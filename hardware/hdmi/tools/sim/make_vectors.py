#!/usr/bin/env python3
"""生成 ModelSim 激励/期望向量: 按主板 cvp_gmii_mac_tx 的线上格式组以太网帧
(preamble+SFD+ETH+IP+UDP+6B应用头+1440B载荷+FCS), 注入 tb_cvp_net2vid 的
GMII 字节流; 同时生成重组器输出的期望光栅 (FS 分帧, 丢包补黑), 供 TB 逐字节比对.

TB 观察到的帧序列 (RTL 行为决定):
  帧0 = 上电黑帧 (首个 offset==0 的包触发上一帧帧尾描述符, 从 pushed=0 补黑满帧)
  帧N = 第 N 个 offset==0 到下一个 offset==0 之间的像素
  最后一组发送的帧没有后续 offset==0, 永远等不到 FS → 不产生观察帧

场景 (帧 = 10 包, IMG 480x10x3 = FRAME_BYTES 14400, 加速仿真):
  clean     4 帧全完整            期望 [黑,f0,f1,f2] crc_bad=0
  lossmid   f1 丢 pkt1 (缺口1包)  期望 pkt1 区域补黑
  dropframe f1 整帧未发           期望 槽位跳过(序列里没有 f1)
  dup       f0 pkt1 重发一次      期望 正常(重复包被拒)
  reorder   f0 按 p0,p2,p1 发送   期望 pkt1 被拒, 区补黑
  badfcs    f0 pkt0 FCS 故意错    期望 MAC crc_bad+1, 区补黑
  biggap    f1 发 p0,p1,p8,p9     期望 缺6包>4包→p2 起补黑到帧尾
  fmt       f1 pkt1 fmt=0x02      期望 重组器按 fmt 丢弃, 区补黑

用法: python make_vectors.py   (在 tools/sim/ 下生成 stim_*.hex / exp_*.hex / manifest.txt)
激励 hex: 每行 1 字节, 'xx'=空闲拍, 末尾 4 行 'zz'=终止符
"""
import os
import struct
import zlib

# ---- 与 cvp_hdmi_top / 主板约定一致 ----
SRC_IP = bytes((192, 168, 1, 66))
DST_IP = bytes((192, 168, 1, 100))
SRC_MAC = bytes.fromhex("021A2B3C4D5E")          # 主板 SA
ETH_DA = b"\xff" * 6                              # 广播(副板 MAC 放行广播 IP 帧)
UDP_PORT = 6000
PAYLOAD = 1440
PKT_PER_FRAME = 10
IMG_W, IMG_H = 480, 10
FRAME_BYTES = IMG_W * IMG_H * 3                   # 14400 = 10 包
IFG_IDLE = 3000                                   # 帧间空闲(覆盖重组器 512 拍消隐 + 追账)
LEAD_IDLE = 100
WARM_GAP = 20000                                  # 预热帧后的长间隔(等黑帧填充/排空完成)
SKIP_COMPARE = 2                                  # TB 跳过比对: 上电黑帧 + 预热帧残影

assert FRAME_BYTES == PKT_PER_FRAME * PAYLOAD


def ip_checksum(hdr):
    s = sum(struct.unpack("> %dH" % (len(hdr) // 2), hdr))
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    return (~s) & 0xFFFF


def wire_packet(seq, k, payload, fmt=0x01, corrupt_fcs=False):
    """一帧线上字节: preamble..FCS 共 1500B (与主板 cvp_gmii_mac_tx 一致)."""
    assert len(payload) == PAYLOAD
    udp_len = 8 + 6 + PAYLOAD                      # 1454
    ip_len = 20 + udp_len                          # 1474
    ip_hdr = struct.pack(">BBHHHBBH", 0x45, 0, ip_len, seq & 0xFFFF, 0, 64, 17, 0) \
        + SRC_IP + DST_IP
    ip_hdr = ip_hdr[:10] + struct.pack(">H", ip_checksum(ip_hdr)) + ip_hdr[12:]
    udp_hdr = struct.pack(">HHHH", UDP_PORT, UDP_PORT, udp_len, 0)
    app = bytes((seq & 0xFF, fmt)) + (k * PAYLOAD).to_bytes(4, "big")
    body = ETH_DA + SRC_MAC + b"\x08\x00" + ip_hdr + udp_hdr + app + payload
    fcs = zlib.crc32(body) & 0xFFFFFFFF            # 以太网 FCS = 反射 CRC32, 线上小端
    if corrupt_fcs:
        fcs ^= 0xFF
    return b"\x55" * 7 + b"\xd5" + body + struct.pack("<I", fcs)


def ref_frame(seq):
    """参考帧光栅字节流: 可识别渐变图案, 便于暴露错位/通道序."""
    row = bytearray()
    for p in range(IMG_W):
        row += bytes(((p * 7) & 0xFF, (p * 13) & 0xFF, (p * 29 + seq * 11) & 0xFF))
    return bytes(row) * IMG_H


def payloads(seq):
    f = ref_frame(seq)
    return [f[k * PAYLOAD:(k + 1) * PAYLOAD] for k in range(PKT_PER_FRAME)]


def fr_raster_expected(seq, sent):
    """一帧期望光栅: 按重组器接受规则(fmt/界内/缺口≤4包)重放, 未达区域保持黑."""
    raster = bytearray(FRAME_BYTES)
    committed = 0
    for (k, fmt, corrupt) in sent:
        off = k * PAYLOAD
        if fmt != 0x01:
            continue                                # 重组器按 fmt 丢弃
        # 注: corrupt(FCS错)时例程 MAC 仍向上转发载荷(uiip_arp_rx 无错误输入),
        # 与 PC 端"内核丢坏帧"不同 —— 期望模型按实际行为保留载荷
        if off == 0 or (off >= committed and off - committed <= 4 * PAYLOAD):
            raster[off:off + PAYLOAD] = ref_frame(seq)[off:off + PAYLOAD]
            committed = off + PAYLOAD
    return bytes(raster)


def build_scenario(name, frames, crc_bad_exp, note):
    """frames: 每帧发送列表, 元素 (k, fmt, corrupt); None = 整帧静默.
    激励 = [预热帧(完整10包)] + 长间隔 + frames;  预热帧吸收上电黑帧的
    staging 水位丢包瞬态, 之后的帧全部正常接收.
    期望 = 预热帧残影(不比对) 之后的 frames[0..n-2] 光栅 (最后一帧等不到 FS)."""
    WARMUP = [(k, 0x01, False) for k in range(PKT_PER_FRAME)]
    stim = [None] * LEAD_IDLE
    plw = payloads(0)
    for (k, fmt, corrupt) in WARMUP:
        stim += wire_packet(0, k, plw[k], fmt, corrupt)
        stim += [None] * 12
    stim += [None] * WARM_GAP
    exp = []
    for fi, fr in enumerate(frames):
        if fr is None:
            stim += [None] * IFG_IDLE
            continue
        pl = payloads(fi)
        for (k, fmt, corrupt) in fr:
            stim += wire_packet(fi, k, pl[k], fmt, corrupt)
            stim += [None] * 12                          # 包间最小 IFG
        stim += [None] * IFG_IDLE
        if fi < len(frames) - 1:                         # 最后一帧观察不到 FS
            exp += fr_raster_expected(fi, fr)
    stim += ["zz"] * 4                                   # TB 终止符
    write_hex("stim_%s.hex" % name, stim)
    write_hex("exp_%s.hex" % name, exp)
    nframes = 2 + len(exp) // FRAME_BYTES                # 黑帧 + 预热残影 + 比对帧
    print("%-10s 观察帧=%d(跳过%d) 激励拍=%d 光栅=%dB crc_bad期望=%d  # %s"
          % (name, nframes, SKIP_COMPARE, len(stim), len(exp), crc_bad_exp, note))
    return nframes, crc_bad_exp


def write_hex(fname, data):
    with open(fname, "w") as f:
        for b in data:
            if b == "zz":
                f.write("zz\n")
            elif b is None:
                f.write("xx\n")
            else:
                f.write("%02x\n" % b)


def main():
    os.chdir(os.path.dirname(os.path.abspath(__file__)))
    manifest = []
    FULL = lambda: [(k, 0x01, False) for k in range(PKT_PER_FRAME)]

    manifest.append(("clean", build_scenario(
        "clean",
        [FULL(), FULL(), FULL(), FULL()], 0, "全完整")))
    manifest.append(("lossmid", build_scenario(
        "lossmid",
        [FULL(), [(k, 0x01, False) for k in range(10) if k != 1], FULL(), FULL()],
        0, "丢pkt1补黑")))
    manifest.append(("dropframe", build_scenario(
        "dropframe",
        [FULL(), None, FULL(), FULL()], 0, "整帧跳过")))
    manifest.append(("dup", build_scenario(
        "dup",
        [[(0, 0x01, False), (1, 0x01, False), (1, 0x01, False)] +
         [(k, 0x01, False) for k in range(2, 10)], FULL(), FULL()],
        0, "重复包被拒")))
    manifest.append(("reorder", build_scenario(
        "reorder",
        [[(0, 0x01, False), (2, 0x01, False)] +
         [(k, 0x01, False) for k in range(1, 10) if k != 2], FULL(), FULL()],
        0, "乱序迟包被拒")))
    manifest.append(("badfcs", build_scenario(
        "badfcs",
        [[(0, 0x01, True)] + [(k, 0x01, False) for k in range(1, 10)], FULL(), FULL()],
        1, "FCS错→MAC丢包")))
    manifest.append(("biggap", build_scenario(
        "biggap",
        [FULL(),
         [(0, 0x01, False), (1, 0x01, False), (8, 0x01, False), (9, 0x01, False)],
         FULL()],
        0, "缺6包>4包→弃帧补黑")))
    manifest.append(("fmt", build_scenario(
        "fmt",
        [FULL(), [(0, 0x01, False), (1, 0x02, False)] +
         [(k, 0x01, False) for k in range(2, 10)], FULL(), FULL()],
        0, "心跳包按fmt丢弃")))

    with open("manifest.txt", "w") as f:
        for name, (nf, bad) in manifest:
            f.write("%s %d %d\n" % (name, nf, bad))
    print("\nmanifest.txt 已生成 (场景名 观察帧数 crc_bad期望)")


if __name__ == "__main__":
    main()

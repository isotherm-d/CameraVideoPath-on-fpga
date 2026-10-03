#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
eth_video_rx —— MLKPAI-F02 以太网视频调试通路 · 上位机接收端

配套板端 cvp_eth_dbg / cvp_gmii_mac_tx（底板 ETHA 网口，RGMII 千兆 UDP）。

UDP 协议（大端，每包）：
    byte0      frame_seq  帧计数 mod 256
    byte1      fmt        0x01 = RGB888 连续帧流
    byte2..5   offset     本包数据在整帧 RGB 字节流中的字节偏移
    byte6..    data       固定 1440B = 480 像素
    一帧 = W*H*3/1440 包（1280x720 → 1920 包）。MAC 层广播发送，板不实现
    ARP：PC 需静态 IP 192.168.1.100/24（端口可用参数改；IP 在 RTL 参数里改）。

用法（先配好 PC 网卡静态 IP 并放行防火墙，详见 README）：
    python tools/eth_video_rx.py                # 默认 0.0.0.0:6000, 1280x720
    python tools/eth_video_rx.py --scale 0.5 --save-dir out_frames

显示窗口按键：s=保存当前帧  q/ESC=退出
依赖：numpy、opencv-python（pip install numpy opencv-python）
"""

import argparse
import os
import socket
import struct
import sys
import time
from collections import deque

import numpy as np
import cv2

HDR_UNPACK = struct.Struct(">BBI").unpack    # frame_seq, fmt, offset u32（大端，共 6B）
HDR_LEN = 6


def parse_args():
    ap = argparse.ArgumentParser(description="MLKPAI-F02 UDP 视频调试接收端")
    ap.add_argument("--bind", default="0.0.0.0", help="绑定地址（默认 0.0.0.0）")
    ap.add_argument("--port", type=int, default=6000, help="UDP 端口（默认 6000，与板端 UDP_DPORT 一致）")
    ap.add_argument("--width", type=int, default=1280)
    ap.add_argument("--height", type=int, default=720)
    ap.add_argument("--data-bytes", type=int, default=1440, help="每包像素字节数（与板端 DATA_BYTES 一致）")
    ap.add_argument("--scale", type=float, default=1.0, help="显示缩放")
    ap.add_argument("--save-dir", default=".", help="按 s 保存 PNG 的目录")
    return ap.parse_args()


FLAG_NAMES = ["PLL锁定", "复位释放", "I2C配置完成", "MIPI字节钟",
              "见过字节流", "见过帧头", "DDR校准", "显示DE",
              "I2C收到ACK", "MIPI_lane错误"]


def decode_flags(v: int) -> str:
    return "  ".join(n for b, n in enumerate(FLAG_NAMES) if v & (1 << b)) or "（全 0）"


def main():
    args = parse_args()
    W, H, DB = args.width, args.height, args.data_bytes
    if (W * H * 3) % DB != 0:
        sys.exit(f"W*H*3={W * H * 3} 不能被 data-bytes={DB} 整除，与板端参数不一致")
    if DB % 3 != 0:
        sys.exit("data-bytes 必须被 3 整除（整像素 RGB888）")
    chunks_per_frame = (W * H * 3) // DB

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 64 << 20)
    sock.settimeout(0.1)     # 无包也要周期性泵 UI，避免窗口假死
    try:
        sock.bind((args.bind, args.port))
    except OSError as e:
        sys.exit(f"绑定 {args.bind}:{args.port} 失败：{e}\n"
                 f"提示：端口被占用？防火墙？或用 --port 换一个。")
    print(f"监听 UDP {args.bind}:{args.port}  期待 {W}x{H} RGB888，"
          f"{DB}B/包 × {chunks_per_frame} 包/帧")
    print("板端应发包到 192.168.1.100（PC 静态 IP），请确认网卡配置与防火墙放行。")
    print("按键：s=保存帧  q/ESC=退出\n")

    frame = np.zeros((H, W, 3), dtype=np.uint8)   # RGB
    cur_seq = None
    got_mask = np.zeros(chunks_per_frame, dtype=bool)
    prev = None                                    # (seq, frame_rgb, complete)

    win = "MLKPAI-F02 eth video"
    cv2.namedWindow(win, cv2.WINDOW_AUTOSIZE)

    stats_n = 0
    stats_bytes = 0
    stat_t0 = time.perf_counter()
    prev_stat_t = stat_t0
    prev_stat_bytes = 0
    fps_hist = deque(maxlen=30)
    last_show = 0.0
    late = 0
    pkt_bad = 0
    frames_done = 0
    last_pkt_t = 0.0        # 最近任意包
    last_video_t = 0.0      # 最近视频包（fmt=1）
    last_hb_t = 0.0         # 最近心跳
    last_flags = -1         # 上次心跳标志（-1 = 还没收到）
    scan_page = -1          # 上次心跳扫描页（0..7，覆盖 128 个 I2C 地址）
    scan_mask = [0] * 8     # 重建的 128 位 I2C ACK 位图（每页 16bit）

    def finish_frame():
        """收尾当前帧：与上一帧比，留完整度高的用于显示"""
        nonlocal prev, frames_done
        comp = float(got_mask.sum()) / chunks_per_frame
        if prev is None or comp >= prev[2]:
            prev = (cur_seq, frame.copy(), comp)
        frames_done += 1
        fps_hist.append(time.perf_counter())

    def show(now):
        seq, img, comp = prev
        disp = cv2.cvtColor(img, cv2.COLOR_RGB2BGR)
        if args.scale != 1.0:
            disp = cv2.resize(disp, None, fx=args.scale, fy=args.scale,
                              interpolation=cv2.INTER_NEAREST)
        dt = fps_hist[-1] - fps_hist[0] if len(fps_hist) > 1 else 1.0
        fps = (len(fps_hist) - 1) / dt if dt > 0 else 0.0
        el = now - stat_t0
        mbps = stats_bytes * 8 / el / 1e6 if el > 0 else 0.0
        cv2.putText(disp, f"seq={seq} {fps:4.1f}fps {mbps:6.1f}Mbps "
                          f"complete={comp * 100:5.1f}% late={late} bad={pkt_bad}",
                    (8, 24), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 255, 0), 1, cv2.LINE_AA)
        cv2.imshow(win, disp)

    try:
        while True:
            # 带超时收包：无包也周期性泵 UI，窗口不会"未响应"
            try:
                data, addr = sock.recvfrom(65536)
            except socket.timeout:
                data = None

            if data is not None:
                last_pkt_t = time.perf_counter()
                stats_n += 1
                stats_bytes += len(data)
                if len(data) >= HDR_LEN:
                    fseq, fmt, offset = HDR_UNPACK(data[:HDR_LEN])
                    payload = data[HDR_LEN:]
                    if fmt == 2:                           # 心跳状态包
                        if len(payload) >= 4:
                            hb_flags = payload[0] | (payload[1] << 8)
                            hb_seq = payload[2]
                            hb_word = payload[3] | (payload[4] << 8)
                            if scan_page != hb_seq:
                                scan_page = hb_seq
                                scan_mask[scan_page] = hb_word
                                addrs = [a for a in range(128)
                                         if scan_mask[a // 16] & (1 << (a % 16))]
                                print(f"\n[心跳#{hb_seq}] 状态=0x{hb_flags:04X} "
                                      f"{decode_flags(hb_flags)}")
                                print(f"  I2C扫描 页{hb_seq} = 0x{hb_word:04X}  "
                                      f"ACK地址: "
                                      f"{[hex(a) for a in addrs] if addrs else '无'}")
                        last_flags = hb_flags
                        last_hb_t = time.perf_counter()
                        payload = None
                    elif fmt == 1 and len(payload) == DB and offset % DB == 0:
                        last_video_t = time.perf_counter()
                        if cur_seq is None:
                            cur_seq = fseq
                        d = (fseq - cur_seq) & 0xFF
                        if d == 0:
                            pass                               # 当前帧
                        elif d < 128:                          # 新帧开始：收尾上一帧
                            finish_frame()
                            frame[:] = 0
                            got_mask[:] = False
                            cur_seq = fseq
                        else:                                  # 迟到包
                            late += 1
                            payload = None
                        if payload is not None:
                            chunk = offset // DB
                            if chunk < chunks_per_frame and not got_mask[chunk]:
                                got_mask[chunk] = True
                                frame.reshape(-1)[offset:offset + DB] = \
                                    np.frombuffer(payload, dtype=np.uint8)
                    else:
                        pkt_bad += 1
                        if pkt_bad <= 10:
                            print(f"  [warn] 异常包：fmt={fmt} len={len(payload)} offset={offset}")
                else:
                    pkt_bad += 1

            now = time.perf_counter()
            if now - last_show > 0.03:                     # ≤30fps 泵 UI（无包也刷）
                video_stale = (now - last_video_t > 1.0) if last_video_t else True
                if prev is not None and not video_stale:
                    show(now)
                else:
                    # 无视频：状态面板（含最近一次心跳的链路标志）
                    splash = np.zeros((380, 780, 3), dtype=np.uint8)
                    cv2.putText(splash, "no video stream - board status (heartbeat)",
                                (20, 40), cv2.FONT_HERSHEY_SIMPLEX, 0.6,
                                (0, 255, 0), 1, cv2.LINE_AA)
                    if last_flags >= 0:
                        lines = [f"flags = 0x{last_flags:04X}"]
                        row = ""
                        for b, n in enumerate(FLAG_NAMES):
                            mark = "[v]" if last_flags & (1 << b) else "[ ]"
                            row += f"{mark}{n} "
                            if (b % 2) == 1:
                                lines.append(row)
                                row = ""
                        if row:
                            lines.append(row)
                        lines.append("")
                        addrs = [a for a in range(128)
                                 if scan_mask[a // 16] & (1 << (a % 16))]
                        if scan_page >= 0:
                            lines.append(f"I2C scan pages recv: {scan_page + 1}/8")
                            lines.append("scan words: " + " ".join(
                                f"{w:04X}" for w in scan_mask))
                            lines.append("ACK addrs: "
                                         + (", ".join(f"0x{a:02X}" for a in addrs)
                                            if addrs else "NONE (bus dead?)"))
                        y = 90
                        for ln in lines:
                            color = (0, 255, 0) if not ln.startswith("flags") else (255, 255, 0)
                            cv2.putText(splash, ln, (20, y),
                                        cv2.FONT_HERSHEY_SIMPLEX, 0.55, color, 1, cv2.LINE_AA)
                            y += 28
                    else:
                        cv2.putText(splash, "no heartbeat either - check cable/LED1/IP/firewall",
                                    (20, 90), cv2.FONT_HERSHEY_SIMPLEX, 0.55,
                                    (0, 0, 255), 1, cv2.LINE_AA)
                    cv2.imshow(win, splash)
                key = cv2.waitKey(1) & 0xFF
                if key in (ord("q"), 27):
                    break
                if key == ord("s") and prev is not None:
                    fn = os.path.join(args.save_dir,
                                      f"frame_{prev[0]:03d}_{int(now)}.png")
                    os.makedirs(os.path.dirname(fn) or ".", exist_ok=True)
                    cv2.imwrite(fn, cv2.cvtColor(prev[1], cv2.COLOR_RGB2BGR))
                    print(f"  saved {fn}")
                last_show = now

            el = now - stat_t0
            if now - prev_stat_t >= 2.0:               # 每 2s 一行窗口统计
                win_t = now - prev_stat_t
                win_b = stats_bytes - prev_stat_bytes
                mbps = win_b * 8 / win_t / 1e6
                print(f"\r[{el:7.1f}s] 包 {stats_n / el:8.0f}/s  "
                      f"{mbps:7.1f} Mbps  整帧 {frames_done}  "
                      f"迟到 {late}  异常 {pkt_bad}   ", end="", flush=True)
                prev_stat_t = now
                prev_stat_bytes = stats_bytes
    except KeyboardInterrupt:
        pass
    finally:
        cv2.destroyAllWindows()
        print("\n退出。")


if __name__ == "__main__":
    main()

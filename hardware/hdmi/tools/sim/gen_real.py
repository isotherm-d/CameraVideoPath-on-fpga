#!/usr/bin/env python3
"""gen_real.py: 全分辨率真机工况向量 (1280x720, 1920包/帧, 背靠背无帧间隔)
激励 = 预热帧(吸收上电黑帧瞬态) + 3 个比对帧; 期望 = 前 2 个比对帧光栅。
配 tb_rgmii_ddr_full.v: +NFRAMES=4 +EXPBAD=0 +SKIPFRAMES=2"""
import struct, zlib, os

SRC_IP = bytes((192,168,1,66)); DST_IP = bytes((192,168,1,100))
SRC_MAC = bytes.fromhex("021A2B3C4D5E"); ETH_DA = b"\xff"*6
UDP_PORT = 6000; PAYLOAD = 1440; PKT = 1920
IMG_W, IMG_H = 1280, 720
FRAME_BYTES = IMG_W*IMG_H*3
IFG = 12            # 真机: 包间仅最小帧距, 帧间无额外空闲
LEAD = 200

def ip_ck(h):
    s = sum(struct.unpack(">%dH" % (len(h)//2), h))
    while s >> 16: s = (s & 0xFFFF) + (s >> 16)
    return (~s) & 0xFFFF

def wire_packet(seq, k, payload, fmt=0x01, corrupt=False):
    ul = 8+6+PAYLOAD; il = 20+ul
    iph = struct.pack(">BBHHHBBH", 0x45,0,il,seq&0xFFFF,0,64,17,0)+SRC_IP+DST_IP
    iph = iph[:10]+struct.pack(">H", ip_ck(iph))+iph[12:]
    udph = struct.pack(">HHHH", UDP_PORT, UDP_PORT, ul, 0)
    app = bytes((seq & 0xFF, fmt)) + (k*PAYLOAD).to_bytes(4,"big")
    body = ETH_DA+SRC_MAC+b"\x08\x00"+iph+udph+app+payload
    fcs = zlib.crc32(body) & 0xFFFFFFFF
    if corrupt: fcs ^= 0xFF
    return b"\x55"*7+b"\xd5"+body+struct.pack("<I", fcs)

def ref_frame(seq):
    row = bytearray()
    for p in range(IMG_W):
        row += bytes(((p*7)&0xFF, (p*13)&0xFF, (p*29+seq*11)&0xFF))
    return bytes(row)*IMG_H

def payloads(seq):
    f = ref_frame(seq); return [f[k*PAYLOAD:(k+1)*PAYLOAD] for k in range(PKT)]

def raster(seq, sent):
    r = bytearray(FRAME_BYTES); c = 0
    for (k,fmt,cor) in sent:
        off = k*PAYLOAD
        if fmt != 0x01 or cor: continue
        if off == 0 or (off >= c and off-c <= 4*PAYLOAD):
            r[off:off+PAYLOAD] = ref_frame(seq)[off:off+PAYLOAD]; c = off+PAYLOAD
    return bytes(r)

def main():
    os.chdir(os.path.dirname(os.path.abspath(__file__)))
    FULL = lambda: [(k,0x01,False) for k in range(PKT)]
    frames = [FULL()] * 10                       # 预热帧 + seq0(瞬态牺牲) + 8 个比对帧 + 1 帧闭合

    stim = [None]*LEAD
    plw = payloads(0)
    for (k,fmt,cor) in FULL():
        stim += wire_packet(0,k,plw[k],fmt,cor); stim += [None]*IFG
    exp = []                                   # 预热残影帧被跳过, 不进期望
    for fi,fr in enumerate(frames):
        pl = payloads(fi)
        for (k,fmt,cor) in fr:
            stim += wire_packet(fi,k,pl[k],fmt,cor); stim += [None]*IFG
        if 1 <= fi < len(frames)-1:            # fi=0(seq0) 被上电瞬态吃掉, 不进期望
            exp += raster(fi, fr)
    stim += ["zz"]*4

    def wh(fn, d):
        with open(fn,"w") as f:
            for b in d:
                f.write("zz\n" if b=="zz" else "xx\n" if b is None else "%02x\n"%b)
    wh("stim_real.hex", stim); wh("exp_real.hex", exp)
    nf = 2 + len(exp)//FRAME_BYTES             # 黑帧 + 预热残影 + 比对帧
    open("manifest_real.txt","w").write("real %d 0\n" % nf)
    print("stim=%d 拍, 期望=%d 字节, 观察帧=%d (跳过2)" % (len(stim), len(exp), nf))

if __name__ == "__main__":
    main()

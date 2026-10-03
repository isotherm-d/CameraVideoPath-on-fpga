#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
verify_eth_out —— 校验 tb_eth_dbg_smoke 抓到的以太网帧（eth_out.bin）
每帧：前导/SFD、以太网/IP/UDP 头、IP 校验和、应用头（frame_seq 递增、offset 归零）、
payload 图案 字节 m = (m//3 + 1 + m%3) & 0xFF、CRC32/FCS。
"""
import struct
import sys
import zlib

DATA_BYTES = 1440
PAYLOAD = 6 + DATA_BYTES
FRAME_LEN = 14 + 20 + 8 + PAYLOAD            # 1488
FCS_BEG = 8 + FRAME_LEN                      # 1496
FRAME_ONWIRE = FCS_BEG + 4                   # 1500
PKTS_PER_FRAME = 1920

MAC_DST = bytes.fromhex("FFFFFFFFFFFF")
MAC_SRC = bytes.fromhex("021A2B3C4D5E")
IP_SRC = bytes([192, 168, 1, 66])
IP_DST = bytes([192, 168, 1, 100])


def crc32_eth(data: bytes) -> bytes:
    return struct.pack("<I", zlib.crc32(data) & 0xFFFFFFFF)


def ip_checksum(hdr20: bytes) -> int:
    s = sum(struct.unpack(">10H", hdr20))
    s = (s & 0xFFFF) + (s >> 16)
    s = (s & 0xFFFF) + (s >> 16)
    return (~s) & 0xFFFF


def main(path):
    buf = open(path, "rb").read()
    n = len(buf) // 1500                     # 每帧自前导码第一字节起（TX_EN 窗口）
    assert n >= 2, f"只抓到 {len(buf)} 字节"
    fails = []

    for pidx in range(2):                    # 校验前 2 包
        seg = buf[pidx * 1500:(pidx + 1) * 1500]
        f = seg                              # 已含前导码+SFD
        tag = f"[包{pidx}]"

        if f[:7] != b"\x55" * 7 or f[7] != 0xD5:
            fails.append(f"{tag} 前导/SFD 错")
        eth = f[8:8 + FRAME_LEN]
        fcs = f[FCS_BEG:FCS_BEG + 4]

        if eth[0:6] != MAC_DST or eth[6:12] != MAC_SRC:
            fails.append(f"{tag} MAC 错")
        if eth[12:14] != b"\x08\x00":
            fails.append(f"{tag} EtherType 错")
        ip = eth[14:34]
        if ip[0:2] != b"\x45\x00":
            fails.append(f"{tag} IP 版本错")
        if struct.unpack(">H", ip[2:4])[0] != 20 + 8 + PAYLOAD:
            fails.append(f"{tag} IP 总长错")
        if ip_checksum(ip) != 0:
            fails.append(f"{tag} IP 校验和错")
        if ip[12:16] != IP_SRC or ip[16:20] != IP_DST:
            fails.append(f"{tag} IP 地址错")
        sport, dport, ulen, ucsum = struct.unpack(">HHHH", eth[34:42])
        if (sport, dport, ulen, ucsum) != (6000, 6000, 8 + PAYLOAD, 0):
            fails.append(f"{tag} UDP 头错 {sport}/{dport}/{ulen}/{ucsum}")

        payload = eth[42:42 + PAYLOAD]
        off = struct.unpack(">I", payload[2:6])[0]
        exp_frame = off // (PKTS_PER_FRAME * DATA_BYTES)
        if payload[0] != exp_frame:
            fails.append(f"{tag} frame_seq={payload[0]} 期待 {exp_frame}")
        if payload[1] != 1:
            fails.append(f"{tag} fmt={payload[1]}")
        if off != pidx * DATA_BYTES:
            fails.append(f"{tag} offset={off} 期待 {pidx * DATA_BYTES}")

        base = pidx * DATA_BYTES
        bad = None
        for j in range(DATA_BYTES):
            expect = (0x11, 0x22, 0x33)[j % 3]
            if payload[6 + j] != expect:
                bad = (j, payload[6 + j], expect)
                break
        if bad is not None:
            fails.append(f"{tag} payload 第{bad[0]}字节 {bad[1]:02X}!={bad[2]:02X}")

        if crc32_eth(eth) != fcs:
            fails.append(f"{tag} FCS 错")

    if fails:
        print("FAIL:")
        for x in fails[:20]:
            print(" ", x)
        sys.exit(1)
    print(f"PASS: {n} 帧线上字节、前 2 包全字段（含帧序/偏移/像素图案/FCS）校验通过")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "eth_out.bin")

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
verify_mac_out —— 校验 tb_mac_tx_smoke 抓到的以太网帧（mac_out.bin）

逐字段校验：前导/SFD、以太网头、IP 头+首部校验和、UDP 头、应用头
（frame_seq/fmt/offset）、payload 图案 (i*7+13)&0xFF、CRC32/FCS。
"""
import struct
import sys
import zlib

DATA_BYTES = 1440
FRAME_ONWIRE = 1500
PAYLOAD = 6 + DATA_BYTES
FRAME_LEN = 14 + 20 + 8 + PAYLOAD           # 1488
FCS_BEG = 8 + FRAME_LEN                      # 1496

MAC_DST = bytes.fromhex("FFFFFFFFFFFF")
MAC_SRC = bytes.fromhex("021A2B3C4D5E")
IP_SRC = bytes([192, 168, 1, 66])
IP_DST = bytes([192, 168, 1, 100])


def crc32_eth(data: bytes) -> bytes:
    """以太网 FCS：CRC-32 (reflected, 0xEDB88320)，低字节先发"""
    c = zlib.crc32(data) & 0xFFFFFFFF        # zlib 即 reflected 0xEDB88320, init/xorout 全 F
    return struct.pack("<I", c)


def ip_checksum(hdr20: bytes) -> int:
    s = sum(struct.unpack(">10H", hdr20))
    s = (s & 0xFFFF) + (s >> 16)
    s = (s & 0xFFFF) + (s >> 16)
    return (~s) & 0xFFFF


def main(path):
    buf = open(path, "rb").read()
    n_frames = len(buf) // FRAME_ONWIRE
    assert len(buf) == 2 * FRAME_ONWIRE, f"长度 {len(buf)} != 2*{FRAME_ONWIRE}"
    fails = []

    for fidx in range(n_frames):
        f = buf[fidx * FRAME_ONWIRE:(fidx + 1) * FRAME_ONWIRE]
        tag = f"[帧{fidx}]"

        if f[:7] != b"\x55" * 7:
            fails.append(f"{tag} 前导错: {f[:7].hex()}")
        if f[7] != 0xD5:
            fails.append(f"{tag} SFD 错: {f[7]:02X}")

        eth = f[8:8 + FRAME_LEN]
        fcs = f[FCS_BEG:FCS_BEG + 4]

        if eth[0:6] != MAC_DST:
            fails.append(f"{tag} MAC_DST 错: {eth[0:6].hex()}")
        if eth[6:12] != MAC_SRC:
            fails.append(f"{tag} MAC_SRC 错: {eth[6:12].hex()}")
        if eth[12:14] != b"\x08\x00":
            fails.append(f"{tag} EtherType 错: {eth[12:14].hex()}")

        ip = eth[14:34]
        if ip[0:2] != b"\x45\x00":
            fails.append(f"{tag} IP 版本/长度错: {ip[0:2].hex()}")
        total_len = struct.unpack(">H", ip[2:4])[0]
        if total_len != 20 + 8 + PAYLOAD:
            fails.append(f"{tag} IP TotalLength={total_len} 期待 {20+8+PAYLOAD}")
        if ip[8] != 0x40 or ip[9] != 0x11:
            fails.append(f"{tag} TTL/Proto 错: {ip[8]:02X}/{ip[9]:02X}")
        if ip_checksum(ip) != 0:
            fails.append(f"{tag} IP 校验和错（含校验和域={ip[10:12].hex()}）")
        if ip[12:16] != IP_SRC or ip[16:20] != IP_DST:
            fails.append(f"{tag} IP 地址错: {ip[12:16].hex()}->{ip[16:20].hex()}")

        udp = eth[34:42]
        sport, dport, ulen, ucsum = struct.unpack(">HHHH", udp)
        if sport != 6000 or dport != 6000:
            fails.append(f"{tag} UDP 端口 {sport}->{dport}")
        if ulen != 8 + PAYLOAD:
            fails.append(f"{tag} UDP len={ulen}")
        if ucsum != 0:
            fails.append(f"{tag} UDP 校验和非 0")

        payload = eth[42:42 + PAYLOAD]
        off = struct.unpack(">I", payload[2:6])[0]
        exp_frame = off // (1920 * DATA_BYTES)      # 包序≠帧序：一帧 1920 包
        if payload[0] != exp_frame:
            fails.append(f"{tag} frame_seq={payload[0]} 期待 {exp_frame}")
        if payload[1] != 1:
            fails.append(f"{tag} fmt={payload[1]}")
        if off != fidx * DATA_BYTES:
            fails.append(f"{tag} offset={off} 期待 {fidx * DATA_BYTES}")

        base = fidx * DATA_BYTES
        expect = bytes(((base + j) * 7 + 13) & 0xFF for j in range(DATA_BYTES))
        if payload[6:] != expect:
            bad = next(j for j in range(DATA_BYTES) if payload[6 + j] != expect[j])
            fails.append(f"{tag} payload 第{bad}字节错: {payload[6+bad]:02X} != {expect[bad]:02X}")

        if crc32_eth(eth) != fcs:
            fails.append(f"{tag} FCS 错: 线上 {fcs.hex()} 计算 {crc32_eth(eth).hex()}")

    if fails:
        print("FAIL:")
        for x in fails[:20]:
            print(" ", x)
        sys.exit(1)
    print(f"PASS: {n_frames} 帧、全部字段（头/校验和/应用头/payload/FCS 字节序）校验通过")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "mac_out.bin")

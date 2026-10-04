#!/usr/bin/env python3
"""cam_ctrl —— MLKPAI-F02 相机网络控制工具(v20)
通过 UDP 命令包(端口 6001)控制相机曝光码与白平衡增益。

用法:
  python cam_ctrl.py exp 1400        # 曝光码(半行); 720p30 合法 62..1400(满帧 996 行=码 1996 由固件钳位)
  python cam_ctrl.py mode 0          # 0=手动(按键) 1=自动(cvp_ae) 2=网络值
  python cam_ctrl.py gain 291 256 246  # 白平衡三通道 Q8 增益(256=1.0x)
  python cam_ctrl.py swap 1          # R/B 通道互换
"""
import socket, sys, time

TARGET = ("192.168.1.66", 6001)
MAGIC = bytes([0xC5, 0xA5, 0x50, 0x01])

def send(sock, cmd, value):
    pkt = MAGIC + bytes([cmd]) + value.to_bytes(3, "big")
    sock.sendto(pkt, TARGET)

def main():
    if len(sys.argv) < 2:
        print(__doc__); return
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    cmd_name = sys.argv[1].lower()
    cmds = {
        "exp":   (1, lambda a: int(a[0])),
        "mode":  (0, lambda a: int(a[0])),
        "gainr": (2, lambda a: int(a[0])),
        "gaing": (3, lambda a: int(a[0])),
        "gainb": (4, lambda a: int(a[0])),
        "swap":  (5, lambda a: int(a[0])),
        "gain":  (None, lambda a: None),   # 特殊: 三通道连发
    }
    if cmd_name not in cmds:
        print("未知命令:", cmd_name); return
    code, fn = cmds[cmd_name]
    args = sys.argv[2:]
    if cmd_name == "gain":
        r, g, b = (int(x) for x in args[:3])
        for c, v in ((2, r), (3, g), (4, b)):
            send(sock, c, v); time.sleep(0.01)
        print(f"白平衡增益 R={r} G={g} B={b} (Q8)")
    else:
        v = fn(args)
        send(sock, code, v)
        print(f"{cmd_name} = {v}")

if __name__ == "__main__":
    main()

"""PC 直连副板发包分诊工具: 按主板网口格式发彩条流.

用法(Windows 管理员):
  1. PC 网线直连副板 RJ45; 网卡配静态 IP 192.168.1.66/24 (无网关)
  2. arp -s 192.168.1.100 FF-FF-FF-FF-FF-FF   (绑定广播MAC, 绕过副板无ARP)
  3. python eth_bar_tx.py            (默认 5fps, 720p 彩条)
     python eth_bar_tx.py --fps 30   (满速, 测重组器鲁棒性)

观察: 副板 LED1(P104) 闪 = 协议栈收到包; LED2(P109) 闪 = 重组出完整帧;
      屏幕出彩条 = 全链路(含DDR/HDMI读侧)通。
发送后按 Ctrl+C 停止。
"""
import socket, sys, time, argparse

W, H, DB, HDR = 1280, 720, 1440, 6
CPF = (W * H * 3) // DB          # 1920

def bar_frame():
    """8 竖彩条一帧的字节流 (R,G,B 连续光栅)."""
    row = bytearray()
    for x in range(W):
        b = x * 8 // W
        row += bytes(((0xFF,0xFF,0xFF),(0xFF,0xFF,0),(0,0xFF,0xFF),(0,0xFF,0),
                      (0xFF,0,0xFF),(0xFF,0,0),(0,0,0xFF),(0,0,0))[b])
    return bytes(row) * H

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fps", type=float, default=5.0)
    ap.add_argument("--gap", type=float, default=8.0, help="per-packet busy gap in us")
    ap.add_argument("--ip", default="192.168.1.100")
    ap.add_argument("--port", type=int, default=6000)
    a = ap.parse_args()

    frame = bar_frame()
    seq = 0
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    print(f"发送 720p 彩条 {a.fps}fps -> {a.ip}:{a.port}  (Ctrl+C 停止)")
    period = 1.0 / a.fps
    next_t = time.perf_counter()
    t0, frames = time.perf_counter(), 0
    try:
        while True:
            for k in range(CPF):
                pkt = bytes((seq & 0xFF, 0x01)) + (k * DB).to_bytes(4, "big") \
                      + frame[k*DB:(k+1)*DB]
                sock.sendto(pkt, (a.ip, a.port))
                if a.gap > 0:                      # 帧距诊断: 消除背靠背
                    t_end = time.perf_counter() + a.gap * 1e-6
                    while time.perf_counter() < t_end:
                        pass
            seq += 1
            frames += 1

            next_t += period
            now = time.perf_counter()
            if now < next_t:
                time.sleep(next_t - now)
            else:
                next_t = now          # 发送落后于目标帧率, 重新对齐

            el = time.perf_counter() - t0
            if el > 2:
                print(f"{frames/el:6.1f} fps 发送中...")
                t0, frames = time.perf_counter(), 0
    except KeyboardInterrupt:
        print("停止")

if __name__ == "__main__":
    main()

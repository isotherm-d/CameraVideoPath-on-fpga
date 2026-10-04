#!/usr/bin/env python3
"""cam_gui —— MLKPAI-F02 相机接收 + 控制一体化图形界面

左: 实时视频(UDP 6000 接收)
右: 控制面板(曝光码/自动曝光开关/白平衡增益/R-B 互换, UDP 6001 命令)
    s=抓图  q=退出
"""
import socket, threading, time, sys
import numpy as np
import tkinter as tk
from tkinter import ttk
import cv2

W, H, DB = 1280, 720, 1440
CHUNKS = W * H * 3 // DB          # 1920 包/帧
TARGET = ("192.168.1.66", 6001)   # 相机命令端口

MAGIC = bytes([0xC5, 0xA5, 0x50, 0x01])


class App:
    def __init__(self, root):
        self.root = root
        root.title("MLKPAI-F02 相机 - 1280x720@30")
        root.protocol("WM_DELETE_WINDOW", self.quit)

        # ---- 视频区 ----
        self.video = tk.Label(root, bg="black", width=640, height=360)
        self.video.grid(row=0, column=0, padx=4, pady=4)

        # ---- 控制面板 ----
        panel = ttk.LabelFrame(root, text="相机控制 (UDP 6001)")
        panel.grid(row=0, column=1, sticky="ns", padx=4, pady=4)

        def lbl(r, t):
            ttk.Label(panel, text=t).grid(row=r, column=0, sticky="w", padx=6, pady=2)

        # 曝光码
        lbl(0, "曝光码 (62..1996 半行)")
        self.exp_var = tk.IntVar(value=1400)
        self.exp_scale = ttk.Scale(panel, from_=62, to=1996, variable=self.exp_var,
                                   orient="horizontal", length=220,
                                   command=self.on_exp_scale)
        self.exp_scale.grid(row=1, column=0, padx=6, sticky="ew")
        self.exp_label = ttk.Label(panel, text="1400")
        self.exp_label.grid(row=2, column=0, sticky="w", padx=6)
        ttk.Button(panel, text="发送曝光", command=self.send_exp).grid(row=3, column=0, pady=2)

        ttk.Separator(panel).grid(row=4, column=0, sticky="ew", pady=6)

        # 模式
        lbl(5, "曝光模式")
        self.mode_var = tk.IntVar(value=0)
        for v, t in ((0, "手动(按键值)"), (1, "自动(cvp_ae)"), (2, "网络值")):
            ttk.Radiobutton(panel, text=t, value=v, variable=self.mode_var,
                            command=self.send_mode).grid(row=6 + v, column=0, sticky="w", padx=6)

        ttk.Separator(panel).grid(row=9, column=0, sticky="ew", pady=6)

        # 白平衡增益
        lbl(10, "白平衡增益 Q8 (256=1.0x, 上限 511)")
        self.gain_vars = {}
        for i, ch in enumerate(("R", "G", "B")):
            ttk.Label(panel, text=ch).grid(row=11 + i, column=0, sticky="w", padx=6)
            sv = tk.IntVar(value=[291, 256, 246][i])
            self.gain_vars[ch] = sv
            ttk.Scale(panel, from_=64, to=511, variable=sv, orient="horizontal",
                      length=220, command=lambda *_: None).grid(row=11 + i, column=0, sticky="ew")
            ttk.Label(panel, textvariable=sv).grid(row=11 + i, column=1)
        ttk.Button(panel, text="发送白平衡", command=self.send_gain).grid(row=14, column=0, pady=2)

        ttk.Separator(panel).grid(row=15, column=0, sticky="ew", pady=6)
        self.swap_var = tk.BooleanVar(value=False)
        ttk.Checkbutton(panel, text="R/B 通道互换", variable=self.swap_var,
                        command=self.send_swap).grid(row=16, column=0, sticky="w", padx=6)

        # 状态栏
        self.status = tk.Label(root, text="启动中...", anchor="w", fg="green")
        self.status.grid(row=1, column=0, columnspan=2, sticky="ew")

        # ---- 接收线程 ----
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 64 << 20)
        self.sock.bind(("0.0.0.0", 6000))
        self.sock.settimeout(0.05)

        self.frame = np.zeros((H, W, 3), dtype=np.uint8)
        self.got = set()
        self.cur = None
        self.frames = 0
        self.running = True

        self.rx_thread = threading.Thread(target=self.rx_loop, daemon=True)
        self.rx_thread.start()
        self.update_video()

    # ---------- 网络接收 ----------
    def rx_loop(self):
        stat_t = time.perf_counter()
        pkt_cnt = 0
        while self.running:
            try:
                d, a = self.sock.recvfrom(65536)
            except socket.timeout:
                continue
            if len(d) < 6 or d[1] != 1:
                continue
            pkt_cnt += 1
            seq = d[0]
            off = int.from_bytes(d[2:6], "big")
            if seq != self.cur:
                self.cur = seq
                self.got = set()
            idx = off // DB
            if idx < CHUNKS and idx not in self.got:
                self.got.add(idx)
                self.frame.reshape(-1)[off:off + DB] = np.frombuffer(d[6:6 + DB], dtype=np.uint8)
            if len(self.got) == CHUNKS:
                self.frames += 1
        el = time.perf_counter() - stat_t
        print(f"接收线程结束: {pkt_cnt/el:.0f} 包/s")

    # ---------- 视频刷新(主线程, Tk 安全) ----------
    def update_video(self):
        img = self.frame.copy()
        complete = len(self.got) / CHUNKS * 100
        cv2.putText(img, f"{self.frames} frames  complete={complete:.0f}%",
                    (8, 24), cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 255, 0), 2)
        rgb = cv2.cvtColor(img, cv2.COLOR_RGB2BGR)
        h, w = rgb.shape[:2]
        ph = int(720 * 0.62); pw = int(1280 * 0.62)
        rgb = cv2.resize(rgb, (pw, ph))
        self.tkimg = __import__("PIL.Image", fromlist=["Image"]).fromarray(rgb)
        try:
            from PIL import ImageTk
            self.photo = ImageTk.PhotoImage(image=self.tkimg)
            self.video.configure(image=self.photo, width=pw, height=ph)
        except ImportError:
            pass
        self.status.configure(text=f"complete={complete:.0f}%  帧计数 {self.frames}")
        if self.running:
            self.root.after(33, self.update_video)

    # ---------- 命令发送 ----------
    def _send(self, cmd, value):
        pkt = MAGIC + bytes([cmd]) + (value & 0xFFFFFF).to_bytes(3, "big")
        self.sock.sendto(pkt, TARGET)

    def send_exp(self):
        v = int(self.exp_var.get())
        self._send(1, v)
        self.exp_label.configure(text=str(v))

    def on_exp_scale(self, _):
        self.exp_label.configure(text=str(int(float(_))))

    def send_mode(self):
        v = int(self.mode_var.get())
        self._send(0, v)

    def send_gain(self):
        for cmd, ch in ((2, "R"), (3, "G"), (4, "B")):
            self._send(cmd, int(self.gain_vars[ch].get()))
            time.sleep(0.01)

    def send_swap(self):
        self._send(5, 1 if self.swap_var.get() else 0)

    def quit(self):
        self.running = False
        self.root.destroy()


def main():
    root = tk.Tk()
    app = App(root)
    root.mainloop()


if __name__ == "__main__":
    main()

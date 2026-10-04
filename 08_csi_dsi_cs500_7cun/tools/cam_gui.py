#!/usr/bin/env python3
"""cam_gui —— MLKPAI-F02 相机接收 + 控制一体化图形界面(v2)

- 完整分辨率实时视频 + 实时帧率显示
- 滑条拖动停止后自动下发(无需点按钮):
    曝光码 / 白平衡 R/G/B / R-B 互换 / 曝光模式
  s=抓图  q=退出
"""
import socket, threading, time
import numpy as np
import tkinter as tk
from tkinter import ttk
import cv2

W, H, DB = 1280, 720, 1440
CHUNKS = W * H * 3 // DB          # 1920 包/帧
TARGET = ("192.168.1.255", 6001)  # 子网广播: 板子不响应 ARP, 广播无需 MAC 解析   # 相机命令端口
MAGIC = bytes([0xC5, 0xA5, 0x50, 0x01])


class App:
    def __init__(self, root):
        self.root = root
        root.title("MLKPAI-F02 相机 - 1280x720@30fps")
        root.resizable(False, False)
        root.protocol("WM_DELETE_WINDOW", self.quit)

        # ---- 视频区(完整分辨率) ----
        self.video = tk.Label(root, bg="black")
        self.video.grid(row=0, column=0, padx=2, pady=2)

        # ---- 控制面板 ----
        panel = ttk.LabelFrame(root, text="控制 (UDP 6001, 拖动即生效)")
        panel.grid(row=0, column=1, sticky="ns", padx=4, pady=4)

        row = 0
        ttk.Label(panel, text="曝光码 (62..2244 半行)").grid(row=row, column=0, columnspan=2, sticky="w", padx=6)
        row += 1
        self.exp_var = tk.IntVar(value=1400)
        self._deb = {}
        ttk.Scale(panel, from_=62, to=2244, variable=self.exp_var, orient="horizontal", length=230,
                  command=lambda v: self.debounced("exp", self.send_exp)).grid(row=row, column=0, columnspan=2, padx=6, sticky="ew")
        row += 1
        self.exp_lbl = ttk.Label(panel, text="1400 半行 (700 行)", width=26)
        self.exp_lbl.grid(row=row, column=0, columnspan=2, sticky="w", padx=6)
        row += 1

        ttk.Separator(panel).grid(row=row, column=0, columnspan=2, sticky="ew", pady=4)
        row += 1
        ttk.Label(panel, text="曝光模式").grid(row=row, column=0, columnspan=2, sticky="w", padx=6)
        row += 1
        self.mode_var = tk.IntVar(value=0)
        for v, t in ((0, "手动(按键值)"), (1, "自动(cvp_ae 闭环)"), (2, "网络值")):
            ttk.Radiobutton(panel, text=t, value=v, variable=self.mode_var,
                            command=self.send_mode).grid(row=row, column=0, columnspan=2, sticky="w", padx=6)
            row += 1

        ttk.Separator(panel).grid(row=row, column=0, columnspan=2, sticky="ew", pady=4)
        row += 1
        ttk.Label(panel, text="白平衡增益 Q8 (256=1.0x)").grid(row=row, column=0, columnspan=2, sticky="w", padx=6)
        row += 1
        self.gain_vars = {}
        for ch, dft in (("R", 291), ("G", 256), ("B", 246)):
            ttk.Label(panel, text=ch, width=2).grid(row=row, column=0, sticky="w", padx=6)
            sv = tk.IntVar(value=dft)
            self.gain_vars[ch] = sv
            ttk.Scale(panel, from_=64, to=511, variable=sv, orient="horizontal", length=200,
                      command=lambda v, c=ch: self.debounced("gain_" + c, self.send_gain)).grid(
                row=row, column=1, sticky="ew")
            row += 1
        self.swap_var = tk.BooleanVar(value=False)
        ttk.Checkbutton(panel, text="R/B 通道互换", variable=self.swap_var,
                        command=self.send_swap).grid(row=row, column=0, columnspan=2, sticky="w", padx=6)
        row += 1

        ttk.Separator(panel).grid(row=row, column=0, columnspan=2, sticky="ew", pady=4)
        row += 1
        ttk.Label(panel, text="白平衡模式").grid(row=row, column=0, columnspan=2, sticky="w", padx=6)
        row += 1
        self.wb_var = tk.IntVar(value=1)   # 0=自动(cvp_awb) 1=色温 K
        ttk.Radiobutton(panel, text="自动 (cvp_awb)", variable=self.wb_var, value=0,
                        command=self.send_wb_mode).grid(row=row, column=0, columnspan=2, sticky="w", padx=6)
        row += 1
        ttk.Radiobutton(panel, text="色温 K 值", variable=self.wb_var, value=1,
                        command=self.send_kelvin).grid(row=row, column=0, columnspan=2, sticky="w", padx=6)
        row += 1
        ttk.Label(panel, text="色温 (2500K..10000K)").grid(row=row, column=0, columnspan=2, sticky="w", padx=6)
        row += 1
        self.k_var = tk.IntVar(value=65)   # 单位 100K
        ttk.Scale(panel, from_=25, to=100, variable=self.k_var, orient="horizontal", length=200,
                  command=lambda v: self.debounced("kelvin", self.send_kelvin)).grid(
            row=row, column=0, columnspan=2, padx=6, sticky="ew")
        self.k_lbl = ttk.Label(panel, text="6500K")
        self.k_lbl.grid(row=row + 1, column=0, columnspan=2, sticky="w", padx=6)
        row += 3

        # ---- 状态栏 ----
        self.status = tk.Label(root, text="监听 6000...", anchor="w", fg="darkgreen", bg="#e8f5e9")
        self.status.grid(row=1, column=0, columnspan=2, sticky="ew")

        # ---- 接收 ----
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 64 << 20)
        self.sock.bind(("0.0.0.0", 6000))
        self.sock.settimeout(0.05)

        self.lock = threading.Lock()
        self.frame = np.zeros((H, W, 3), dtype=np.uint8)
        self.got = set()
        self.cur = None
        self.fps = 0.0
        self.complete = 0.0
        self.running = True

        threading.Thread(target=self.rx_loop, daemon=True).start()
        self.update_video()

        root.bind("q", lambda e: self.quit())
        root.bind("s", lambda e: self.snap())

    def snap(self):
        fn = time.strftime("snap_%H%M%S.png")
        with self.lock:
            cv2.imwrite(fn, cv2.cvtColor(self.frame, cv2.COLOR_RGB2BGR))
        self.status.configure(text=f"已保存 {fn}", fg="darkblue")

    def quit(self):
        self.running = False
        time.sleep(0.1)
        self.root.destroy()

    # ---------- 接收线程 ----------
    def rx_loop(self):
        fps_t = time.perf_counter()
        fps_n = 0
        while self.running:
            try:
                d, a = self.sock.recvfrom(65536)
            except socket.timeout:
                continue
            if len(d) < 6 or d[1] != 1:
                continue
            seq = d[0]
            off = int.from_bytes(d[2:6], "big")
            idx = off // DB
            with self.lock:
                if seq != self.cur:
                    self.cur = seq
                    self.got = set()
                if idx < CHUNKS and idx not in self.got:
                    self.got.add(idx)
                    self.frame.reshape(-1)[off:off + DB] = np.frombuffer(d[6:6 + DB], dtype=np.uint8)
                self.complete = len(self.got) / CHUNKS * 100
            fps_n += 1
            now = time.perf_counter()
            if now - fps_t >= 1.0:
                self.fps = (fps_n / (now - fps_t)) / CHUNKS
                fps_n = 0
                fps_t = now

    # ---------- 视频刷新(主线程) ----------
    def update_video(self):
        with self.lock:
            img = self.frame.copy()
            complete = self.complete
        disp = cv2.cvtColor(img, cv2.COLOR_RGB2BGR)
        cv2.putText(disp, f"{self.fps:4.1f} fps  complete={complete:.0f}%",
                    (10, 30), cv2.FONT_HERSHEY_SIMPLEX, 0.9, (0, 255, 0), 2)
        from PIL import Image, ImageTk
        self.photo = ImageTk.PhotoImage(image=Image.fromarray(disp))
        self.video.configure(image=self.photo)
        self.status.configure(
            text=f"{self.fps:4.1f} fps | complete={complete:.0f}% | 曝光 {int(self.exp_var.get())} 半行")
        if self.running:
            self.root.after(33, self.update_video)

    # ---------- 命令 ----------
    def _send(self, cmd, value):
        pkt = MAGIC + bytes([cmd]) + (value & 0xFFFFFF).to_bytes(3, "big")
        self.sock.sendto(pkt, TARGET)

    def debounced(self, key, fn, delay=250):
        """拖动停止 250ms 后执行一次(防抖)"""
        if key in self._deb:
            self.root.after_cancel(self._deb[key])
        self._deb[key] = self.root.after(delay, fn)

    def send_exp(self):
        v = int(self.exp_var.get())
        self._send(1, v)
        self.exp_lbl.configure(text=f"{v} 半行 ({v//2} 行)")

    def send_mode(self):
        self._send(0, int(self.mode_var.get()))

    def send_gain(self):
        for cmd, ch in ((2, "R"), (3, "G"), (4, "B")):
            self._send(cmd, int(self.gain_vars[ch].get()))
            time.sleep(0.005)

    def send_swap(self):
        self._send(5, 1 if self.swap_var.get() else 0)

    def send_wb_mode(self):
        v = int(self.wb_var.get())
        # 语义换算: 板上 cmd6=1 为自动 AWB 使能, 0=冻结(手动 K)。GUI wb_var 0=自动 1=手动 K
        self._send(6, 0 if v else 1)
        if v == 1:
            self._send(7, int(self.k_var.get()))   # K 模式: 立即带上色温值
        self.status.configure(text=f"白平衡模式 = {'自动' if v==0 else '色温 K'}", fg="darkblue")

    def send_kelvin(self):
        # 总是同时发模式切换(冻结自动 AWB) + K 值
        self.wb_var.set(1)
        self._send(6, 0)                      # 板值 0 = 冻结自动 AWB(手动 K)
        k = int(self.k_var.get())
        self._send(7, k)
        self.k_lbl.configure(text=f"{k*100}K")


def main():
    root = tk.Tk()
    App(root)
    root.mainloop()


if __name__ == "__main__":
    main()

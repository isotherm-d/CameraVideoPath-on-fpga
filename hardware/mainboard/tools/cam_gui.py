#!/usr/bin/env python3
"""v25 complete-frame RGB viewer and preset/K/manual white balance."""
import socket
import threading
import time
import tkinter as tk
from tkinter import ttk
from pathlib import Path

import cv2
import numpy as np
from PIL import Image, ImageTk
from camera_commands import CameraCommands
from color_model import load_profile, temperature_gains
from frame_tools import FrameAssembler

W, H = 1280, 720
MODES = ("preset", "kelvin", "rgb")


class App:
    def __init__(self, root):
        self.root, self.profile = root, load_profile()
        root.title("MLKPAI-F02 相机 v25 - 1280x720@30fps")
        root.resizable(False, False)
        root.protocol("WM_DELETE_WINDOW", self.quit)
        self._deb = {}
        self.video = tk.Label(root, bg="black")
        self.video.grid(row=0, column=0, padx=2, pady=2)
        panel = ttk.LabelFrame(root, text="相机控制")
        panel.grid(row=0, column=1, sticky="ns", padx=4, pady=4)
        row = 0

        def label(text):
            nonlocal row
            ttk.Label(panel, text=text).grid(row=row, column=0, columnspan=3, sticky="w", padx=6)
            row += 1

        label("曝光码（62～1800 半行）")
        self.exp_var = tk.IntVar(value=self.profile["default_exposure"])
        ttk.Scale(panel, from_=62, to=1800, variable=self.exp_var, length=240,
                  command=lambda v: self.debounced("exp", self.send_exp)).grid(
                      row=row, column=0, columnspan=3, padx=6, sticky="ew")
        row += 1
        self.exp_lbl = ttk.Label(panel)
        self.exp_lbl.grid(row=row, column=0, columnspan=3, sticky="w", padx=6)
        row += 1
        self.update_exp_label()
        label("白平衡模式")
        self.wb_var = tk.IntVar(value=0)
        for value, text in enumerate(("标定预设", "色温 K 值", "手动 RGB")):
            ttk.Radiobutton(panel, text=text, variable=self.wb_var, value=value,
                            command=self.send_wb_mode).grid(
                                row=row, column=0, columnspan=3, sticky="w", padx=6)
            row += 1
        label("色温（2500K～10000K）")
        self.k_var = tk.IntVar(value=self.profile["reference_kelvin"] // 100)
        ttk.Scale(panel, from_=25, to=100, variable=self.k_var, length=240,
                  command=lambda v: self.debounced("kelvin", self.send_kelvin)).grid(
                      row=row, column=0, columnspan=3, padx=6, sticky="ew")
        row += 1
        self.k_lbl = ttk.Label(panel)
        self.k_lbl.grid(row=row, column=0, columnspan=3, sticky="w", padx=6)
        row += 1
        label("手动 RGB 增益（256＝1.0×）")
        self.gain_vars, self.gain_labels = {}, {}
        for ch, default in zip("RGB", self.profile["base_gains_q8"]):
            ttk.Label(panel, text=ch).grid(row=row, column=0, padx=6)
            self.gain_vars[ch] = tk.IntVar(value=default)
            ttk.Scale(panel, from_=64, to=511, variable=self.gain_vars[ch], length=150,
                      command=lambda v, c=ch: self.debounced("gain_" + c, self.send_gain)).grid(
                          row=row, column=1, sticky="ew")
            self.gain_labels[ch] = ttk.Label(panel, width=12)
            self.gain_labels[ch].grid(row=row, column=2, padx=4)
            row += 1
        self.swap_var = tk.BooleanVar(value=False)
        ttk.Checkbutton(panel, text="R/B 通道互换（所有模式）", variable=self.swap_var,
                        command=self.send_swap).grid(row=row, column=0, columnspan=3, sticky="w", padx=6)
        row += 1
        self.effective_lbl = ttk.Label(panel, wraplength=270)
        self.effective_lbl.grid(row=row, column=0, columnspan=3, sticky="w", padx=6, pady=6)
        row += 1
        ttk.Button(panel, text="应用全部参数", command=self.apply_all).grid(
            row=row, column=0, columnspan=3, padx=6, pady=4, sticky="ew")
        row += 1
        self.command_lbl = ttk.Label(panel, text="UDP 6001；参数未回读", wraplength=270)
        self.command_lbl.grid(row=row, column=0, columnspan=3, sticky="w", padx=6)
        self.refresh_gain_labels()
        self.status = ttk.Label(root, text="等待完整帧…", anchor="w")
        self.status.grid(row=1, column=0, columnspan=2, sticky="ew")

        self.control = CameraCommands()
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        if hasattr(socket, "SO_EXCLUSIVEADDRUSE"):
            self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 64 << 20)
        self.sock.bind(("0.0.0.0", 6000))
        self.sock.settimeout(.1)
        self.lock = threading.Lock()
        self.frame = np.zeros((H, W, 3), dtype=np.uint8)
        self.fps = self.complete = self.last_frame_time = 0.0
        self.rx_error = ""
        self.running = True
        threading.Thread(target=self.rx_loop, daemon=True).start()
        root.bind("s", lambda e: self.snap())
        root.bind("q", lambda e: self.quit())
        root.bind("<Escape>", lambda e: self.quit())
        self.update_video()

    def update_exp_label(self):
        v = int(self.exp_var.get())
        self.exp_lbl.configure(text=f"{v} 半行（{v / 2:g} 行）")

    def refresh_gain_labels(self):
        for ch in "RGB":
            v = int(self.gain_vars[ch].get())
            self.gain_labels[ch].configure(text=f"{v} / {v / 256:.2f}×")
        k = int(self.k_var.get()) * 100
        self.k_lbl.configure(text=f"{k}K")
        mode = MODES[int(self.wb_var.get())]
        if mode == "rgb":
            gains = [int(self.gain_vars[c].get()) for c in "RGB"]
        else:
            gains = temperature_gains(self.profile["reference_kelvin"] if mode == "preset" else k, self.profile)
        self.effective_lbl.configure(text="所选模式增益 R/G/B：" + "/".join(map(str, gains)))

    def debounced(self, key, fn, delay=250):
        if key in self._deb:
            self.root.after_cancel(self._deb.pop(key))
        def run():
            self._deb.pop(key, None)
            fn()
        self._deb[key] = self.root.after(delay, run)

    def cancel_wb_callbacks(self):
        for key in tuple(self._deb):
            if key != "exp":
                self.root.after_cancel(self._deb.pop(key))

    def transmit(self, action):
        try:
            action()
        except OSError as error:
            self.command_lbl.configure(text=f"发送失败：{error}")
            return False
        self.command_lbl.configure(text="参数已发送；板端未回读")
        return True

    def send_exp(self):
        self.update_exp_label()
        return self.transmit(lambda: self.control.exposure(int(self.exp_var.get())))

    def send_wb_mode(self):
        self.cancel_wb_callbacks()
        self.refresh_gain_labels()
        mode = MODES[int(self.wb_var.get())]
        return self.transmit(lambda: self.control.white_balance(
            mode, int(self.k_var.get()) * 100, tuple(int(self.gain_vars[c].get()) for c in "RGB")))

    def send_gain(self):
        self.wb_var.set(2)
        self.send_wb_mode()

    def send_kelvin(self):
        self.wb_var.set(1)
        self.send_wb_mode()

    def send_swap(self):
        return self.transmit(lambda: self.control.swap(self.swap_var.get()))

    def apply_all(self):
        if self.send_exp() and self.send_wb_mode():
            self.send_swap()

    def rx_loop(self):
        receiver = FrameAssembler()
        start, frames = time.monotonic(), 0
        while self.running:
            try:
                packet, address = self.sock.recvfrom(65536)
            except socket.timeout:
                continue
            except OSError as error:
                if self.running:
                    self.rx_error = str(error)
                return
            if address[0] != "192.168.1.66":
                continue
            frame = receiver.accept(packet)
            if frame is not None:
                now = time.monotonic()
                frames += 1
                with self.lock:
                    self.frame = frame
                    self.complete = receiver.complete_percent
                    self.last_frame_time = now
                    if now - start >= 1:
                        self.fps = frames / (now - start)
                        start, frames = now, 0

    def update_video(self):
        with self.lock:
            img, fps, complete, last = self.frame.copy(), self.fps, self.complete, self.last_frame_time
        stale = time.monotonic() - last > 1
        cv2.putText(img, f"{0 if stale else fps:4.1f} fps  complete={complete:.0f}%",
                    (10, 30), cv2.FONT_HERSHEY_SIMPLEX, .9, (0, 255, 0), 2)
        # UDP and Pillow both use RGB. OpenCV RGB2BGR is only needed for imwrite.
        self.photo = ImageTk.PhotoImage(Image.fromarray(img))
        self.video.configure(image=self.photo)
        self.status.configure(text=self.rx_error or (
            "等待完整帧；请确认只有一个收图程序" if stale else
            f"{fps:.1f} fps | 完整帧比例 {complete:.1f}% | s 保存原始 RGB 图像"))
        if self.running:
            self.root.after(33, self.update_video)

    def snap(self):
        if not self.last_frame_time:
            self.command_lbl.configure(text="尚未收到完整帧")
            return
        path = Path.cwd() / time.strftime("snap_%Y%m%d_%H%M%S.png")
        with self.lock:
            img = self.frame.copy()
        Image.fromarray(img).save(path)
        self.command_lbl.configure(text=f"已保存：{path.name}")

    def quit(self):
        self.running = False
        for callback in self._deb.values():
            self.root.after_cancel(callback)
        self.sock.close()
        self.control.close()
        self.root.destroy()


def main():
    root = tk.Tk()
    try:
        App(root)
    except OSError as error:
        root.destroy()
        raise SystemExit(f"无法打开收图窗口，请关闭其他收图程序：{error}") from error
    root.mainloop()


if __name__ == "__main__":
    main()

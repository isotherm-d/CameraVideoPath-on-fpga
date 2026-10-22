"""1280x720@30fps V26 viewer: seven modes, AE/AWB, confirmed status and latency."""
import collections
import socket
import threading
import time
import tkinter as tk
from tkinter import ttk
from pathlib import Path
import cv2
import numpy as np
from PIL import Image,ImageTk,ImageDraw,ImageFont
from frame_tools import FrameAssembler
from v26_client import V26Control
from v26_protocol import MODE_NAMES

class App:
    CONTROL_CLASS=V26Control
    WINDOW_TITLE="MLKPAI-F02 v26 - 1280x720@30fps"
    CAPTURE_PREFIX='v26'
    def extra_controls(self,panel):pass
    def create_panel(self,root):
        panel=ttk.LabelFrame(root,text="算法与自动图像调节")
        panel.grid(row=0,column=1,sticky="ns",padx=6)
        return panel
    def __init__(self,root):
        self.root=root
        root.title(self.WINDOW_TITLE)
        root.protocol("WM_DELETE_WINDOW",self.quit)
        self.video=tk.Label(root,bg="black")
        self.video.grid(row=0,column=0,padx=2,pady=2)
        panel=self.create_panel(root)
        self.row=0
        self.callbacks={}
        def label(text):
            ttk.Label(panel,text=text).grid(row=self.row,column=0,columnspan=3,sticky="w",padx=6)
            self.row+=1
        label("图像算法（按键可向前/向后切换）")
        self.mode=ttk.Combobox(panel,values=MODE_NAMES,state="readonly",width=28)
        self.mode.current(0)
        self.mode.grid(row=self.row,column=0,columnspan=3,padx=6,sticky="ew");self.row+=1
        self.mode.bind("<<ComboboxSelected>>",lambda e:self.submit({0:self.mode.current()}))
        self.ae=tk.BooleanVar(value=True)
        self.toggle(panel,"自动曝光",self.ae,lambda:self.submit({1:int(self.ae.get())}))
        self.exp=self.scale(panel,"手动曝光设定（半行，62～1800）",62,1800,500,lambda:self.manual_exposure())
        self.sensor_gain=self.scale(panel,"手动模拟增益（档位16～143）",16,143,108,lambda:self.manual_gain())
        label("白平衡模式")
        self.wb=ttk.Combobox(panel,values=("标定预设","色温 K","手动 RGB","自动场景"),state="readonly",width=28)
        self.wb.current(0)
        self.wb.grid(row=self.row,column=0,columnspan=3,padx=6,sticky="ew");self.row+=1
        self.wb.bind("<<ComboboxSelected>>",lambda e:self.submit({2:self.wb.current()}))
        self.k=self.scale(panel,"色温（K，近似标定曲线）",2500,10000,6500,self.manual_temperature)
        self.gains=[self.scale(panel,f"手动 {c} 增益设定 Q8（256=1倍）",64,1024,d,self.manual_rgb)
                    for c,d in zip("RGB",(344,256,451))]
        self.swap=tk.BooleanVar(value=False)
        self.toggle(panel,"R/B 通道互换",self.swap,lambda:self.submit({9:int(self.swap.get())}))
        self.tone=tk.BooleanVar(value=False)
        self.toggle(panel,"显示支路自动对比度",self.tone,lambda:self.submit({10:int(self.tone.get())}))
        self.osd=tk.BooleanVar(value=True)
        self.toggle(panel,"FPGA 状态文字",self.osd,lambda:self.submit({11:int(self.osd.get())}))
        self.extra_controls(panel)
        ttk.Button(panel,text="应用全部设置",command=self.apply_all).grid(row=self.row,column=0,columnspan=3,padx=6,sticky="ew");self.row+=1
        self.actual=ttk.Label(panel,text="等待板端回读",wraplength=300,justify="left")
        self.actual.grid(row=self.row,column=0,columnspan=3,sticky="w",padx=6,pady=8);self.row+=1
        self.command=ttk.Label(panel,text="等待连接",wraplength=300,justify="left")
        self.command.grid(row=self.row,column=0,columnspan=3,sticky="w",padx=6)
        self.status=ttk.Label(root,text="等待完整帧…",wraplength=1550)
        self.status.grid(row=1,column=0,columnspan=2,sticky="w")
        self.control=self.CONTROL_CLASS()
        try:self.overlay_font=ImageFont.truetype('C:/Windows/Fonts/msyh.ttc',20)
        except OSError:self.overlay_font=None
        self.sock=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
        if hasattr(socket,"SO_EXCLUSIVEADDRUSE"):
            self.sock.setsockopt(socket.SOL_SOCKET,socket.SO_EXCLUSIVEADDRUSE,1)
        self.sock.setsockopt(socket.SOL_SOCKET,socket.SO_RCVBUF,64<<20)
        self.sock.bind(("",6000));self.sock.settimeout(.1)
        self.lock=threading.Lock();self.frame=None;self.record=None
        self.running=True;self.fps=0.;self.complete=0.;self.rx_error=""
        self.delays=collections.deque(maxlen=120)
        self.last_measurement=None
        self.submissions=collections.OrderedDict()
        threading.Thread(target=self.receive,daemon=True).start()
        root.bind("s",lambda e:self.snap());root.bind("q",lambda e:self.quit());root.bind("<Escape>",lambda e:self.quit())
        self.update()
    def toggle(self,panel,text,var,action):
        ttk.Checkbutton(panel,text=text,variable=var,command=action).grid(row=self.row,column=0,columnspan=3,sticky="w",padx=6)
        self.row+=1
    def scale(self,panel,text,lo,hi,default,action):
        ttk.Label(panel,text=text).grid(row=self.row,column=0,columnspan=3,sticky="w",padx=6);self.row+=1
        v=tk.IntVar(value=default)
        value_label=ttk.Label(panel,text=str(default),width=5)
        def changed(_):
            value_label.configure(text=str(v.get()))
            key=id(v)
            if key in self.callbacks:self.root.after_cancel(self.callbacks[key])
            def send():
                self.callbacks.pop(key,None);action()
            self.callbacks[key]=self.root.after(250,send)
        ttk.Scale(panel,from_=lo,to=hi,variable=v,length=230,command=changed).grid(row=self.row,column=0,columnspan=2,padx=6)
        value_label.grid(row=self.row,column=2);self.row+=1
        return v
    def submit(self,fields):self.control.configure(fields)
    def manual_exposure(self):
        self.ae.set(False);self.submit({1:0,3:self.exp.get()})
    def manual_gain(self):
        self.ae.set(False);self.submit({1:0,4:self.sensor_gain.get()})
    def manual_temperature(self):
        self.wb.current(1);self.submit({2:1,5:round(self.k.get()/100)})
    def manual_rgb(self):
        self.wb.current(2);self.submit({2:2,6:self.gains[0].get(),7:self.gains[1].get(),8:self.gains[2].get()})
    def apply_all(self):
        for callback in self.callbacks.values():self.root.after_cancel(callback)
        self.callbacks.clear()
        self.submit({0:self.mode.current(),1:int(self.ae.get()),2:self.wb.current(),3:self.exp.get(),4:self.sensor_gain.get(),
                     5:round(self.k.get()/100),6:self.gains[0].get(),7:self.gains[1].get(),8:self.gains[2].get(),
                     9:int(self.swap.get()),10:int(self.tone.get()),11:int(self.osd.get())})
    def receive(self):
        assembler=FrameAssembler()
        first_ns=0;start=time.monotonic();count=0
        while self.running:
            try:packet,addr=self.sock.recvfrom(65536);now=time.monotonic_ns()
            except socket.timeout:continue
            except OSError as error:
                if self.running:self.rx_error=str(error)
                return
            if addr[0]!="192.168.1.66":continue
            before=assembler.sequence
            frame=assembler.accept(packet,now/1e9)
            if assembler.sequence!=before:first_ns=now
            if frame is not None:
                count+=1;clock=now/1e9
                with self.lock:
                    self.frame=frame
                    self.record={"sequence":assembler.sequence,"complete_ns":now,"first_ns":first_ns,
                                 "assembly_ms":(now-first_ns)/1e6}
                    self.complete=assembler.complete_percent
                    if clock-start>=1:
                        self.fps=count/(clock-start);count=0;start=clock
    def update(self):
        with self.lock:
            frame=None if self.frame is None else self.frame.copy()
            rec=None if self.record is None else dict(self.record)
        now=time.monotonic_ns();state=self.control.snapshot()
        metadata=None if rec is None else self.control.frame_metadata(rec["sequence"],rec["complete_ns"])
        fresh=rec is not None and now-rec["complete_ns"]<1e9
        if frame is None:frame=np.zeros((720,1280,3),dtype=np.uint8)
        if state and state["flags"]&32:
            frame[:]=0
        estimated=None;lat_text="端到端估计：等待时钟同步/匹配帧元数据"
        if metadata and not metadata["flags"]&32:
            processing=(metadata["process_tick"]-metadata["capture_tick"])/100000
            if processing<0:processing=float("nan")
            lat_text=f"帧 {metadata['frame_id']} | FPGA 帧首→处理 {processing:.3f} ms | 拼帧 {rec['assembly_ms']:.2f} ms"
            if "matched_tx_tick" in metadata:
                tx_ms=(metadata["matched_tx_tick"]-metadata["capture_tick"])/100000
                lat_text+=f" | FPGA 帧首→发完 {tx_ms:.2f} ms"
            # Detection boxes and class names are already baked into FPGA RGB.
            # Diagnostic result packets continue while SW1 hides that overlay;
            # repainting them here would bypass SW1 and create flashing boxes.
        text=f"{self.fps if fresh else 0:.1f} fps complete={self.complete:.0f}%"
        if metadata:text+=f" {MODE_NAMES[metadata['mode']] if metadata['mode']<7 else '?'} F{metadata['frame_id']}"
        display=Image.fromarray(frame)
        if self.overlay_font:
            ImageDraw.Draw(display).text((8,43),text,font=self.overlay_font,fill=(0,255,0),stroke_width=1)
        else:
            names=('ORIG','GRAY','BINARY','EDGE','CARTOON','SKETCH','SEPIA')
            text=f"{self.fps if fresh else 0:.1f} fps complete={self.complete:.0f}%"
            if metadata:text+=f" {names[metadata['mode']] if metadata['mode']<7 else 'UNKNOWN'} F{metadata['frame_id']}"
            fallback=np.asarray(display).copy();cv2.putText(fallback,text,(8,60),cv2.FONT_HERSHEY_SIMPLEX,.65,(0,255,0),2);display=Image.fromarray(fallback)
        self.photo=ImageTk.PhotoImage(display)
        submitted_now=time.monotonic_ns()
        self.video.configure(image=self.photo)
        if fresh:
            self.submissions.setdefault(rec["complete_ns"],submitted_now)
            while len(self.submissions)>8:self.submissions.popitem(last=False)
        if metadata and not metadata["flags"]&32:
            submitted=self.submissions.get(rec["complete_ns"],submitted_now)
            estimated=self.control.estimated_submission(metadata,submitted)
            if estimated:
                delay,error=estimated
                lat_text+=f" | 采集→显示提交估计 {delay:.2f} ±{error:.2f} ms"
                key=(metadata["frame_id"],rec["complete_ns"])
                if key!=self.last_measurement:
                    self.delays.append(delay);self.last_measurement=key
                lat_text+=f" | 平均 {np.mean(self.delays):.2f} / P95 {np.percentile(self.delays,95):.2f} ms"
        if state and state["flags"]&32:
            lat_text=("数据流异常，等待连续完整帧恢复" if state.get('stream_diag_version')==1
                      else "数据流异常，已停止显示；请复位采集")

        if state:
            stale=now-state["received_ns"]>1e9
            if stale:self.actual.configure(text="板端状态超时")
            else:
                flags=state["flags"]
                self.actual.configure(text=f"实际配置 {state['cfg_id']}，图像配置 {state['frame_cfg_id']}\n"
                    f"已写曝光 {state['sensor_exp']} 半行；增益档 {state['sensor_gain']}\n"
                    f"实际 R/G/B：{state['gain_r']}/{state['gain_g']}/{state['gain_b']}\n"
                    f"平均亮度 {state['mean']}；AWB {('关闭','工作','冻结')[min(state['awb_state'],2)]}\n"
                    f"传感器：{'忙' if flags&8 else '空闲'}；{'I2C错误' if flags&16 else '正常'}\n"
                    f"流错误 {state['stream_errors']}，传感器错误 {state['sensor_errors']}")
        self.command.configure(text=self.control.notice)
        self.status.configure(text=self.rx_error or (
            "未收到完整帧；确认匹配 v26 比特流、网线及只有一个收图程序" if not fresh else lat_text))
        if self.running:self.root.after(33,self.update)
    def snap(self):
        with self.lock:
            if self.frame is None:return
            frame=self.frame.copy()
        folder=Path.cwd()/"captures"
        folder.mkdir(exist_ok=True)
        p=folder/time.strftime(self.CAPTURE_PREFIX+"_%Y%m%d_%H%M%S.png")
        Image.fromarray(frame).save(p)
        self.control.notice=f"已保存 FPGA 输出：{p.name}"
    def quit(self):
        self.running=False
        for cb in self.callbacks.values():self.root.after_cancel(cb)
        self.control.close();self.sock.close();self.root.destroy()

def main():
    root=tk.Tk()
    try:App(root)
    except OSError as error:
        root.destroy()
        raise SystemExit(f"无法打开窗口，请关闭其他收图程序：{error}")
    root.mainloop()
if __name__=="__main__":main()

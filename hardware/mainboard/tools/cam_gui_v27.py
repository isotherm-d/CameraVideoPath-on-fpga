"""V27 viewer: independent thresholds, calibrated AWB and classified I2C status."""
import tkinter as tk
import time
from tkinter import ttk
from cam_gui_v26 import App as BaseApp
from v27_client import V27Control
from v27_protocol import profile_fields,DEFAULT_PROFILES,stream_error_text

class App(BaseApp):
    CONTROL_CLASS=V27Control
    WINDOW_TITLE='MLKPAI-F02 v27 - 1280x720@30fps'
    CAPTURE_PREFIX='v27'
    def __init__(self,root):
        self._ready=False
        super().__init__(root)
        self.mode.bind('<<ComboboxSelected>>',self.mode_changed)
        self._ready=True
        self.show_profile(self.mode.current())

    def create_panel(self,root):
        outer=ttk.Frame(root);outer.grid(row=0,column=1,sticky='ns',padx=6)
        canvas=tk.Canvas(outer,width=350,height=720,highlightthickness=0)
        scroll=ttk.Scrollbar(outer,orient='vertical',command=canvas.yview)
        canvas.configure(yscrollcommand=scroll.set)
        canvas.pack(side='left',fill='both',expand=True);scroll.pack(side='right',fill='y')
        panel=ttk.LabelFrame(canvas,text='算法与自动图像调节（可向下滚动）')
        item=canvas.create_window((0,0),window=panel,anchor='nw')
        panel.bind('<Configure>',lambda e:canvas.configure(scrollregion=canvas.bbox('all')))
        canvas.bind('<Configure>',lambda e:canvas.itemconfigure(item,width=e.width))
        return panel

    def extra_controls(self,panel):
        self.profiles=dict(DEFAULT_PROFILES);self.profile_mode=3;self.threshold_job=None;self.loading=False
        self.high=tk.IntVar(value=130);self.low=tk.IntVar(value=65);self.stroke=tk.IntVar(value=1);self.link=tk.BooleanVar(value=True)
        group=ttk.LabelFrame(panel,text='轮廓阈值（边缘 / 素描各自记忆）')
        group.grid(row=self.row,column=0,columnspan=3,sticky='ew',padx=6,pady=5);self.row+=1
        self.threshold_group=group
        ttk.Label(group,text='主轮廓阈值：越小，细节越多').grid(row=0,column=0,columnspan=2,sticky='w')
        ttk.Scale(group,from_=1,to=512,variable=self.high,command=lambda _:self.edge_changed()).grid(row=1,column=0,sticky='ew')
        high_spin=ttk.Spinbox(group,from_=1,to=2040,textvariable=self.high,width=6,command=self.edge_changed)
        high_spin.grid(row=1,column=1)
        high_spin.bind('<Return>',lambda e:self.edge_changed());high_spin.bind('<FocusOut>',lambda e:self.edge_changed())
        ttk.Checkbutton(group,text='低阈值联动为主阈值的50%',variable=self.link,command=self.edge_changed).grid(row=2,column=0,columnspan=2,sticky='w')
        ttk.Label(group,text='高级：低阈值').grid(row=3,column=0,sticky='w')
        self.low_spin=ttk.Spinbox(group,from_=1,to=2040,textvariable=self.low,width=6,command=self.edge_changed)
        self.low_spin.grid(row=3,column=1)
        self.low_spin.bind('<Return>',lambda e:self.edge_changed());self.low_spin.bind('<FocusOut>',lambda e:self.edge_changed())
        ttk.Radiobutton(group,text='细线',variable=self.stroke,value=1,command=self.edge_changed).grid(row=4,column=0,sticky='w')
        ttk.Radiobutton(group,text='加粗',variable=self.stroke,value=2,command=self.edge_changed).grid(row=4,column=1,sticky='w')
        ttk.Button(group,text='恢复本模式推荐值',command=self.restore_profile).grid(row=5,column=0,columnspan=2,sticky='ew')
        self.low_spin.configure(state='disabled')

    def show_profile(self,mode):
        if mode not in (3,5):self.threshold_group.grid_remove();return
        self.threshold_group.grid();self.profile_mode=mode;self.loading=True
        low,high,width=self.profiles[mode]
        self.low.set(low);self.high.set(high);self.stroke.set(width)
        self.link.set(low==max(1,high//2))
        self.low_spin.configure(state='disabled' if self.link.get() else 'normal')
        self.loading=False

    def edge_changed(self):
        if self.loading:return
        try:
            high=self.high.get()
            if self.link.get():self.low.set(max(1,high//2))
            self.low_spin.configure(state='disabled' if self.link.get() else 'normal')
            profile_fields(self.profile_mode,self.low.get(),high,self.stroke.get())
            self.profiles[self.profile_mode]=(self.low.get(),high,self.stroke.get())
        except (ValueError,tk.TclError) as error:
            if hasattr(self,'control'):self.control.notice=str(error)
            return
        if self.threshold_job:self.root.after_cancel(self.threshold_job)
        self.threshold_job=self.root.after(250,self.send_thresholds)

    def send_thresholds(self):
        if self.threshold_job:self.root.after_cancel(self.threshold_job);self.threshold_job=None
        self.submit(profile_fields(self.profile_mode,*self.profiles[self.profile_mode]))

    def restore_profile(self):
        self.profiles[self.profile_mode]=DEFAULT_PROFILES[self.profile_mode]
        self.show_profile(self.profile_mode);self.send_thresholds()

    def mode_changed(self,event=None):
        if self.threshold_job:self.send_thresholds()
        mode=self.mode.current();self.show_profile(mode);self.submit({0:mode})

    def apply_all(self):
        if self.threshold_job:self.send_thresholds()
        super().apply_all()

    def update(self):
        super().update()
        if not self._ready:return
        state=self.control.snapshot()
        if not state:return
        if time.monotonic_ns()-state['received_ns']>1_000_000_000:return
        if state.get('firmware')!=27:
            self.actual.configure(text='已连接 v26；请先下载 v27 比特流后使用新控件。');return
        busy='待提交' in self.control.notice or '等待板端' in self.control.notice
        if not busy and not self.threshold_job and state['frame_cfg_id']==state['cfg_id']:
            self.profiles[3]=(state['edge_low'],state['edge_high'],state['edge_width'])
            self.profiles[5]=(state['sketch_low'],state['sketch_high'],state['sketch_width'])
            if state['mode']!=self.mode.current():
                self.mode.current(state['mode']);self.show_profile(state['mode'])
            self.ae.set(bool(state['flags']&1));self.wb.current(state['wb_mode'])
            self.tone.set(bool(state['flags']&2));self.osd.set(bool(state['flags']&4))
        flags=state['diag_flags']
        init='失败' if flags&1 else '完成' if flags&8 else '等待/配置中'
        current='进行中，等待确认' if state['flags']&8 else '超时' if flags&4 else 'NACK' if flags&2 else '正常'
        recovery='（重试后已恢复）' if flags&16 else ''
        reasons={0:'关闭',1:'可信样本，小幅校正',2:'样本不足，保持',3:'区域覆盖不足，保持'}
        failure='无' if state['last_error_code']==0 else (
            f"{'启动' if flags&64 else '运行期'} 0x{state['last_register']:04X}，字节{state['last_byte']}，"
            f"{('NACK' if state['last_error_code']==1 else '超时')}")
        stream_detail=''
        if state.get('stream_diag_version')==1:
            stream_detail=(f"\n流状态：{'恢复等待' if state['flags']&32 else '正常'}；"
                           f"最近：{stream_error_text(state['stream_error_last'])}")
            if state['stream_error_history']&1:
                stream_detail+=f"\n最近异常RAW组数：{state['stream_bad_groups']}（应为230400）"
        if 'ae_digital_gain_q8' in state:
            stream_detail+=f"\nAE数字增益：{state['ae_digital_gain_q8']/256:.3f}倍"
        if 'ae_target_mean' in state:
            stream_detail+=f"\n硬件 v{state['hardware_build']}；AE目标亮度：{state['ae_target_mean']}"
        self.actual.configure(text=
            f"实际配置 {state['cfg_id']}，图像配置 {state['frame_cfg_id']}\n"
            f"实际已写曝光 {state['sensor_exp']} 半行；模拟增益档 {state['sensor_gain']}\n"
            f"实际 R/G/B：{state['gain_r']}/{state['gain_g']}/{state['gain_b']}\n"
            f"平均亮度 {state['mean']}；AWB {reasons.get(state['awb_reason'],'状态未知')}\n"
            f"中性样本 {state['neutral_count']}；区域掩码 {state['awb_regions']:X}\n"
            f"初始化：{init}{recovery}；启动重试 {state['init_retries']}\n"
            f"当前参数写入：{current}；历史NACK {state['runtime_nacks']} / 超时 {state['runtime_timeouts']}\n"
            f"最近失败：{failure}\n"
            f"边缘低/高：{state['edge_low']}/{state['edge_high']}；素描：{state['sketch_low']}/{state['sketch_high']}\n"
            f"流错误 {state['stream_errors']}，失败写入请求 {state['sensor_errors']}"+stream_detail)

    def quit(self):
        if self.threshold_job:self.root.after_cancel(self.threshold_job);self.threshold_job=None
        super().quit()

def main():
    root=tk.Tk()
    try:App(root)
    except OSError as error:
        root.destroy();raise SystemExit(f'无法打开窗口，请关闭其他收图程序：{error}')
    root.mainloop()
if __name__=='__main__':main()

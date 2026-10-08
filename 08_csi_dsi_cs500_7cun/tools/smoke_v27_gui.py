import tkinter as tk
from cam_gui_v27 import App

class Fake:
    def __init__(self):self.sent=[];self.notice='test';self.current=None
    def configure(self,fields):self.sent.append(fields)
    def snapshot(self):return self.current
    def close(self):pass
root=tk.Tk();root.withdraw();App.CONTROL_CLASS=Fake
app=App(root)
app.mode.current(3);app.mode_changed();app.high.set(100);app.edge_changed();app.send_thresholds()
assert app.control.sent[-1]=={13:50,14:100,17:1}
app.mode.current(5);app.mode_changed();app.link.set(False);app.low.set(33);app.high.set(80);app.stroke.set(2);app.edge_changed();app.send_thresholds()
assert app.control.sent[-1]=={15:33,16:80,18:2}
app.mode.current(3);app.mode_changed();assert (app.low.get(),app.high.get(),app.stroke.get())==(50,100,1)
app.restore_profile();assert app.control.sent[-1]=={13:45,14:90,17:1}
assert app.overlay_font is not None,'Chinese font unavailable'
assert bytes(app.overlay_font.getmask('边缘'))!=bytes(app.overlay_font.getmask('??'))
app.quit();print('PASS hidden v27 threshold independence, linking, restore, Chinese font and shutdown')

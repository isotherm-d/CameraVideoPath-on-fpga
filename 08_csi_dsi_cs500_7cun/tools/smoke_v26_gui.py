import time,tkinter as tk
from cam_gui_v26 import App
root=tk.Tk();root.withdraw()
app=App(root)
sent=[]
app.control.configure=lambda fields:sent.append(fields)
app.mode.current(4);app.mode.event_generate("<<ComboboxSelected>>");root.update()
assert sent[-1]=={0:4}
app.gains[0].set(1024);app.manual_rgb()
assert sent[-1][6]==1024 and sent[-1][2]==2
app.ae.set(True);app.exp.set(700);app.manual_exposure()
assert sent[-1]=={1:0,3:700} and not app.ae.get()
app.k.set(4000);app.manual_temperature()
assert sent[-1]=={2:1,5:40}
app.quit()
print("PASS hidden V26 Tk controls and shutdown")

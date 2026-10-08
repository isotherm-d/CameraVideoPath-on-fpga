"""Hidden real-board GUI rendering check; does not send configuration changes."""
import argparse,json,time,tkinter as tk
from pathlib import Path
from PIL import ImageTk
from cam_gui_v27 import App
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);folder=p.parse_args().output
folder.mkdir(parents=True,exist_ok=True)
root=tk.Tk();root.withdraw();app=App(root);result={}
def finish():
    state=app.control.snapshot()
    result.update(status=state,fps=app.fps,complete=app.complete,actual_text=app.actual.cget('text'),
                  unicode_font=app.overlay_font is not None,ae_checkbox=app.ae.get(),wb_selection=app.wb.current())
    result['passed']=bool(state and state.get('firmware')==27 and app.frame is not None and app.overlay_font and app.complete>=99.9 and not state['flags']&48)
    if app.photo:ImageTk.getimage(app.photo).save(folder/'viewer_render.png')
    (folder/'live_gui.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
    app.quit()
root.after(5000,finish);root.mainloop()
assert result['passed'],result
assert result['ae_checkbox']==bool(result['status']['flags']&1)
assert result['wb_selection']==result['status']['wb_mode']
assert '初始化：完成' in result['actual_text']
print('PASS hidden live V27 GUI: complete frames, Unicode overlay, real diagnostics and readback controls')

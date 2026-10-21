"""Idempotently register the five-class path in the experiment's original .al."""
import re
from pathlib import Path
REPO=Path(__file__).resolve().parents[2]
assert REPO.name=='CameraVideoPath-on-fpga-yolo'
p=REPO/'08_csi_dsi_cs500_7cun/td_project/camera_to_dsi_display.al';text=p.read_text(encoding='utf8')
disabled={'cellnet32_core.v','cvp_cellnet32.v','cvp_roi_rgb32.v','cvp_center_classifier.v','cvp_center_window.v','cvp_class_confirm.v'}
enabled={'cvp_cell_tracks.v','cvp_cell_label.v'}
def rewrite(m):
 block=m[0];name=Path(m[1]).name
 if name in disabled:
  block=re.sub(r'(Name="UsedIn(?:Syn|P&R)" Val=")true',r'\1false',block)
 if name in enabled:
  block=re.sub(r'\s*<Attr Name="AutoExcluded" Val="true"/>','',block)
  block=re.sub(r'(Name="UsedIn(?:Syn|P&R)" Val=")false',r'\1true',block)
 return block
text=re.sub(r'<File Path="([^"]+)"[^>]*>.*?</File>',rewrite,text,flags=re.S)
if 'yolo/cvp_yolo_tracks.v' not in text:
 addition='''            <File Path="../user_source/hdl_source/yolo/cvp_yolo_tracks.v">
                <FileInfo>
                    <Attr Name="UsedInSyn" Val="true"/>
                    <Attr Name="UsedInP&R" Val="true"/>
                    <Attr Name="BelongTo" Val="design_1"/>
                    <Attr Name="CompileOrder" Val="74"/>
                </FileInfo>
            </File>
'''
 text=text.replace('        </Verilog>',addition+'        </Verilog>')
p.write_text(text,encoding='utf8');print('FIVE_ORIGINAL_PROJECT_REGISTERED',p)

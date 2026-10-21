"""Build the existing camera_to_dsi_display mainboard project in its own runs."""
from pathlib import Path
import argparse, hashlib, json, re, subprocess, time
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
model_dir=ROOT/'user_source/hdl_source/yolo'
active=json.loads((model_dir/'model/active_model.json').read_text(encoding='utf8'))
assert active['protocol']['classes']==['BAS','EOS','LYM','MON','NEU'], 'Only the joint five-class YOLO model is allowed'
assert active['protocol']['geometry']=='fullframe'
top=(ROOT/'user_source/hdl_source/design_top_wrapper.v').read_text(encoding='utf8')
assert re.search(r'cvp_yolo160_detector\s*#\(\.FRAME_INTERVAL\(2\)\)\s*u_yolo160',top),'This build requires the 15Hz top-level detector'
assert re.search(r'cvp_yolo_tracks\s*#\([^\n]*\.SINGLE_TARGET\(1\)',top),'Require one selected cell'
assert re.search(r'cvp_cell_label\s*#\(\.N\(1\),\.FULL_NAMES\(1\)\)',top),'Require one box with full English name'
for name,digest in active['assets'].items():
    path=model_dir/name if name.startswith('model/') or name.endswith('.vh') else model_dir/'model'/name
    assert hashlib.sha256(path.read_bytes()).hexdigest()==digest,'YOLO asset mismatch '+name
ap = argparse.ArgumentParser()
ap.add_argument('--route', action='store_true')
ap.add_argument('--name', default='camera_to_dsi_display')
ap.add_argument('--project',type=Path,default=ROOT/'td_project/camera_to_dsi_display.al')
args = ap.parse_args()
assert args.project.resolve() == ROOT/'td_project/camera_to_dsi_display.al', 'Use the existing mainboard project only'
assert args.name == 'camera_to_dsi_display', 'Use the existing mainboard run directory only'
out = ROOT / 'td_project/camera_to_dsi_display_Runs' / ('phy_1' if args.route else 'syn_1')
out.mkdir(parents=True, exist_ok=True)
project = args.project.resolve()
text = project.read_text(encoding='utf-8')
project_name=re.search(r'<Name>([^<]+)</Name>',text)[1]
assert project_name=='camera_to_dsi_display'
# TD's XML-like format has literal P&R attribute values and :: tag names.
tree=ET.fromstring(text.replace('&','&amp;').replace('::','__'))
required={'cvp_cell_label.v','cvp_cell_tracks.v','yolo160_first.v','cvp_yolo_tracks.v',
          'yolo160_core.v','yolo160_boxes.v','cvp_yolo160_detector.v'}
for name in required:
    matches=[f for f in tree.findall('./Source_Files/Verilog/File') if Path(f.attrib['Path']).name==name]
    assert len(matches)==1, 'Missing or duplicate original-project source: '+name
    attrs={a.attrib['Name']:a.attrib['Val'] for a in matches[0].findall('./FileInfo/Attr')}
    assert attrs.get('UsedInSyn')=='true' and attrs.get('UsedInP&R')=='true' and attrs.get('AutoExcluded')!='true', name
for name in {'cellnet32_core.v','cvp_roi_rgb32.v','cvp_center_classifier.v','cvp_cellnet32.v'}:
    matches=[f for f in tree.findall('./Source_Files/Verilog/File') if Path(f.attrib['Path']).name==name]
    assert len(matches)==1
    attrs={a.attrib['Name']:a.attrib['Val'] for a in matches[0].findall('./FileInfo/Attr')}
    assert attrs.get('UsedInSyn')=='false' and attrs.get('UsedInP&R')=='false','Legacy classifier must not be built: '+name
bit_name=project_name+'.bit'
project_file=project_name+'.prj'
def absolute(m):
    return 'Path="' + (project.parent / m[1]).resolve().as_posix() + '"'
text = re.sub(r'Path="([^"]+)"', absolute, text)
# TD command mode resolves XML paths from cwd. This is a generated run cache,
# with the original project name; no additional user-facing .al is created.
(out / project_file).write_text(text, encoding='utf-8')
if (out/'build_result.json').exists():
    (out/'build_result.json').replace(out/('build_result_previous_'+str(time.time_ns())+'.json'))
# TD resolves Verilog include files from the run directory.
for src in (ROOT / 'user_source/hdl_source/classify').glob('*.vh'):
    (out / src.name).write_bytes(src.read_bytes())
for src in (ROOT/'user_source/hdl_source/yolo').glob('*.vh'):
    (out/src.name).write_bytes(src.read_bytes())

tcl = '''import_device ph1_35p.db -package PH1P35MDG324 -speed 3
open_project {%s}
elaborate -top design_top_wrapper
read_adc {%s}
read_sdc {%s}
optimize_rtl
report_area -file rtl.area
optimize_gate -packarea gate.area
legalize_phy_inst
update_timing
report_timing_summary -file gate.timing
report_timing_path -file gate_paths.timing -ep_num 10 -path_num 1
export_db gate.db
''' % (project_file,(ROOT / 'user_source/constraints_source/pin.adc').as_posix(),
       (ROOT / 'td_project/camera_to_dsi_display.sdc').as_posix())
if args.route:
    tcl += '''place
update_timing -mode manhattan
report_area -file place.area
report_timing_summary -file place.timing
export_db place.db
route
report_area -file route.area
update_timing -mode final
report_timing_summary -file route.timing
export_db route.db
bitgen -bit %s
'''
    tcl=tcl % bit_name
tcl += 'exit\n'
(out / 'build.tcl').write_text(tcl, encoding='utf-8')
sources = sorted((ROOT / 'user_source/hdl_source').rglob('*.v'))
sources += sorted((ROOT / 'user_source/hdl_source').rglob('*.vh'))
sources += sorted((ROOT / 'user_source/hdl_source').rglob('*.sv'))
sources += sorted((ROOT / 'user_source/ip_source/PLL').rglob('*.v'))
sources += sorted((ROOT/'user_source/hdl_source/yolo/model').glob('*.hex'))
sources += [project,
            ROOT / 'td_project/camera_to_dsi_display.sdc',ROOT / 'user_source/constraints_source/pin.adc']
sources += [Path(__file__).resolve()]
manifest = {str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
(out / 'source_hashes.json').write_text(json.dumps(manifest,indent=2),encoding='utf-8')
start = time.time()
with (out / 'build.log').open('w',encoding='utf-8') as log:
    p = subprocess.run(['td_commands_prompt.exe'], input='source build.tcl\n',text=True,
                       stdout=log,stderr=subprocess.STDOUT,cwd=out)
log = (out / 'build.log').read_text(encoding='utf-8',errors='replace')
if p.returncode or re.search(r'\b(?:ERROR|FATAL)\b',log):
    raise RuntimeError(f'TD build failed: {out / "build.log"}')
expected = 'route.area' if args.route else 'gate.area'
if not (out / expected).exists():
    raise RuntimeError('TD did not produce the requested final report')
for name in [expected,'route.timing' if args.route else 'gate.timing']+([bit_name] if args.route else []):
    if (out/name).stat().st_mtime < start-1:
        raise RuntimeError('Stale output from an earlier build: '+name)
for key,old_hash in manifest.items():
    if hashlib.sha256((ROOT/key).read_bytes()).hexdigest()!=old_hash:
        raise RuntimeError('Source changed during build: '+key)
area=(out / expected).read_text()
timing=(out / ('route.timing' if args.route else 'gate.timing')).read_text()
metrics={name:int(re.search(r'^#'+name+r'\*?\s+(\d+)',area,re.M)[1])
         for name in ('slice','eram','dsp')}
metrics.update({name:float(re.search(name+r':\s*([-\d.]+)ns',timing)[1])
                for name in ('SWNS','HWNS')})
metrics.update(place_and_route=args.route,board_validated=False,elapsed_seconds=time.time()-start)
metrics.update(video_fps_configured=30,inference_interval_frames=2,YOLO_Hz=15,held_missed_detections=2)
metrics.update(max_display_cells=1,full_English_names=True,selection_policy='keep identity; otherwise nearest center')
if args.route:
    metrics['bit_sha256']=hashlib.sha256((out/bit_name).read_bytes()).hexdigest()
metrics['project']='td_project/camera_to_dsi_display.al'
metrics['bit_path']=str((out/bit_name).relative_to(ROOT)) if args.route else None
(out/'build_result.json').write_text(json.dumps(metrics,indent=2),encoding='utf-8')
if args.route and (metrics['SWNS']<0 or metrics['HWNS']<0):
    raise RuntimeError('Physical timing failed; this bitstream is not a validated candidate: '+str(metrics))
print(f'TD_BUILD_PASS {expected}, elapsed={time.time()-start:.1f}s, output={out}')


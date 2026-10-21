"""Source/report/model-bound TD6.2 programming of joint-YOLO PH1P35 SRAM."""
import argparse,datetime,hashlib,json,re,socket,subprocess,time
from pathlib import Path
BASE=Path(__file__).resolve().parents[1];REPO=BASE.parent;BOARD=REPO/'hardware/mainboard'
BUILD=BOARD/'td_project/camera_to_dsi_display_Runs/phy_1';REPORT=BOARD/'reports/yolo_single15/current'
OUT=BOARD/'reports/yolo_single15/programming';TD=Path('C:/Anlogic/TD_6.2.1_Engineer_6.2.168.116/bin/td_commands_prompt.exe')
FROZEN=BASE/'five/frozen'
STATE={'stage':'preflight','download_attempted':False}
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def read(p):return json.loads(p.read_text(encoding='utf8'))
def check(r):
 for name,want in r['source_hashes'].items():assert sha(REPO/name)==want,'Simulation source mismatch '+name
def main(args):
 assert Path(subprocess.check_output(['git','rev-parse','--show-toplevel'],cwd=REPO,text=True).strip()).resolve()==REPO.resolve(),'Unexpected repository root'
 assert subprocess.check_output(['git','branch','--show-current'],cwd=REPO,text=True).strip()=='main','Program only from the published main branch'
 result=read(BUILD/'build_result.json');assert result['place_and_route'] and min(result['SWNS'],result['HWNS'])>=0
 assert result['slice']<=21216 and result['eram']<=108 and result['dsp']<=40
 assert result['project']=='td_project/camera_to_dsi_display.al'
 bit=BUILD/'camera_to_dsi_display.bit';assert sha(bit)==result['bit_sha256']
 for name,want in read(BUILD/'source_hashes.json').items():assert sha(BOARD/name)==want,'Physical source mismatch '+name
 summary=read(REPORT/'summary.json');assert summary['build']['phase'] in ['timing_pass_not_programmed','timing_pass_programmed_SRAM']
 assert result['YOLO_Hz']==15 and result['inference_interval_frames']==2
 assert summary['YOLO_Hz_default']==15 and summary['hold_last_result_on_skipped_frames'] and summary['display_atomic_snapshot']
 assert summary['held_missed_detections']==2 and summary['third_miss_retires']
 assert result['max_display_cells']==summary['max_display_cells']==1 and result['full_English_names']
 assert summary['component_tests']==5 and summary['full_English_names']==['Basophil','Eosinophil','Lymphocyte','Monocyte','Neutrophil']
 assert summary['build']['physical']['bit_sha256']==result['bit_sha256']
 assert summary['classes']==['BAS','EOS','LYM','MON','NEU'] and summary['standalone_CellNet_in_active_hierarchy'] is False
 assert summary['integer_natural_vectors']==14 and summary['natural_class_coverage']==[0,1,2,3,4]
 assert (summary['video_RTL_tests'],summary['packet_integrity_tests'],summary['python_tests'])==(42,2,38)
 for i in range(14):
  r=read(REPORT/f'five_v{i}/results.json');assert r['status']=='PASS';check(r)
 for n in ['five_unit','five_legacy_tracks','five_stream_burst','five_stream_paced']:
  r=read(REPORT/n/'results.json');assert all(v=='PASS' for v in r['tests'].values());check(r)
 active=read(BOARD/'user_source/hdl_source/yolo/model/active_model.json')
 assert active['protocol']['classes']==summary['classes'] and active['protocol']['geometry']=='fullframe'
 assert active['run']==summary['model']
 assert active['runtime']['YOLO_Hz']==15 and active['runtime']['held_missed_detections']==2
 assert active['runtime']['max_display_cells']==1 and active['runtime']['full_English_names']==summary['full_English_names']
 for name,want in active['assets'].items():assert sha(BOARD/'user_source/hdl_source/yolo'/name)==want,'YOLO ROM/header mismatch '+name
 frozen=FROZEN
 for name,want in summary['frozen_assets'].items():assert sha(frozen/name)==want,'Frozen asset mismatch '+name
 assert sha(frozen/'quantized.npz')==active['quantized_sha256']
 assert sha(frozen/'detector.pt')==active['checkpoint_sha256']
 assert active['threshold_q16']==summary['validation']['score_q16']
 assert not re.search(r'cellnet32_core|cvp_center_classifier',(BUILD/'route.area').read_text()),'CellNet still consumes physical resources'
 print('FIVE_YOLO_PREFLIGHT_PASS',result['bit_sha256'],flush=True)
 if not args.program:return
 OUT.mkdir(parents=True,exist_ok=True);STATE['stage']='usb_inventory'
 usb=subprocess.run(['powershell.exe','-NoProfile','-NonInteractive','-Command',
 "Get-PnpDevice -PresentOnly | Where-Object {$_.InstanceId -match 'VID_0403&PID_6042'} | ForEach-Object {$_.InstanceId}"],text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=30)
 (OUT/'usb_inventory.txt').write_text(usb.stdout,encoding='utf8')
 assert usb.returncode==0 and 'VID_0403&PID_6042' in usb.stdout,'Mainboard USB-JTAG absent; no TD download executed'
 def listening():
  try:
   with socket.create_connection(('127.0.0.1',6555),timeout=1):return True
  except OSError:return False
 if not listening():
  server=TD.with_name('hwserver.exe')
  with (OUT/'hwserver.log').open('w',encoding='utf8') as log:
   helper=subprocess.Popen([str(server),'-r','-f','12','-i','0','-s','6555'],cwd=server.parent,stdout=log,stderr=subprocess.STDOUT,creationflags=subprocess.CREATE_NO_WINDOW)
  for _ in range(50):
   if listening() or helper.poll() is not None:break
   time.sleep(.1)
  assert listening(),'OneCable server unavailable'
 def run(script,name):
  (OUT/(name+'.tcl')).write_text(script,encoding='utf8')
  p=subprocess.run([str(TD)],cwd=OUT,input=script,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=90)
  (OUT/(name+'.log')).write_text(p.stdout,encoding='utf8');print(p.stdout,flush=True)
  assert p.returncode==0 and not re.search(r'\b(?:ERROR|FATAL)\b',p.stdout),'TD failed: '+name
  return p.stdout
 connect='connect_cable -host_name 127.0.0.1:6555\n';STATE['stage']='identify'
 probe=run(connect+'read_device_id -cable 0\nexit\n','identify_mainboard')
 assert re.search(r'^PH1P35MDG324\s*$',probe,re.M) and 'EG4D20' not in probe,'Wrong target; no download'
 STATE['stage']='download';STATE['download_attempted']=True
 script=connect+'read_device_id -cable 0\nset code [catch {download -bit {'+bit.as_posix()+'} -mode jtag -spd 7 -cable 0} result]\nputs "TD_DOWNLOAD_CATCH=$code"\nputs "TD_DOWNLOAD_RESULT=$result"\nexit\n'
 log=run(script,'program_jtag')
 assert 'Chip validation success: PH1P35MDG324' in log and re.search(r'^.*TD_DOWNLOAD_CATCH=0\s*$',log,re.M)
 assert re.search(r'RUN-1003 : finish command "download -bit .* -mode jtag .*"',log)
 record={'recorded_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'model':active['run'],'device':'PH1P35MDG324',
 'bit_sha256':sha(bit),'tool':'TD6.2','mode':'jtag','program_sram_success':True,'flash_written':False,'board_accuracy_validated':False,'hdmi_validated':False,
 'evidence':'correct chip; Tcl catch=0; synchronous download finished; no ERROR/FATAL','runtime':active['runtime']}
 (OUT/'programming.json').write_text(json.dumps(record,indent=2),encoding='utf8');print('FIVE_YOLO_MAINBOARD_SRAM_PROGRAM_PASS',flush=True)
if __name__=='__main__':
 parser=argparse.ArgumentParser();parser.add_argument('--program',action='store_true');args=parser.parse_args()
 try:main(args)
 except Exception as exc:
  if args.program:
   OUT.mkdir(parents=True,exist_ok=True)
   record={'recorded_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),**STATE,'result':'not_verified','error':str(exc)}
   (OUT/'last_attempt.json').write_text(json.dumps(record,indent=2),encoding='utf8')
  raise

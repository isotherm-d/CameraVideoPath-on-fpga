"""Verify the YOLO experiment, then optionally program PH1P35 SRAM with TD6.2."""
import argparse,datetime,hashlib,json,re,socket,subprocess,time
from pathlib import Path
REPO=Path(__file__).resolve().parents[1];BOARD=REPO/'08_csi_dsi_cs500_7cun'
BUILD=BOARD/'td_project/camera_to_dsi_display_Runs/phy_1'
REPORT=BOARD/'reports/yolo160/current';OUT=BOARD/'reports/yolo160/programming'
TD=Path('C:/Anlogic/TD_6.2.1_Engineer_6.2.168.116/bin/td_commands_prompt.exe')
if __name__=='__main__' and len(json.loads((BOARD/'user_source/hdl_source/yolo/model/active_model.json').read_text(encoding='utf8'))['protocol']['classes'])==5:
 import runpy
 runpy.run_path(str(REPO/'yolo/five/program_mainboard.py'),run_name='__main__')
 raise SystemExit(0)
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main(args):
 assert REPO.name=='CameraVideoPath-on-fpga-yolo','Only the separate experiment checkout is allowed'
 branch=subprocess.check_output(['git','branch','--show-current'],cwd=REPO,text=True).strip()
 assert branch=='experiment/yolo160-w4a4','Unexpected experiment branch'
 result=json.loads((BUILD/'build_result.json').read_text())
 assert result['place_and_route'] and min(result['SWNS'],result['HWNS'])>=0,'Final physical timing must pass'
 assert result['slice']<=21216 and result['eram']<=108 and result['dsp']<=40,'Resource overflow'
 bit=BUILD/'camera_to_dsi_display.bit';assert sha(bit)==result['bit_sha256']
 assert result['project']=='td_project/camera_to_dsi_display.al'
 for name,want in json.loads((BUILD/'source_hashes.json').read_text(encoding='utf8')).items():
  assert sha(BOARD/name)==want,'Physical source mismatch '+name
 summary=json.loads((REPORT/'summary.json').read_text(encoding='utf8'))
 assert summary['build']['phase']=='timing_pass_not_programmed'
 assert summary['build']['physical']['bit_sha256']==result['bit_sha256']
 assert summary['RTL_integer_vectors']==6 and summary['classifier_integer_vectors']==72
 assert (summary['video_regression'],summary['packet_integrity'],summary['python_tests'])==(42,2,38)
 for i in range(6):
  r=json.loads((REPORT/f'rtl_v{i}/result.json').read_text(encoding='utf8'));assert r['status']=='PASS'
  for name,want in r['source_hashes'].items():assert sha(REPO/name)==want,'RTL evidence mismatch '+name
 for test in ['integration_control','integration_full','integration_paced']:
  r=json.loads((REPORT/test/'results.json').read_text(encoding='utf8'));assert all(v=='PASS' for v in r['tests'].values())
  for name,want in r['source_hashes'].items():assert sha(REPO/name)==want,'Integration evidence mismatch '+name
 r=json.loads((REPORT/'classifier_regression.json').read_text(encoding='utf8'))
 for name,want in r['source_hashes'].items():assert sha(BOARD/name)==want,'Classifier evidence mismatch '+name
 active=json.loads((BOARD/'user_source/hdl_source/yolo/model/active_model.json').read_text(encoding='utf8'))
 for name,want in active['assets'].items():assert sha(BOARD/'user_source/hdl_source/yolo'/name)==want,'YOLO ROM mismatch '+name
 assert sha(REPO/'yolo/frozen/quantized.npz')==active['quantized_sha256']
 print('YOLO_PREFLIGHT_PASS',result['bit_sha256'],flush=True)
 if not args.program:return
 OUT.mkdir(parents=True,exist_ok=True)
 def run(script,name):
  (OUT/(name+'.tcl')).write_text(script,encoding='utf8')
  p=subprocess.run([str(TD)],input=script,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=90)
  (OUT/(name+'.log')).write_text(p.stdout,encoding='utf8');print(p.stdout,flush=True)
  assert p.returncode==0 and not re.search(r'\b(?:ERROR|FATAL)\b',p.stdout),'TD failure '+name
  return p.stdout
 usb=subprocess.run(['powershell.exe','-NoProfile','-NonInteractive','-Command',
 "Get-PnpDevice -PresentOnly | Where-Object {$_.InstanceId -match 'VID_0403&PID_6042'} | ForEach-Object {$_.InstanceId}"],text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=30)
 (OUT/'usb_inventory.txt').write_text(usb.stdout,encoding='utf8')
 assert usb.returncode==0 and 'VID_0403&PID_6042' in usb.stdout,'Mainboard USB-JTAG absent'
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
 connect='connect_cable -host_name 127.0.0.1:6555\n'
 probe=run(connect+'read_device_id -cable 0\nexit\n','identify_mainboard')
 assert re.search(r'^PH1P35MDG324\s*$',probe,re.M) and 'EG4D20' not in probe,'Wrong chip; no download'
 script=connect+'read_device_id -cable 0\nset code [catch {download -bit {'+bit.as_posix()+'} -mode jtag -spd 7 -cable 0} result]\nputs "TD_DOWNLOAD_CATCH=$code"\nputs "TD_DOWNLOAD_RESULT=$result"\nexit\n'
 log=run(script,'program_jtag')
 assert 'Chip validation success: PH1P35MDG324' in log
 assert re.search(r'^.*TD_DOWNLOAD_CATCH=0\s*$',log,re.M)
 assert re.search(r'RUN-1003 : finish command "download -bit .* -mode jtag .*"',log)
 save={'recorded_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'device':'PH1P35MDG324',
 'bit_sha256':sha(bit),'tool':'TD6.2','mode':'jtag','program_sram_success':True,'flash_written':False,
 'board_accuracy_validated':False,'hdmi_validated':False,'evidence':'correct chip; native Tcl catch=0; synchronous download finished; no ERROR/FATAL'}
 (OUT/'programming.json').write_text(json.dumps(save,indent=2),encoding='utf8')
 print('YOLO_MAINBOARD_SRAM_PROGRAM_PASS',flush=True)
if __name__=='__main__':
 ap=argparse.ArgumentParser();ap.add_argument('--program',action='store_true');main(ap.parse_args())

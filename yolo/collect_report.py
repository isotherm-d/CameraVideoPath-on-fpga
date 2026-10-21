"""Collect source-matched experiment evidence, without accessing any hardware."""
import argparse,datetime,hashlib,json,re,shutil,zipfile
from pathlib import Path
ROOT=Path(__file__).resolve().parent;REPO=ROOT.parent
BOARD=REPO/'08_csi_dsi_cs500_7cun';HDL=BOARD/'user_source/hdl_source/yolo'
RUN=ROOT/'runs/s160_w0075_intqat';DEST=BOARD/'reports/yolo160/current'
if __name__=='__main__' and len(json.loads((HDL/'model/active_model.json').read_text(encoding='utf8'))['protocol']['classes'])==5:
 import runpy
 runpy.run_path(str(ROOT/'five/collect_report.py'),run_name='__main__')
 raise SystemExit(0)
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def save(p,v):p.write_text(json.dumps(v,ensure_ascii=False,indent=2),encoding='utf8')
def check_hashes(report,base):
 for name,want in report['source_hashes'].items():
  if sha(base/name)!=want:raise RuntimeError('Evidence source mismatch: '+name)
def main(args):
 DEST.mkdir(parents=True,exist_ok=True)
 results=[]
 for i in range(6):
  folder=ROOT/f'tmp/rtl_v{i}';r=json.loads((folder/'result.json').read_text());check_hashes(r,REPO)
  assert r['status']=='PASS';results.append(r)
  for name in ['result.json','sim.log','compile.log']:
   out=DEST/f'rtl_v{i}';out.mkdir(exist_ok=True);shutil.copy2(folder/name,out/name)
 for name in ['integration_control','integration_full','integration_paced']:
  folder=ROOT/'tmp'/name;r=json.loads((folder/'results.json').read_text());check_hashes(r,REPO)
  assert all(v=='PASS' for v in r['tests'].values())
  out=DEST/name;out.mkdir(exist_ok=True)
  for p in folder.glob('*.log'):shutil.copy2(p,out/p.name)
  shutil.copy2(folder/'results.json',out/'results.json')
 cr=ROOT/'tmp/classifier_regression';r=json.loads((cr/'results.json').read_text());check_hashes(r,BOARD)
 assert r['natural_and_boundary_vectors']==72
 shutil.copy2(cr/'results.json',DEST/'classifier_regression.json')
 for src,name in [(ROOT/'tmp/classifier_regression_console.log','classifier_regression.log'),
                  (ROOT/'tmp/video_regression_console.log','video_regression.log'),
                  (ROOT/'tmp/python_regression.log','python_regression.log')]:
  shutil.copy2(src,DEST/name)
 assert '42 RTL tests and 2 packet integrity checks' in (DEST/'video_regression.log').read_text(encoding='utf-8-sig')
 assert re.search(r'Ran 38 tests.*\s+OK', (DEST/'python_regression.log').read_text(encoding='utf8'),re.S)
 frozen=ROOT/'frozen';frozen.mkdir(exist_ok=True)
 for name in ['detector.pt','quantized.npz','protocol.json','frozen.json','fp32_validation.json','qat_validation.json',
              'integer_validation.json','test_result.json','accumulator_bounds.json','data_manifest.json','history.json','layers.json']:
  shutil.copy2(RUN/name,frozen/name)
 assert sha(frozen/'quantized.npz')==json.loads((frozen/'frozen.json').read_text())['quantized_sha256']
 with zipfile.ZipFile(frozen/'rtl_vectors.zip','w',zipfile.ZIP_DEFLATED) as z:
  for p in sorted((RUN/'vectors').rglob('*')):
   if p.is_file():
    relative=p.relative_to(RUN/'vectors')
    z.write(p,relative.as_posix())
 third=ROOT/'third_party';third.mkdir(exist_ok=True)
 shutil.copy2(ROOT/'data/BCCD_Dataset/LICENSE',third/'BCCD_LICENSE.txt')
 provenance=REPO.parent/'tmp/yolo_research_20261020/copy_20261020_161147'
 copy=json.loads((provenance/'copy_result.json').read_text());shutil.copy2(provenance/'copy_result.json',DEST/'copy_result.json')
 hashes=json.loads((provenance/'copied_file_hashes.json').read_text(encoding='utf8'));source=Path(copy['source'])
 original={k:sha(source/k)==v for k,v in hashes.items() if Path(k).suffix in ['.v','.sv','.vh','.al','.sdc','.adc','.hex','.py','.ps1','.md']}
 save(DEST/'original_checkout_check.json',{'compared_to_copy_snapshot':len(original),'all_match':all(original.values()),'mismatches':[k for k,v in original.items() if not v]})
 if not all(original.values()):raise RuntimeError('Original source differs from copy snapshot; inspect before reporting it untouched')
 gate=json.loads((BOARD/'reports/yolo160/attempt4_first_pipeline/build_result.json').read_text())
 status={'phase':'physical_build_in_progress','gate_estimate':gate,'board_validated':False,'programmed':False}
 if (DEST/'build_status.json').exists() and not args.physical:
  status=json.loads((DEST/'build_status.json').read_text(encoding='utf8'))
 if args.physical:
  phy=BOARD/'td_project/camera_to_dsi_display_Runs/phy_1';p=phy/'build_result.json'
  if p.exists():
   physical=json.loads(p.read_text());manifest=json.loads((phy/'source_hashes.json').read_text())
   for name,want in manifest.items():
    assert sha(BOARD/name)==want,'Physical source mismatch '+name
   bit=BOARD/physical['bit_path'];assert sha(bit)==physical['bit_sha256']
   status['physical']=physical;status['phase']='timing_pass_not_programmed' if physical['SWNS']>=0 and physical['HWNS']>=0 else 'timing_failed_do_not_program'
   target=DEST/'physical';target.mkdir(exist_ok=True)
   for n in ['route.area','route.timing','build.log','build_result.json','source_hashes.json','camera_to_dsi_display.bit']:
    shutil.copy2(phy/n,target/n)
  else:status['phase']='physical_build_in_progress_no_final_result'
 programming=BOARD/'reports/yolo160/programming/programming.json'
 if programming.exists() and status.get('physical'):
  record=json.loads(programming.read_text(encoding='utf8'))
  if record['bit_sha256']==status['physical']['bit_sha256'] and record.get('program_sram_success'):
   status['programmed']=True;status['programming_record']='../programming/programming.json'
 usb=BOARD/'reports/yolo160/programming/usb_inventory.txt'
 if not status['programmed'] and usb.exists() and 'VID_0403&PID_6042' not in usb.read_text(encoding='utf8',errors='replace'):
  status['download_blocked_reason']='Mainboard USB-JTAG absent; stopped before TD cable access or download'
 save(DEST/'build_status.json',status)
 active=json.loads((HDL/'model/active_model.json').read_text())
 active['assets']={str(p.relative_to(HDL)):sha(p) for p in list((HDL/'model').glob('*'))+list(HDL.glob('*.vh')) if p.is_file() and p.name!='active_model.json'}
 active['status']='RTL_verified_'+status['phase'];active['test_result']='yolo/frozen/test_result.json';active['checkpoint_sha256']=sha(frozen/'detector.pt')
 save(HDL/'model/active_model.json',active)
 summary={'updated_at':datetime.datetime.now().astimezone().isoformat(),'branch':'experiment/yolo160-w4a4','model':'s160_w0075_intqat',
 'cadence_default':10,'video_fps':30,'detector_region':[320,40,959,679],'detector_input':[160,160],
 'classifier_crop':[400,120,879,599],'classifier_input':[32,32],'RTL_integer_vectors':len(results),
 'RTL_cycles':max(v['cycles'] for v in results),'full720p30_tests':['burst','paced_4444_clocks_per_row'],
 'video_regression':42,'packet_integrity':2,'python_tests':38,'classifier_integer_vectors':72,
 'model_test':{k:v for k,v in json.loads((RUN/'test_result.json').read_text()).items() if k not in ['predictions','frozen_sha256']},
 'build':status,'board_validated':False,'test_opened_after_freeze':True,
 'frozen_assets':{p.name:sha(p) for p in frozen.glob('*') if p.is_file()}}
 save(DEST/'summary.json',summary)
 print('YOLO_EVIDENCE_COLLECTED',status['phase'],DEST)
if __name__=='__main__':
 ap=argparse.ArgumentParser();ap.add_argument('--physical',action='store_true');main(ap.parse_args())

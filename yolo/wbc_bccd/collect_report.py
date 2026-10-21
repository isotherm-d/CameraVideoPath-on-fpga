"""Collect the isolated repair with source-bound simulation and physical proof."""
import argparse,datetime,hashlib,json,re,shutil,zipfile
from pathlib import Path
BASE=Path(__file__).resolve().parents[1];REPO=BASE.parent;BOARD=REPO/'08_csi_dsi_cs500_7cun';HOME=BASE/'wbc_bccd';HDL=BOARD/'user_source/hdl_source/yolo'
DEST=BOARD/'reports/yolo_wbc_bccd15/current';FROZEN=HOME/'frozen';NAMES=['Basophil','Eosinophil','Lymphocyte','Monocyte','Neutrophil']
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def read(p):return json.loads(p.read_text(encoding='utf8'))
def save(p,x):p.write_text(json.dumps(x,indent=2,ensure_ascii=False),encoding='utf8')
def check(r):
 for n,w in r['source_hashes'].items():assert sha(REPO/n)==w,n
def main(name):
 run=BASE/'runs'/name;accept_path=run/('board_trial_acceptance.json' if (run/'board_trial_acceptance.json').exists() else 'acceptance.json');accept=read(accept_path);assert accept['gate_passed'];active=read(HDL/'model/active_model.json');assert active['run']==name
 assert sha(run/'quantized.npz')==accept['quantized_sha256']==active['quantized_sha256']
 audit=read(HOME/'data_audit.json');assert audit['status']=='PASS' and audit['manifest_sha256']==sha(run/'data_manifest.json')
 post=read(run/'postprocess_protocol.json')
 for n,w in post['source_hashes'].items():assert sha(REPO/n)==w,n
 for n,w in accept.get('engineering_trial_policy',{}).get('source_hashes',{}).items():assert sha(REPO/n)==w,n
 assert active['postprocess']['detection_score']=='objectness*255'
 for n,w in read(run/'training_source_hashes.json').items():assert sha(REPO/n)==w,n
 for n,w in active['assets'].items():assert sha(HDL/n)==w,n
 probes=DEST.parent/'development_probes';pr=read(probes/'summary.json');assert pr['model']==name and pr['probes']==5 and pr['exact_10_layer_RTL_replay_pass']
 for p in probes.glob('v*/results.json'):
  r=read(p);check(r);assert r['status']=='PASS'
 DEST.mkdir(exist_ok=True,parents=True);classes=set();cycles=[]
 for n in ['five_v'+str(i) for i in range(14)]+['five_unit','five_legacy_tracks','five_stream_burst','five_stream_paced']:
  src=BASE/'tmp'/n;r=read(src/'results.json');check(r);assert all(v=='PASS' for v in r['tests'].values())
  if n!='five_legacy_tracks':assert r['model']==name
  target=DEST/n;target.mkdir(exist_ok=True)
  for p in [*src.glob('*.log'),src/'results.json']:shutil.copy2(p,target/p.name)
  if n.startswith('five_v'):
   i=int(n[6:]);classes.update(read(run/f'vectors/v{i}/expected_boxes.json')['classes'])
   cycles.append(int(re.search(r'cycles=(\d+)',(src/'tb_five_vector.log').read_text())[1]))
 assert classes=={0,1,2,3,4}
 # Fresh inherited RTL/Python regressions for this experiment.
 for n,w in read(HOME/'regression_source_hashes.json').items():assert sha(REPO/n)==w,n
 old=BASE/'tmp/wbc_bccd_regression'
 for n in ['video_regression.log','python_regression.log']:shutil.copy2(old/n,DEST/n)
 assert '42 RTL tests and 2 packet integrity checks' in (DEST/'video_regression.log').read_text(encoding='utf-8-sig')
 assert re.search(r'Ran 38 tests.*\s+OK',(DEST/'python_regression.log').read_text(),re.S)
 FROZEN.mkdir(exist_ok=True)
 for n in ['detector.pt','quantized.npz','protocol.json','frozen.json','history.json','training_source_hashes.json','fp32_validation.json','qat_validation.json','integer_validation.json','test_regression.json','data_manifest.json']:
  shutil.copy2(run/n,FROZEN/n)
 shutil.copy2(run/'acceptance.json',FROZEN/'original_acceptance.json');shutil.copy2(accept_path,FROZEN/'acceptance.json')
 for n in ['engineering_trial_policy.json','deployment_policy.json']:
  if (run/n).exists():shutil.copy2(run/n,FROZEN/n)
 shutil.copy2(HOME/'regression_source_hashes.json',FROZEN/'regression_source_hashes.json')
 shutil.copy2(HOME/'data_audit.json',FROZEN/'data_audit.json')
 for n in ['camera_val.npz','camera_val_manifest.json']:
  if (run/n).exists():shutil.copy2(run/n,FROZEN/n)
 shutil.copy2(run/'postprocess_protocol.json',FROZEN/'postprocess_protocol.json')
 for n,w in post['source_hashes'].items():
  p=FROZEN/'postprocess_sources'/n;p.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(REPO/n,p)
 for n,w in accept.get('engineering_trial_policy',{}).get('source_hashes',{}).items():
  p=FROZEN/'postprocess_sources'/n;p.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(REPO/n,p)
 shutil.copy2(BOARD/'td_project/camera_to_dsi_display.al',FROZEN/'project_used.al')
 with zipfile.ZipFile(FROZEN/'rtl_vectors.zip','w',zipfile.ZIP_DEFLATED) as z:
  for p in sorted((run/'vectors').rglob('*')):
   if p.is_file():z.write(p,p.relative_to(run/'vectors').as_posix())
 phy=BOARD/'td_project/camera_to_dsi_display_Runs/phy_1';physical=read(phy/'build_result.json')
 assert physical['place_and_route'] and min(physical['SWNS'],physical['HWNS'])>=0
 for n,w in read(phy/'source_hashes.json').items():assert sha(BOARD/n)==w,n
 assert sha(BOARD/physical['bit_path'])==physical['bit_sha256']
 target=DEST/'physical';target.mkdir(exist_ok=True)
 for n in ['route.area','route.timing','build_result.json','source_hashes.json','build.log','camera_to_dsi_display.bit']:shutil.copy2(phy/n,target/n)
 status={'phase':'timing_pass_not_programmed','programmed':False,'board_validated':False,'physical':physical}
 record=DEST.parent/'programming/programming.json'
 if record.exists() and read(record)['bit_sha256']==physical['bit_sha256'] and read(record)['program_sram_success']:
  status.update(phase='timing_pass_programmed_SRAM',programmed=True)
 summary={'recorded_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'model':name,'classes':['BAS','EOS','LYM','MON','NEU'],
  'YOLO_Hz_default':15,'inference_interval_frames':2,'display_atomic_snapshot':True,'hold_last_result_on_skipped_frames':True,'held_missed_detections':2,
  'third_miss_retires':True,'max_display_cells':1,'full_English_names':NAMES,'standalone_CellNet_in_active_hierarchy':False,
  'integer_natural_vectors':14,'natural_class_coverage':sorted(classes),'max_vector_cycles':max(cycles),
  'component_tests':5,'legacy_track_tests':3,'video_RTL_tests':42,'packet_integrity_tests':2,'python_tests':38,'development_RTL_probes':pr,
  'unchanged_video_regression_snapshot_reused':False,'validation':{'score_q16':accept['threshold_q16'],'metrics':accept['validation']},'repair_acceptance':accept,'training_sources':['WBCAtt+','BCCD'],'reused_TEST_regression':read(run/'test_regression.json'),
  'build':status,'board_validated':False,'frozen_assets':{p.relative_to(FROZEN).as_posix():sha(p) for p in FROZEN.rglob('*') if p.is_file()}}
 save(DEST/'summary.json',summary);save(DEST/'build_status.json',status);print('TWO_SOURCE_REPORT_COLLECTED',status['phase'],flush=True)
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--name',default='wbc_bccd160_20261021');main(p.parse_args().name)

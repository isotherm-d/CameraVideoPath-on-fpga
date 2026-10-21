"""Collect only source-matched joint-YOLO evidence; never use old CellNet proof."""
import argparse,datetime,hashlib,json,re,shutil,zipfile
from pathlib import Path
BASE=Path(__file__).resolve().parents[1];REPO=BASE.parent;BOARD=REPO/'08_csi_dsi_cs500_7cun'
HDL=BOARD/'user_source/hdl_source/yolo';DEST=BOARD/'reports/yolo_single15/current'
FULL_NAMES=['Basophil','Eosinophil','Lymphocyte','Monocyte','Neutrophil']
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def read(p):return json.loads(p.read_text(encoding='utf8'))
def save(p,value):p.write_text(json.dumps(value,ensure_ascii=False,indent=2),encoding='utf8')
def check(report):
 for name,want in report['source_hashes'].items():
  assert sha(REPO/name)==want,'Evidence source mismatch '+name
def copy_checks(name):
 folder=BASE/'tmp'/name;r=read(folder/'results.json');check(r)
 assert all(v=='PASS' for v in r['tests'].values())
 target=DEST/name;target.mkdir(exist_ok=True)
 for p in folder.glob('*.log'):shutil.copy2(p,target/p.name)
 shutil.copy2(folder/'results.json',target/'results.json')
 return r
def main(args):
 DEST.mkdir(parents=True,exist_ok=True)
 selection=read(BASE/'five/model_selection.json');chosen=selection['selected'];run=BASE/'runs'/chosen['run']
 assert chosen['checkpoint_sha256']==sha(run/'detector.pt')
 assert chosen['quantized_sha256']==sha(run/'quantized.npz')
 manifest=read(run/'vectors/manifest.json');assert manifest['vectors']==14
 vector_cycles=[];predicted_classes=set()
 for i in range(14):
  r=copy_checks('five_v'+str(i));assert r['model']==chosen['run']
  log=(BASE/f'tmp/five_v{i}/tb_five_vector.log').read_text(encoding='utf8')
  vector_cycles.append(int(re.search(r'first_words=6400 cycles=(\d+)',log)[1]))
  predicted_classes.update(read(run/f'vectors/v{i}/expected_boxes.json')['classes'])
 assert predicted_classes=={0,1,2,3,4},'All five class outputs must be covered by natural vectors'
 for name in ['five_unit','five_legacy_tracks','five_stream_burst','five_stream_paced']:copy_checks(name)
 assert len(read(DEST/'five_unit/results.json')['tests'])==5
 for src,dst in [('five_video_regression_console.log','video_regression.log'),('five_python_regression.log','python_regression.log')]:
  shutil.copy2(BASE/'tmp'/src,DEST/dst)
 assert '42 RTL tests and 2 packet integrity checks' in (DEST/'video_regression.log').read_text(encoding='utf-8-sig')
 assert re.search(r'Ran 38 tests.*\s+OK',(DEST/'python_regression.log').read_text(encoding='utf8'),re.S)
 frozen=BASE/'five/frozen';frozen.mkdir(exist_ok=True)
 names=['detector.pt','quantized.npz','protocol.json','frozen.json','fp32_validation.json','qat_validation.json',
        'integer_validation.json','confidence_protocol.json','data_manifest.json','history.json','layers.json',
        'five_class_test_result.json','five_test_partition.json']
 for name in names:shutil.copy2(run/name,frozen/name)
 for name in ['model_selection.json','raw_model_selection.json']:shutil.copy2(BASE/'five'/name,frozen/name)
 with zipfile.ZipFile(frozen/'rtl_vectors.zip','w',zipfile.ZIP_DEFLATED) as z:
  for p in sorted((run/'vectors').rglob('*')):
   if p.is_file():z.write(p,p.relative_to(run/'vectors').as_posix())
 # Keep the other VAL candidates' results without promoting their TEST metrics.
 candidate_dir=frozen/'candidates';candidate_dir.mkdir(exist_ok=True)
 for row in selection['candidates']:
  source=BASE/'runs'/row['run'];target=candidate_dir/row['run'];target.mkdir(exist_ok=True)
  for name in ['protocol.json','frozen.json','integer_validation.json']:shutil.copy2(source/name,target/name)
 active=read(HDL/'model/active_model.json');assert active['run']==chosen['run']
 assert active['protocol']['classes']==['BAS','EOS','LYM','MON','NEU']
 # Prove the old classifier was removed from the active hierarchy, not merely
 # hidden at its output. Synthesis reports from failed iterations stay separate.
 status={'phase':'synthesis_pending','programmed':False,'board_validated':False}
 syn=BOARD/'td_project/camera_to_dsi_display_Runs'/('phy_1' if args.physical else 'syn_1')
 if (syn/'build_result.json').exists():
  gate=read(syn/'build_result.json');pins=read(syn/'source_hashes.json')
  if args.physical:
   area=(syn/'gate.area').read_text();timing=(syn/'gate.timing').read_text()
   gate={name:int(re.search(r'^#'+name+r'\*?\s+(\d+)',area,re.M)[1]) for name in ['slice','eram','dsp']}
   gate.update({name:float(re.search(name+r':\s*([-\d.]+)ns',timing)[1]) for name in ['SWNS','HWNS']})
   gate.update(place_and_route=False,board_validated=False,source='gate reports from the same final physical build')
  for name,want in pins.items():assert sha(BOARD/name)==want,'Synthesis source mismatch '+name
  assert not re.search(r'cellnet32_core|cvp_center_classifier', (syn/'gate.area').read_text())
  status={'phase':'physical_build_pending','gate_estimate':gate,'programmed':False,'board_validated':False}
  target=DEST/'synthesis';target.mkdir(exist_ok=True)
  for n in ['gate.area','gate.timing','source_hashes.json','build.log']:shutil.copy2(syn/n,target/n)
  save(target/'build_result.json',gate)
 if (DEST/'build_status.json').exists() and not args.physical:
  previous=read(DEST/'build_status.json')
  if previous.get('physical'):status=previous
 if args.physical:
  phy=BOARD/'td_project/camera_to_dsi_display_Runs/phy_1'
  if (phy/'build_result.json').exists():
   physical=read(phy/'build_result.json');assert physical['place_and_route']
   for name,want in read(phy/'source_hashes.json').items():assert sha(BOARD/name)==want,'Physical source mismatch '+name
   assert sha(BOARD/physical['bit_path'])==physical['bit_sha256']
   assert not re.search(r'cellnet32_core|cvp_center_classifier',(phy/'route.area').read_text())
   status['physical']=physical;status['phase']='timing_pass_not_programmed' if min(physical['SWNS'],physical['HWNS'])>=0 else 'timing_failed_do_not_program'
   target=DEST/'physical';target.mkdir(exist_ok=True)
   for n in ['route.area','route.timing','build_result.json','source_hashes.json','build.log','camera_to_dsi_display.bit']:shutil.copy2(phy/n,target/n)
  else:status['phase']='physical_build_in_progress_no_final_result'
 programming=BOARD/'reports/yolo_single15/programming/programming.json'
 if programming.exists() and status.get('physical'):
  record=read(programming)
  if record['bit_sha256']==status['physical']['bit_sha256'] and record.get('program_sram_success'):
   status['programmed']=True
   status['phase']='timing_pass_programmed_SRAM'
 usb=BOARD/'reports/yolo_single15/programming/usb_inventory.txt'
 if not status['programmed'] and usb.exists() and 'VID_0403&PID_6042' not in usb.read_text(encoding='utf8',errors='replace'):
  status['download_blocked_reason']='Mainboard USB-JTAG absent; no TD download executed'
 save(DEST/'build_status.json',status)
 test=read(run/'five_class_test_result.json');validation=read(run/'integer_validation.json')
 manifest_data=read(frozen/'data_manifest.json');usage=[]
 for split in ['train','val','test']:
  for dataset in ['Raabin_train','BCCD']:
   rows=[r for r in manifest_data['sources'] if r['split']==split and r['source']==dataset]
   if rows:
    usage.append({'dataset':dataset,'split':split,'samples_including_crops':len(rows),
                  'original_images':len({r['name'].split(':')[0] for r in rows}),
                  'negative_crops':sum('crop' in r for r in rows),'objects':sum(r['boxes'] for r in rows),
                  'five_class_labels':dataset=='Raabin_train'})
 save(DEST/'dataset_usage.json',{'manifest_sha256':sha(frozen/'data_manifest.json'),'usage':usage,
      'Raabin_heldout_official_mask_pairs':test['official_TestA_mask_pairs'],
      'Raabin_heldout_group_disjoint_pairs':test['group_disjoint_pairs'],
      'camera_annotated_training_samples':0,'weights_unchanged_for_15Hz':True})
 assert validation['selected']['score_q16']==chosen['integer_confidence']['score_q16']
 active['assets']={str(p.relative_to(HDL)).replace('\\','/'):sha(p) for p in list((HDL/'model').glob('*'))+list(HDL.glob('*.vh')) if p.is_file() and p.name!='active_model.json'}
 active['status']='RTL_verified_'+status['phase'];active['threshold_q16']=validation['selected']['score_q16'];active['checkpoint_sha256']=chosen['checkpoint_sha256']
 active['runtime']={'video_fps_configured':30,'inference_interval_frames':2,'YOLO_Hz':15,'held_missed_detections':2,'display_atomic_snapshot':True,
                    'max_display_cells':1,'full_English_names':FULL_NAMES,'selection_policy':'keep identity; otherwise nearest center'}
 active['test_report']='yolo/five/frozen/five_class_test_result.json';save(HDL/'model/active_model.json',active)
 original=REPO.parent/'tmp/yolo_research_20261020/copy_20261020_161147';copy=read(original/'copy_result.json');pins=read(original/'copied_file_hashes.json')
 checked={k:sha(Path(copy['source'])/k)==v for k,v in pins.items() if Path(k).suffix in ['.v','.sv','.vh','.al','.sdc','.adc','.hex','.py','.ps1','.md']}
 save(DEST/'original_checkout_check.json',{'files_checked':len(checked),'all_match':all(checked.values()),'mismatches':[k for k,v in checked.items() if not v]})
 summary={'recorded_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'branch':'experiment/yolo160-w4a4','model':chosen['run'],
 'classes':active['protocol']['classes'],'detector_region':[0,0,1279,719],'input_rgb':[160,160],'video_fps':30,'YOLO_Hz_default':15,'inference_interval_frames':2,
 'display_atomic_snapshot':True,'hold_last_result_on_skipped_frames':True,'held_missed_detections':2,'third_miss_retires':True,
 'max_display_cells':1,'full_English_names':FULL_NAMES,'selection_policy':'keep identity; otherwise nearest center',
 'sampler_x':'4+8*k','sampler_y':'2+4*j+floor(j/2)','standalone_CellNet_in_active_hierarchy':False,
 'initial_confirm':2,'switch_confirm':3,'missed_detector_updates_retained':2,'class_TTL_video_frames':15,'box_TTL_video_frames':5,
 'integer_natural_vectors':14,'logits_per_vector':3000,'C1_words_per_vector':6400,'natural_class_coverage':sorted(predicted_classes),
 'max_vector_cycles':max(vector_cycles),'full720p30_modes':['burst','three clocks/pixel, 4444 clocks/row'],
 'component_tests':5,'legacy_track_tests':3,'video_RTL_tests':42,'packet_integrity_tests':2,'python_tests':38,
 'validation':validation['selected'],'heldout':{k:v for k,v in test.items() if k not in ['pairs','predictions_TestA','predictions_BCCD']},
 'build':status,'original_source_files_unchanged':all(checked.values()),'board_validated':False,
 'frozen_assets':{str(p.relative_to(frozen)).replace('\\','/'):sha(p) for p in frozen.rglob('*') if p.is_file()}}
 save(DEST/'summary.json',summary);print('FIVE_REPORT_COLLECTED',status['phase'],DEST)
if __name__=='__main__':
 parser=argparse.ArgumentParser()
 mode=parser.add_mutually_exclusive_group()
 mode.add_argument('--physical',dest='physical',action='store_true',help='Collect the original-project physical run (default)')
 mode.add_argument('--synthesis',dest='physical',action='store_false',help='Collect a separate synthesis-only run')
 parser.set_defaults(physical=True);main(parser.parse_args())

"""Preserve the VAL-only failure and create an explicitly development-calibrated release."""
import datetime,hashlib,json,shutil
from pathlib import Path
BASE=Path(__file__).resolve().parents[1];HOME=BASE/'wbc_bccd';SOURCE=BASE/'runs/wbc_bccd160_objectmax_20261021';RUN=BASE/'runs/wbc_bccd160_devcam_20261021'
def read(p):return json.loads(p.read_text(encoding='utf8'))
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
if __name__=='__main__':
 if RUN.exists():raise FileExistsError(RUN)
 assert read(SOURCE/'frozen.json')['geometry_and_type_parameters_unchanged']
 RUN.mkdir()
 for n in ['detector.pt','quantized.npz','frozen.json','data_manifest.json','history.json','training_source_hashes.json','fp32_validation.json','qat_validation.json','camera_val.npz','camera_val_manifest.json']:
  shutil.copy2(SOURCE/n,RUN/n);assert sha(RUN/n)==sha(SOURCE/n)
 p=read(SOURCE/'protocol.json');p.update(name=RUN.name,training_run=SOURCE.name,deployment_only_alias=True,
  final_threshold='Explicit DEVELOPMENT calibration: public and fixed camera-augmented VAL plus provided room/cell screenshots, same grid0.40..0.95 step0.025, no TEST. Screenshots never train weights or supply cell type.',
  procedural_VAL_screening_limit=.02,procedural_final_limit=.01)
 (RUN/'protocol.json').write_text(json.dumps(p,indent=2),encoding='utf8')
 policy={'recorded_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'training_run':SOURCE.name,'checkpoint_sha256':sha(RUN/'detector.pt'),'quantized_sha256':sha(RUN/'quantized.npz'),
  'rationale':'VAL-only0.95 threshold passed public metrics and artificial background regressions but missed provided unlabelled post-OSD cell screenshot. Separate deployment calibration uses that provided development example plus room-negative. Preserve original failure, do not claim an independent camera test or VAL-only threshold.',
  'weights_reselected':False,'training_unchanged_after_freeze':True,'screenshot_pixels_trained':False,'screenshot_threshold_tuning':True,'TEST_used':False,
  'detection_score':'sigmoid_LUT(objectness)*255','type':'neural five-logit argmax','development_cell_approximate_ROI':[540,210,830,525],'development_cell_class_label':None,
  'grid':[.4+.025*k for k in range(23)],'selection':'same balanced public/fixed-augmented VAL objective, constrained by provided development room empty and cell IoU>=0.5 plus uniform checks; no TEST',
  'gates':'Natural jointF1>=.88, BCCD recall>=.85 precision>=.75, fixed cameraVAL jointF1>=.70; 256 procedural VAL screening<=2% due coarse sample count; both larger1024-image stress regressions remain<=1%; all uniform and room probes empty, development cell localizes; full RTL/source/bit/timing binding',
  'previous_VAL_only_failure':str(SOURCE/'acceptance.json'),
  'source_hashes':{p.relative_to(BASE.parent).as_posix():sha(p) for p in [Path(__file__),HOME/'object_reference.py',HOME/'evaluate_camera_calibrated.py',HOME/'run_tests.py',HOME/'run_all_vectors.py',HOME/'tb_five_post.sv']}}
 (RUN/'postprocess_protocol.json').write_text(json.dumps(policy,indent=2),encoding='utf8');(RUN/'deployment_policy.json').write_text(json.dumps(policy,indent=2),encoding='utf8');print('DEVELOPMENT_CALIBRATION_ALIAS_CREATED_NO_RETRAIN_NO_PROGRAM',flush=True)

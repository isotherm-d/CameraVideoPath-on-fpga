import argparse,datetime,hashlib,json
from pathlib import Path
BASE=Path(__file__).resolve().parents[1];HOME=BASE/'wbc_bccd';RUN=BASE/'runs/wbc_bccd160_camera_20261021'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--name',default='wbc_bccd160_object_20261021');p.add_argument('--evaluator',default='evaluate_objectness_head.py');args=p.parse_args();RUN=BASE/'runs'/args.name
 path=RUN/'postprocess_protocol.json'
 if path.exists():raise FileExistsError(path)
 protocol={'recorded_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'checkpoint_sha256':sha(RUN/'detector.pt'),'quantized_sha256':sha(RUN/'quantized.npz'),
  'rationale':'BCCD boxes have no five-class supervision. Keep learned objectness detection separate from five-class argmax, so uncertain type confidence does not remove a well-localized cell. Still measure joint type+IoU correctness, negatives and exposure-augmented VAL.',
  'weights_reselected':False,'training_unchanged':True,'detection_score':'sigmoid_LUT(objectness)*255; same 0..65025 score range','type':'argmax of the five neural logits; no extra classifier',
  'selection':'Same declared 0.55 natural jointF1+0.20 BCCD localizationF1+0.25 fixed cameraVAL jointF1-0.3 proceduralVAL_FP-0.1 acquired_negative_FP; VAL only',
  'grid':[.4+.025*k for k in range(23)],'gates':'Natural jointF1>=.88, BCCD recall>=.85/precision>=.75, cameraVAL jointF1>=.70, proceduralVAL and separate finalFP<=.01; all uniform and room probes empty, historical cell development localizes; full RTL/timing/source binding',
  'TEST_used':False,'screenshot_pixels_trained':False,'screenshot_threshold_tuning':False,
  'source_hashes':{p.relative_to(BASE.parent).as_posix():sha(p) for p in [HOME/'object_reference.py',HOME/args.evaluator,HOME/'run_tests.py',HOME/'run_all_vectors.py',HOME/'tb_five_post.sv']}}
 path.write_text(json.dumps(protocol,indent=2),encoding='utf8');print('POSTPROCESS_PROTOCOL_FROZEN_BEFORE_VAL_CALIBRATION',flush=True)

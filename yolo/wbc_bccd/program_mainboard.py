"""Repair-gated wrapper of the existing source-bound TD6.2 SRAM programmer."""
import argparse,datetime,json,sys
from pathlib import Path
BASE=Path(__file__).resolve().parents[1];sys.path.insert(0,str(BASE))
from five import program_mainboard as guarded
guarded.REPORT=guarded.BOARD/'reports/yolo_wbc_bccd15/current'
guarded.OUT=guarded.BOARD/'reports/yolo_wbc_bccd15/programming'
guarded.FROZEN=BASE/'wbc_bccd/frozen'
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--program',action='store_true');args=p.parse_args()
 acceptance=json.loads((guarded.FROZEN/'acceptance.json').read_text(encoding='utf8'));assert acceptance['gate_passed'] and all(acceptance['checks'].values())
 if acceptance.get('acceptance_kind')=='engineering_SRAM_trial_with_disclosed_residual_FP':
  assert acceptance['original_gate_passed'] is False
  assert max(acceptance['procedural_final']['FP_rate'],acceptance['extra_procedural_final']['FP_rate'])<=.02
  assert [k for k,v in acceptance['original_checks'].items() if not v]==['procedural_final_FP_at_most_001']
  assert guarded.sha(guarded.FROZEN/'original_acceptance.json')==acceptance['engineering_trial_policy']['original_acceptance_sha256']
 try:
  guarded.main(args)
  if args.program:
   path=guarded.OUT/'programming.json';record=json.loads(path.read_text(encoding='utf8'));record.update(release_scope='engineering_SRAM_trial_with_disclosed_residual_FP',original_1percent_artificial_background_gate_passed=False,artificial_background_FP_rates=[acceptance['procedural_final']['FP_rate'],acceptance['extra_procedural_final']['FP_rate']],threshold_uses_provided_development_frames=True);path.write_text(json.dumps(record,indent=2),encoding='utf8')
 except Exception as exc:
  if args.program:
   guarded.OUT.mkdir(exist_ok=True,parents=True)
   (guarded.OUT/'last_attempt.json').write_text(json.dumps({'recorded_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),**guarded.STATE,'result':'not_verified','error':str(exc)},indent=2))
  raise

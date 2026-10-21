"""Freeze the run selection on VAL before opening five-class TEST masks."""
import hashlib,json
from pathlib import Path
BASE=Path(__file__).resolve().parents[1]
names=['five_fullframe_seed0','five_fullframe_seed1','five_fullframe_seed2','five_fullframe_wide_seed0']
rows=[]
for name in names:
 folder=BASE/'runs'/name;f=json.loads((folder/'frozen.json').read_text());p=json.loads((folder/'protocol.json').read_text())
 rows.append({'run':name,'selection_score':f['validation']['selection_score'],'validation':f['validation'],
 'checkpoint_sha256':hashlib.sha256((folder/'detector.pt').read_bytes()).hexdigest(),
 'quantized_sha256':f['quantized_sha256'],'channels':p['channels'],'wide_head':p.get('wide_head',False)})
 calibration=json.loads((folder/'integer_validation.json').read_text())
 rows[-1]['integer_confidence']=calibration['selected'];rows[-1]['integer_objective']=calibration['selected']['metrics']['objective']
selected=max(rows,key=lambda r:r['integer_objective'])
report={'criterion':'VAL only exact integer chain: 0.7 joint macroF1 + 0.3 BCCD localizationF1 - 0.1 negative-image FP rate',
 'checkpoint_criterion':'within each training run: 0.7 joint macroAP50 + 0.3 BCCD localizationAP50',
 'selected':selected,'candidates':rows,'five_class_TEST_masks_opened':False}
p=BASE/'five/model_selection.json'
if p.exists():
 previous=json.loads(p.read_text())
 if previous['criterion']=='VAL only: 0.7 joint five-class macroAP50 + 0.3 BCCD localizationAP50':
  assert not any((BASE/'runs'/n/'five_class_test_result.json').exists() for n in names),'TEST already opened'
  (BASE/'five/raw_model_selection.json').write_text(json.dumps(previous,indent=2))
 else:assert previous==report,'Integer model selection already frozen; do not change after TEST'
p.write_text(json.dumps(report,indent=2))
print('FIVE_RUN_SELECTED',selected['run'],selected['integer_objective'])

import sys,json
from pathlib import Path
import numpy as np
BASE=Path(__file__).resolve().parents[1];sys.path.insert(0,str(BASE))
from export import decode_int
run=BASE/'runs/wbc_bccd160_20261021';log=np.load(run/'historical_cell_unknown_true_class_probe.npz')['logits'];b,s,c=decode_int(log,'fullframe',True);ids=np.argsort(-s,kind='stable')[:15]
x=np.load(run/'historical_cell_unknown_true_class_probe.npz')['rgb'];out={'candidate':run.name,'strongest_candidates':[{'box':b[i].tolist(),'score':int(s[i]),'class':int(c[i])} for i in ids],'cell_ROI_RGB_mean':x[47:115,65:105].mean((0,1)).tolist(),'entire_RGB_mean':x.mean((0,1)).tolist()}
(run/'camera_diagnosis.json').write_text(json.dumps(out,indent=2),encoding='utf8');print(json.dumps(out),flush=True)

"""Read-only development probes; cannot select a checkpoint or threshold."""
import argparse,json,sys
from pathlib import Path
import numpy as np
import torch
BASE=Path(__file__).resolve().parents[1];sys.path.insert(0,str(BASE))
from export import integer,decode_int,SIG
p=argparse.ArgumentParser();p.add_argument('--name',default='wbc_bccd160_objectmax_20261021');args=p.parse_args()
run=BASE/'runs'/args.name;ck=torch.load(run/'qat_best.pt',weights_only=False,map_location='cpu');state=ck['state'];q={}
for i in range(10):
 w=state[f'blocks.{i}.conv.weight'].numpy();bi=state[f'blocks.{i}.conv.bias'].numpy();s=state[f'blocks.{i}.shift'].numpy();ins=1/256 if i==0 else .25;outs=1/256 if i==9 else .25;lim=127 if i in [0,9] else 7
 q[f'w{i}']=np.clip(np.floor(w*(ins/outs)*np.exp2(s)[:,None,None,None]+.5),-lim,lim).astype(np.int8);q[f'b{i}']=np.floor(bi/outs*np.exp2(s)+.5).astype(np.int32);q[f's{i}']=s.astype(np.uint8)
rows=[]
for name in ['user_empty_scene','historical_cell_unknown_true_class']:
 x=np.load(BASE/'runs/wbc_bccd160_20261021'/(name+'_probe.npz'))['rgb'];log,_=integer(x,q);b,s,c=decode_int(log,'fullframe',True);ids=np.argsort(-s,kind='stable')[:3]
 sig=SIG[np.clip((log.transpose(1,2,0).reshape(10,10,3,10).astype(np.int64)>>4)+128,0,255)];obj=(sig[...,4]*255).ravel();cls=sig[...,5:].max(-1).ravel();oi=np.argsort(-obj,kind='stable')[:3]
 rows.append({'name':name,'top':[{'score':int(s[i]),'objectness_x255':int(obj[i]),'class_sigmoid':int(cls[i]),'box':b[i].tolist(),'class':int(c[i])} for i in ids],'objectness_only_top':[{'score':int(obj[i]),'box':b[i].tolist(),'class':int(c[i])} for i in oi]})
result={'epoch':ck['epoch'],'purpose':'Development observation only; selected by VAL, no checkpoint or confidence changes allowed here','probes':rows};(run/f'development_progress_epoch{ck["epoch"]}.json').write_text(json.dumps(result,indent=2),encoding='utf8');print(json.dumps(result),flush=True)

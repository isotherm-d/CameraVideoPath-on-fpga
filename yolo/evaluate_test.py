"""One held-out evaluation after freezing model and VAL-selected confidence."""
import argparse,hashlib,json
import numpy as np
import torch
from model import Detector
from export import ROOT,integer
from calibrate import predict
from train import iou

def main(args):
 folder=ROOT/'runs'/args.name
 frozen=['detector.pt','quantized.npz','integer_validation.json','protocol.json']
 hashes={n:hashlib.sha256((folder/n).read_bytes()).hexdigest() for n in frozen}
 selected=json.loads((folder/'integer_validation.json').read_text())['selected']
 ckpt=torch.load(folder/'detector.pt',map_location='cpu',weights_only=False);p=ckpt['protocol']
 data=np.load(ROOT/'data'/p['data_file']);d=np.load(folder/'quantized.npz')
 model=Detector(p['width'],p['side']).cuda();model.enable_qat();model.load_state_dict(ckpt['state']);model.eval()
 torch.backends.cuda.matmul.allow_tf32=False;torch.backends.cudnn.allow_tf32=False
 logs=[]
 with torch.no_grad():
  for i in range(0,len(data['test_x']),64):
   x=torch.tensor(data['test_x'][i:i+64],device='cuda').permute(0,3,1,2).float()/256
   raw=model(x).permute(0,1,4,2,3).reshape(len(x),18,10,10)
   logs.extend(np.rint(raw.cpu().numpy()*256).astype(np.int16))
 for idx in np.linspace(0,len(logs)-1,6,dtype=int):
  gold,_=integer(data['test_x'][idx],d)
  assert np.array_equal(gold,logs[idx]),f'TEST exact integer mismatch {idx}'
 rows=[]
 for i,log in enumerate(logs):
  bb,ss=predict(log,selected['score_q16']);n=int(data['test_n'][i]);gt=data['test_boxes'][i,:n];used=set();tp=0
  for b in bb:
   ov=iou(b,gt) if n else np.array([]);k=next((int(k) for k in np.argsort(-ov) if k not in used and ov[k]>=.5),None)
   if k is not None:used.add(k);tp+=1
  rows.append({'index':i,'objects':n,'tp':tp,'fp':len(bb)-tp,'boxes':bb.tolist(),'scores':ss.tolist()})
 tp=sum(r['tp'] for r in rows);fp=sum(r['fp'] for r in rows);total=sum(r['objects'] for r in rows)
 neg=[r for r in rows if r['objects']==0]
 result={'status':'held-out BCCD only; not camera or patient-independent validation','frozen_sha256':hashes,
 'threshold_q16':selected['score_q16'],'numpy_QAT_exact_vectors':6,'images':len(rows),'objects':total,
 'recall_IoU50':tp/total,'precision_IoU50':tp/(tp+fp),'FP_per_image':fp/len(rows),
 'negative_images':len(neg),'false_positive_negative_images':sum(r['fp']>0 for r in neg),'predictions':rows}
 assert hashes=={n:hashlib.sha256((folder/n).read_bytes()).hexdigest() for n in frozen}
 (folder/'test_result.json').write_text(json.dumps(result,indent=2))
 print(json.dumps({k:v for k,v in result.items() if k not in ('predictions','frozen_sha256')},indent=2))
if __name__=='__main__':
 ap=argparse.ArgumentParser();ap.add_argument('--name',default='s160_w0075_intqat');main(ap.parse_args())

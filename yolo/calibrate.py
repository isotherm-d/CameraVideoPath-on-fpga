"""Select confidence on VAL only using the exact integer LUT/box decode."""
import argparse,json
from pathlib import Path
import numpy as np
import torch
from model import Detector
from export import integer,decode_int,ROOT,HDL
from train import iou
def predict(log,th):
 b,s=decode_int(log);valid=(b[:,0]<b[:,2])&(b[:,1]<b[:,3])
 ids=np.where((s>=th)&valid)[0];ids=ids[np.argsort(-s[ids],kind='stable')[:20]];keep=[]
 while len(ids) and len(keep)<5:
  k=ids[0];keep.append(k);ids=ids[1:]
  inter=np.maximum(np.minimum(b[k,2:],b[ids,2:])-np.maximum(b[k,:2],b[ids,:2]),0).prod(1)
  union=(b[k,2:]-b[k,:2]).prod()+(b[ids,2:]-b[ids,:2]).prod(1)-inter
  ids=ids[inter*256<=union*103]
 return b[keep]/640,s[keep]
def main(args):
 folder=ROOT/'runs'/args.name;ckpt=torch.load(folder/'detector.pt',weights_only=False,map_location='cpu');p=ckpt['protocol'];d=np.load(folder/'quantized.npz');data=np.load(ROOT/'data'/p['data_file'])
 torch.backends.cuda.matmul.allow_tf32=False;torch.backends.cudnn.allow_tf32=False
 model=Detector(p['width'],p['side']).cuda();model.enable_qat();model.load_state_dict(ckpt['state']);model.eval()
 logs=[]
 with torch.no_grad():
  for i in range(0,len(data['val_x']),64):
   x=torch.tensor(data['val_x'][i:i+64],device='cuda').permute(0,3,1,2).float()/256
   raw=model(x).permute(0,1,4,2,3).reshape(len(x),18,10,10)
   logs.extend(np.rint(raw.cpu().numpy()*256).astype(np.int16))
 for j,idx in enumerate(json.loads((folder/'vectors/manifest.json').read_text())['indices']):
  gold=np.load(folder/f'vectors/v{j}/golden.npz')['logits']
  if not np.array_equal(gold,logs[idx]):
   delta=np.abs(gold.astype(np.int64)-logs[idx].astype(np.int64));raise RuntimeError(f'QAT/golden integer mismatch vector {j}: {np.count_nonzero(delta)}, max={delta.max()}')
 report={'numpy_vs_QAT_vectors':6,'threshold_selection':'VAL only, macro recall >=0.90 and each-domain FP/image <=0.05','thresholds':[]}
 for thf in np.r_[np.arange(.25,.951,.025),np.arange(.955,.996,.005)]:
  th=round(thf*65025);metrics={}
  for domain,name in [(0,'BCCD'),(1,'Raabin')]:
   ids=np.where(data['val_domain']==domain)[0];tp=fp=0;total=0;negs=negfp=0
   for i in ids:
    bb,_=predict(logs[i],th);nn=data['val_n'][i];gt=data['val_boxes'][i,:nn];total+=int(nn);used=set()
    if nn==0:negs+=1;negfp+=int(len(bb)>0)
    for b in bb:
     ov=iou(b,gt) if nn else np.array([]);c=next((int(k) for k in np.argsort(-ov) if k not in used and ov[k]>=.5),None)
     if c is None:fp+=1
     else:tp+=1;used.add(c)
   metrics[name]={'recall':tp/max(total,1),'precision':tp/max(tp+fp,1),'FP_per_image':fp/len(ids),'negative_images':negs,'false_positive_negative_images':negfp,'objects':total,'images':len(ids)}
  ok=all(m['recall']>=.9 and m['FP_per_image']<=.05 for m in metrics.values())
  report['thresholds'].append({'threshold':float(thf),'score_q16':th,'metrics':metrics,'passes':ok})
 choices=[v for v in report['thresholds'] if v['passes']]
 selected=choices[0] if choices else None;report['selected']=selected
 (folder/'integer_validation.json').write_text(json.dumps(report,indent=2))
 if selected is None:raise RuntimeError('No deployment confidence meets validation gate')
 for j,idx in enumerate(json.loads((folder/'vectors/manifest.json').read_text())['indices']):
  bb,ss=predict(logs[idx],selected['score_q16']);coords=np.rint(bb*640).astype(int).tolist();(folder/f'vectors/v{j}/expected_boxes.json').write_text(json.dumps({'boxes_local640':coords,'scores':ss.tolist()},indent=2))
  words=[sum(int(v)<<(12*(3-k)) for k,v in enumerate(z)) for z in coords];words+= [0xffffffffffff]*(5-len(words));packed=sum(v<<(48*k) for k,v in enumerate(words))
  (folder/f'vectors/v{j}/expected_boxes.hex').write_text(f'{packed:060x}\n')
 (HDL/'yolo160_threshold.vh').write_text(f'`define YOLO_SCORE_THRESHOLD {selected["score_q16"]}\n`define YOLO_NMS_Q8 103\n')
 print('YOLO_INTEGER_VAL_GATE',json.dumps(selected),flush=True)
if __name__=='__main__':
 ap=argparse.ArgumentParser();ap.add_argument('--name',default='s160_w0075_intqat');main(ap.parse_args())

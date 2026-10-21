"""Freeze one confidence threshold on VAL with exact RTL LUT/decode/NMS."""
import argparse,hashlib,json,sys
from pathlib import Path
import numpy as np
import torch
BASE=Path(__file__).resolve().parents[1];sys.path.insert(0,str(BASE))
from model import Detector
from export import integer,decode_int,writehex
from train import iou
CLASSES=['BAS','EOS','LYM','MON','NEU']
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def predict(logits,threshold):
 b,s,c=decode_int(logits,'fullframe',True)
 ids=np.flatnonzero((s>=threshold)&(b[:,0]<b[:,2])&(b[:,1]<b[:,3]));ids=ids[np.argsort(-s[ids],kind='stable')[:20]];keep=[]
 while len(ids) and len(keep)<5:
  k=int(ids[0]);keep.append(k);ids=ids[1:]
  inter=np.maximum(np.minimum(b[k,2:],b[ids,2:])-np.maximum(b[k,:2],b[ids,:2]),0).prod(1)
  union=(b[k,2:]-b[k,:2]).prod()+(b[ids,2:]-b[ids,:2]).prod(1)-inter
  ids=ids[inter*256<=union*103]
 return b[keep],s[keep],c[keep]
def metrics(logs,data,split,threshold):
 typed_tp=np.zeros(5,int);typed_fp=np.zeros(5,int);typed_n=np.zeros(5,int);loc={0:[0,0,0,0,0,0],1:[0,0,0,0,0,0]};conf=np.zeros((5,6),int)
 scale=np.array([1280,720,1280,720]);rows=[]
 for i,log in enumerate(logs):
  bb,ss,cc=predict(log,threshold);domain=int(data[split+'_domain'][i]);n=int(data[split+'_n'][i]);gt=data[split+'_boxes'][i,:n];gc=data[split+'_classes'][i,:n]
  loc[domain][2]+=n;loc[domain][3]+=1
  if n==0:loc[domain][4]+=1;loc[domain][5]+=int(len(bb)>0)
  used=set();matches={}
  for b,c in zip(bb,cc):
   ov=iou(b/scale,gt) if n else np.array([]);j=next((int(j) for j in np.argsort(-ov) if j not in used and ov[j]>=.5),None)
   if j is None:loc[domain][1]+=1
   else:loc[domain][0]+=1;used.add(j);matches[j]=int(c)
   if domain==1:
    if j is not None and c==gc[j]:typed_tp[int(c)]+=1
    else:typed_fp[int(c)]+=1
  if domain==1:
   for j,c in enumerate(gc):typed_n[int(c)]+=1;conf[int(c),matches.get(j,5)]+=1
  rows.append({'index':i,'boxes':bb.tolist(),'classes':cc.tolist(),'scores':ss.tolist()})
 result={}
 for domain,name in [(0,'BCCD'),(1,'Raabin')]:
  tp,fp,total,count,neg,negfp=loc[domain]
  result[name]={'images':count,'objects':total,'TP':tp,'FP':fp,'recall':tp/max(total,1),'precision':tp/max(tp+fp,1),'F1':2*tp/max(tp+fp+total,1),'FP_per_image':fp/max(count,1),'negative_images':neg,'false_positive_negative_images':negfp}
 per={}
 for c,name in enumerate(CLASSES):
  tp,fp,total=int(typed_tp[c]),int(typed_fp[c]),int(typed_n[c]);per[name]={'TP':tp,'FP':fp,'objects':total,'recall':tp/max(total,1),'precision':tp/max(tp+fp,1),'F1':2*tp/max(tp+fp+total,1)}
 result['five_classes']=per;result['joint_macro_F1']=float(np.mean([v['F1'] for v in per.values()]));result['joint_correct_recall']=int(typed_tp.sum())/max(typed_n.sum(),1)
 result['confusion_gt_pred_miss']=conf.tolist();result['objective']=.7*result['joint_macro_F1']+.3*result['BCCD']['F1']-.1*result['BCCD']['false_positive_negative_images']/max(result['BCCD']['negative_images'],1)
 return result,rows
def logits(model,x):
 output=[]
 with torch.no_grad():
  for k in range(0,len(x),64):
   a=torch.tensor(x[k:k+64],device='cuda').permute(0,3,1,2).float()/256
   q=model(a).permute(0,1,4,2,3).reshape(len(a),30,10,10)
   output.extend(np.rint(q.cpu().numpy()*256).astype(np.int16))
 return output
def main(args):
 run=BASE/'runs'/args.name;ckpt=torch.load(run/'detector.pt',weights_only=False,map_location='cuda');p=ckpt['protocol']
 assert p['geometry']=='fullframe' and p['classes']==CLASSES
 spec={'selection':'VAL only: maximize 0.7 joint macroF1 + 0.3 BCCD localization F1 - 0.1 negative-image false positive rate',
 'thresholds':[float(v) for v in np.arange(.10,.976,.025)],'ties':'prefer higher threshold','NMS':'class-agnostic top20, 103/256, five outputs','test_opened':False}
 protocol=run/'confidence_protocol.json'
 if protocol.exists():assert json.loads(protocol.read_text())==spec
 else:protocol.write_text(json.dumps(spec,indent=2))
 torch.backends.cuda.matmul.allow_tf32=False;torch.backends.cudnn.allow_tf32=False
 model=Detector(.075,160,5,p.get('wide_head',False)).cuda();model.enable_qat();model.load_state_dict(ckpt['state']);model.eval()
 d=np.load(BASE/'data'/p['data_file']);q=np.load(run/'quantized.npz');logs=logits(model,d['val_x'])
 selection=[]
 for c in range(5):selection+=list(map(int,np.flatnonzero(d['val_classes'][:,0]==c)[:2]))
 selection+=list(map(int,np.flatnonzero((d['val_domain']==0)&(d['val_n']>0))[:2]))
 selection+=list(map(int,np.flatnonzero(d['val_n']==0)[:2]))
 for i in selection:
  gold,_=integer(d['val_x'][i],q)
  assert np.array_equal(gold,logs[i]),'QAT/NumPy exact mismatch '+str(i)
 choices=[]
 for th in spec['thresholds']:
  m,_=metrics(logs,d,'val',round(th*65025));choices.append({'threshold':th,'score_q16':round(th*65025),'metrics':m})
 best=max(choices,key=lambda z:(z['metrics']['objective'],z['threshold']))
 result={'checkpoint_sha256':sha(run/'detector.pt'),'quantized_sha256':sha(run/'quantized.npz'),'selection_protocol':spec,
         'numpy_QAT_exact_vectors':len(selection),'selected':best,'thresholds':choices}
 (run/'integer_validation.json').write_text(json.dumps(result,indent=2))
 if args.activate:
  hdl=BASE.parent/'08_csi_dsi_cs500_7cun/user_source/hdl_source/yolo'
  (hdl/'yolo160_threshold.vh').write_text(f'`define YOLO_SCORE_THRESHOLD {best["score_q16"]}\n`define YOLO_NMS_Q8 103\n')
  assert json.loads((run/'vectors/manifest.json').read_text())['indices']==selection
  for j,i in enumerate(selection):
   folder=run/f'vectors/v{j}';bb,ss,cc=predict(logs[i],best['score_q16'])
   words=[sum(int(v)<<(12*(3-k)) for k,v in enumerate(b)) for b in bb]+[0xffffffffffff]*(5-len(bb))
   writehex(folder/'expected_boxes.hex',[sum(v<<(48*k) for k,v in enumerate(words))],60)
   classes=cc.tolist()+[5]*(5-len(cc));scores=ss.tolist()+[0]*(5-len(ss))
   writehex(folder/'expected_classes.hex',[sum(int(v)<<(3*k) for k,v in enumerate(classes))],4)
   writehex(folder/'expected_scores.hex',[sum(int(v)<<(16*k) for k,v in enumerate(scores))],20)
   (folder/'expected_boxes.json').write_text(json.dumps({'boxes_global720p':bb.tolist(),'classes':cc.tolist(),'scores':ss.tolist()},indent=2))
 print('FIVE_INTEGER_VAL',args.name,json.dumps(best),flush=True)
if __name__=='__main__':
 parser=argparse.ArgumentParser();parser.add_argument('--name',required=True);parser.add_argument('--activate',action='store_true');main(parser.parse_args())

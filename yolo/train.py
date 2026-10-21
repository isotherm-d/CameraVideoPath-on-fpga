"""Train, quantization-fine-tune and freeze one-class WBC detection candidates."""
import argparse,copy,hashlib,json,random,time
from pathlib import Path
import numpy as np
import torch
from torch.nn import functional as F
from model import Detector,decode,loss
ROOT=Path(__file__).resolve().parent
def js(p,v):p.write_text(json.dumps(v,indent=2),encoding='utf8')
def iou(a,b):
 lo=np.maximum(a[:2],b[:,:2]);hi=np.minimum(a[2:],b[:,2:]);inter=np.maximum(hi-lo,0).prod(1)
 return inter/np.maximum(np.maximum(a[2:]-a[:2],0).prod()+np.maximum(b[:,2:]-b[:,:2],0).prod(1)-inter,1e-8)
def nms(bb,ss,threshold=.05,max_keep=5):
 ids=np.where(ss>=threshold)[0];ids=ids[np.argsort(-ss[ids],kind='stable')];keep=[]
 while len(ids) and len(keep)<max_keep:
  k=ids[0];keep.append(k);ids=ids[1:];ids=ids[iou(bb[k],bb[ids])<.4]
 return bb[keep].clip(0,1),ss[keep]
@torch.no_grad()
def evaluate(model,x,gt,nn,dom):
 model.eval();pred=[];threshold=.25
 for i in range(0,len(x),64):
  bb,sc=decode(model(x[i:i+64]),model.side);bb=bb.cpu().numpy().reshape(-1,3*(model.side//16)**2,4);sc=sc.cpu().numpy().reshape(len(bb),-1)
  pred.extend(nms(b,s) for b,s in zip(bb,sc))
 result={}
 for d,name in [(0,'BCCD'),(1,'Raabin'),(-1,'all')]:
  ids=np.arange(len(x)) if d<0 else np.where(dom==d)[0]
  if not len(ids):continue
  detected=[];matched_iou=[];total=int(nn[ids].sum());tp=fp=0
  for k in ids:
   bb,sc=pred[k];truth=gt[k,:nn[k]];used=set()
   for box,score in zip(bb,sc):
    ov=iou(box,truth) if len(truth) else np.array([]);order=np.argsort(-ov);match=next((int(z) for z in order if z not in used and ov[z]>=.5),None)
    hit=match is not None
    if hit:used.add(match)
    detected.append((float(score),hit))
    if score>=threshold:
     tp+=int(hit);fp+=int(not hit)
     if hit:matched_iou.append(float(ov[match]))
  detected.sort(key=lambda z:-z[0]);flags=np.array([int(z[1]) for z in detected]);cum=flags.cumsum();rec=cum/max(total,1);prec=cum/np.arange(1,len(cum)+1)
  ap=float(np.mean([prec[rec>=r].max(initial=0) for r in np.linspace(0,1,101)]))
  result[name]={'AP50':ap,'recall_at_025':tp/max(total,1),'precision_at_025':tp/max(tp+fp,1),'FP_per_image_at_025':fp/len(ids),'matched_IoU_at_025':float(np.mean(matched_iou)) if matched_iou else 0,'images':len(ids),'objects':total}
 result['selection_score']=float(np.mean([v['AP50'] for k,v in result.items() if k in ['BCCD','Raabin']]))
 return result
def augment(x,bb,n,labels=None):
 b=len(x);flip=torch.rand(b,device=x.device)<.5;x=torch.where(flip[:,None,None,None],x.flip(3),x)
 xx=bb.clone();bb=bb.clone();bb[...,0]=torch.where(flip[:,None],1-xx[...,2],xx[...,0]);bb[...,2]=torch.where(flip[:,None],1-xx[...,0],xx[...,2])
 flip=torch.rand(b,device=x.device)<.5;x=torch.where(flip[:,None,None,None],x.flip(2),x);yy=bb.clone();bb[...,1]=torch.where(flip[:,None],1-yy[...,3],yy[...,1]);bb[...,3]=torch.where(flip[:,None],1-yy[...,1],yy[...,3])
 # Affine crop/zoom, with exact box transformation and removal of clipped objects.
 scale=.75+torch.rand(b,device=x.device)*.5;trans=(torch.rand(b,2,device=x.device)-.5)*.25
 theta=torch.zeros(b,2,3,device=x.device);theta[:,0,0]=scale;theta[:,1,1]=scale;theta[:,:,2]=trans
 grid=F.affine_grid(theta,x.shape,align_corners=False);x=F.grid_sample(x,grid,padding_mode='border',align_corners=False)
 bb=((bb.reshape(b,-1,2,2)*2-1-trans[:,None,None,:])/scale[:,None,None,None]+1)/2;bb=bb.reshape(b,-1,4).clamp(0,1)
 valid=(torch.arange(bb.shape[1],device=x.device)[None]<n[:,None])&((bb[...,2:]-bb[...,:2]).amin(-1)>.04)
 # Compact per-image targets after clipping.
 rank=valid.long().cumsum(1)-1;dest=torch.zeros_like(bb);bi=torch.arange(b,device=x.device)[:,None].expand_as(valid);dest[bi[valid],rank[valid]]=bb[valid];n=valid.sum(1)
 if labels is not None:
  compact=torch.full_like(labels,-1);compact[bi[valid],rank[valid]]=labels[valid]
 gray=x.mean(1,keepdim=True);sat=.65+torch.rand(b,1,1,1,device=x.device)*.7
 x=(gray+(x-gray)*sat)*(.7+torch.rand(b,3,1,1,device=x.device)*.6)
 x=x.clamp(0,255/256).pow(.8+torch.rand(b,1,1,1,device=x.device)*.4)
 x=torch.floor(x*256+.5).clamp(0,255)/256
 return (x,dest,n,compact) if labels is not None else (x,dest,n)
def run(args):
 out=ROOT/'runs'/args.name
 if (out/'frozen.json').exists():raise FileExistsError('Frozen experiment already exists')
 out.mkdir(parents=True,exist_ok=True);seed=20261020;random.seed(seed);np.random.seed(seed);torch.manual_seed(seed);torch.cuda.manual_seed_all(seed)
 torch.set_num_threads(4);torch.backends.cudnn.benchmark=True
 device='cuda';d=np.load(ROOT/'data'/args.data);side=args.side
 def x(s):
  a=torch.from_numpy(d[s+'_x']).permute(0,3,1,2).to(device).float()/256
  if side!=160:a=F.interpolate(a,(side,side),mode='nearest-exact')
  return a
 tx,vx=x('train'),x('val');tb=torch.tensor(d['train_boxes'],device=device);tn=torch.tensor(d['train_n'],device=device)
 vb,vn,vd=d['val_boxes'],d['val_n'],d['val_domain'];domain=d['train_domain']
 # Balance natural BCCD scenes and single-cell Raabin masks.
 prob=np.zeros(len(tx))
 for j in [0,1]:prob[domain==j]=.5/max((domain==j).sum(),1)
 pp=torch.tensor(prob,device=device)
 model=Detector(args.width,side).to(device);best=-1.;history=[];start=time.monotonic()
 protocol={'seed':seed,'side':side,'width':args.width,'channels':model.channels,'classes':['WBC'],'first_last_weights':8,'hidden_weights':4,'hidden_activations':4,'input_scale':1/256,'hidden_scale':.25,'logit_scale':1/256,'strides':16,'fp32_epochs':args.epochs,'qat_epochs':args.qat_epochs,'checkpoint_selection':'macro domain AP50 on VAL only','test_opened':False,'data_file':args.data,'dataset_manifest_sha256':hashlib.sha256((ROOT/'data'/args.manifest).read_bytes()).hexdigest()}
 (out/'data_manifest.json').write_bytes((ROOT/'data'/args.manifest).read_bytes())
 js(out/'protocol.json',protocol)
 for phase,epochs,lr in [('fp32',args.epochs,1e-3),('qat',args.qat_epochs,1e-4)]:
  if phase=='qat':
   model.load_state_dict(best_state);model.enable_qat();best=-1.
  opt=torch.optim.AdamW(model.parameters(),lr=lr,weight_decay=1e-4);sched=torch.optim.lr_scheduler.CosineAnnealingLR(opt,epochs)
  for ep in range(1,epochs+1):
   model.train();ids=torch.multinomial(pp,len(tx),True);loss_sum=0.
   for i in range(0,len(tx),args.batch):
    ii=ids[i:i+args.batch];a,b,n=augment(tx[ii],tb[ii],tn[ii]);opt.zero_grad(set_to_none=True);ll=loss(model(a),b,n,side);ll.backward();torch.nn.utils.clip_grad_norm_(model.parameters(),10);opt.step();loss_sum+=float(ll.detach())*len(ii)
   sched.step()
   if ep==1 or ep%5==0 or ep==epochs:
    metrics=evaluate(model,vx,vb,vn,vd);score=metrics['selection_score']
    if score>best:
     best=score;best_state=copy.deepcopy(model.state_dict());best_metric=metrics;best_ep=ep
     torch.save({'state':best_state,'protocol':protocol,'phase':phase,'epoch':ep,'validation':metrics},out/f'{phase}_best.pt')
    item={'phase':phase,'epoch':ep,'loss':loss_sum/len(tx),'validation':metrics,'best':best,'seconds':time.monotonic()-start};history.append(item);js(out/'history.json',history)
    print(json.dumps(item),flush=True)
  js(out/f'{phase}_validation.json',{'epoch':best_ep,'validation':best_metric})
 model.load_state_dict(best_state);torch.save({'state':best_state,'protocol':protocol,'phase':'qat','validation':best_metric},out/'detector.pt')
 # Integer export is the deployment source, independent of inference framework.
 arrays={};spec=[]
 for i,b in enumerate(model.blocks):
  w=b.conv.weight.detach().cpu().numpy();bias=b.conv.bias.detach().cpu().numpy();shift=b.shift.cpu().numpy();factor=(b.ins/b.outs)*np.exp2(shift)[:,None,None,None];qmax=2**(b.bits-1)-1
  qw=np.clip(np.floor(w*factor+.5),-qmax,qmax).astype(np.int8);qb=np.floor(bias/b.outs*np.exp2(shift)+.5).astype(np.int64)
  if abs(qb).max()>=2**31:raise OverflowError('Bias exceeds int32')
  arrays[f'w{i}']=qw;arrays[f'b{i}']=qb.astype(np.int32);arrays[f's{i}']=shift.astype(np.uint8)
  spec.append({'layer':i,'shape':list(qw.shape),'bits':b.bits,'pool':i<4,'first':i==0,'last':i==9})
 np.savez(out/'quantized.npz',**arrays);js(out/'layers.json',spec)
 js(out/'frozen.json',{'validation':best_metric,'test_opened':False,'quantized_sha256':hashlib.sha256((out/'quantized.npz').read_bytes()).hexdigest(),'elapsed_seconds':time.monotonic()-start})
 print('YOLO_CANDIDATE_FROZEN',out,flush=True)
if __name__=='__main__':
 ap=argparse.ArgumentParser();ap.add_argument('--name',default='s160_w010');ap.add_argument('--side',type=int,default=160);ap.add_argument('--width',type=float,default=.1);ap.add_argument('--epochs',type=int,default=100);ap.add_argument('--qat-epochs',type=int,default=30);ap.add_argument('--batch',type=int,default=64);ap.add_argument('--data',default='wbc160_v2.npz');ap.add_argument('--manifest',default='manifest_v2.json');run(ap.parse_args())

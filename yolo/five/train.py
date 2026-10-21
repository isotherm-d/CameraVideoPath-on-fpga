"""Five-class joint detection/classification. BCCD objects have no class loss."""
import argparse,copy,hashlib,json,random,sys,time
from pathlib import Path
import numpy as np
import torch
from torch.nn import functional as F
BASE=Path(__file__).resolve().parents[1];sys.path.insert(0,str(BASE))
from model import Detector,decode_classes,loss
from train import augment,iou
CLASSES=['BAS','EOS','LYM','MON','NEU']
def js(p,v):p.write_text(json.dumps(v,indent=2),encoding='utf8')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def selected(bb,sc,threshold=.05):
 ids=np.flatnonzero(sc>=threshold);ids=ids[np.argsort(-sc[ids],kind='stable')[:20]];keep=[]
 while len(ids) and len(keep)<5:
  k=int(ids[0]);keep.append(k);ids=ids[1:];ids=ids[iou(bb[k],bb[ids])<=103/256]
 return np.array(keep,dtype=int)
def average_precision(entries,total):
 entries=sorted(entries,key=lambda z:-z[0]);flags=np.array([int(v[1]) for v in entries]);rec=flags.cumsum()/max(total,1)
 prec=flags.cumsum()/np.arange(1,len(flags)+1)
 return float(np.mean([prec[rec>=r].max(initial=0) for r in np.linspace(0,1,101)]))
@torch.no_grad()
def evaluate(model,x,gt,nn,labels,dom):
 model.eval();pred=[]
 for k in range(0,len(x),64):
  bb,ss,cc=decode_classes(model(x[k:k+64]),model.side)
  b=bb.cpu().numpy().reshape(len(bb),-1,4);s=ss.cpu().numpy().reshape(len(bb),-1);c=cc.cpu().numpy().reshape(len(bb),-1)
  for b1,s1,c1 in zip(b,s,c):
   ids=selected(b1,s1);pred.append((b1[ids].clip(0,1),s1[ids],c1[ids]))
 result={};joint=[[] for _ in range(5)];totals=[int((labels==k).sum()) for k in range(5)];conf=np.zeros((5,6),int)
 for domain,name in [(0,'BCCD_localization'),(1,'Raabin_localization')]:
  entries=[];total=0;matched=0;correct=0
  for i in np.where(dom==domain)[0]:
   b,s,c=pred[i];n=int(nn[i]);truth=gt[i,:n];total+=n;used=set()
   for box,score,klass in zip(b,s,c):
    ov=iou(box,truth) if n else np.array([]);j=next((int(j) for j in np.argsort(-ov) if j not in used and ov[j]>=.5),None)
    hit=j is not None
    if hit:used.add(j);matched+=1
    entries.append((float(score),hit))
    if domain==1:
     good=hit and int(klass)==int(labels[i,j]);joint[int(klass)].append((float(score),good))
     if good:correct+=1
   if domain==1:
    for j in range(n):
     ov=np.array([float(iou(truth[j],b)[k]) for k in range(len(b))]) if len(b) else np.array([])
     k=int(np.argmax(ov)) if len(ov) and ov.max()>=.5 else -1
     conf[int(labels[i,j]),int(c[k]) if k>=0 else 5]+=1
  result[name]={'AP50':average_precision(entries,total),'objects':total,'localized_at005':matched,'typed_correct_at005':correct}
 per={CLASSES[k]:average_precision(joint[k],totals[k]) for k in range(5)}
 result['joint_AP50_by_class']=per;result['joint_macro_AP50']=float(np.mean(list(per.values())))
 result['joint_top1_IoU50']=float(conf[:,:5].trace()/max(conf.sum(),1));result['confusion_gt_pred_miss']=conf.tolist()
 result['selection_score']=.7*result['joint_macro_AP50']+.3*result['BCCD_localization']['AP50']
 return result

def mosaic(x,bb,n,cc,tx,tb,tn,tc,pool):
 # Real labelled single-cell views form four tiles. Every cell retains a box/type.
 take=torch.rand(len(x),device=x.device)<.30;ids=torch.where(take)[0]
 if not len(ids):return x,bb,n,cc
 picks=pool[torch.randint(len(pool),(len(ids),4),device=x.device)]
 tiles=F.interpolate(tx[picks.flatten()],(80,80),mode='nearest-exact').reshape(len(ids),4,3,80,80)
 mixed=torch.cat((torch.cat((tiles[:,0],tiles[:,1]),3),torch.cat((tiles[:,2],tiles[:,3]),3)),2)
 x=x.clone();bb=bb.clone();n=n.clone();cc=cc.clone();x[ids]=mixed;bb[ids]=0;cc[ids]=-1;n[ids]=4
 for q in range(4):
  offset=torch.tensor([q%2,q//2,q%2,q//2],device=x.device)*.5
  bb[ids,q]=tb[picks[:,q],0]*.5+offset;cc[ids,q]=tc[picks[:,q],0]
 return x,bb,n,cc

def main(args):
 out=BASE/'runs'/args.name
 if (out/'frozen.json').exists():raise FileExistsError('Preserve frozen experiment; choose another name')
 out.mkdir(parents=True,exist_ok=True);torch.set_num_threads(4);random.seed(args.seed);np.random.seed(args.seed);torch.manual_seed(args.seed);torch.cuda.manual_seed_all(args.seed)
 torch.backends.cudnn.benchmark=True;torch.backends.cuda.matmul.allow_tf32=False;torch.backends.cudnn.allow_tf32=False
 data=BASE/'data'/('five_'+args.geometry+'.npz');d=np.load(data)
 tx=torch.tensor(d['train_x'],device='cuda').permute(0,3,1,2).float()/256
 vx=torch.tensor(d['val_x'],device='cuda').permute(0,3,1,2).float()/256
 tb=torch.tensor(d['train_boxes'],device='cuda');tn=torch.tensor(d['train_n'],device='cuda');tc=torch.tensor(d['train_classes'],device='cuda')
 p=np.zeros(len(tx));domain=d['train_domain'];cc=d['train_classes'][:,0]
 p[domain==0]=args.bccd_weight/max((domain==0).sum(),1)
 for c in range(5):p[(domain==1)&(cc==c)]=(1-args.bccd_weight)/5/max(((domain==1)&(cc==c)).sum(),1)
 pp=torch.tensor(p,device='cuda');pool=torch.where(tc[:,0]>=0)[0]
 model=Detector(.075,160,5,args.wide_head).cuda()
 warm=BASE/'frozen/detector.pt' if args.qat_warmstart else BASE/'runs/s160_w0075_intqat/fp32_best.pt'
 # Float warmstart retains the proven localization backbone, not the old class.
 if not args.qat_warmstart:
  old=torch.load(warm,weights_only=False,map_location='cuda')['state'];own=model.state_dict()
  model.load_state_dict({k:v for k,v in old.items() if k in own and own[k].shape==v.shape},strict=False)
  with torch.no_grad():
   for a in range(3):
    if model.blocks[9].conv.weight.shape[1:]==old['blocks.9.conv.weight'].shape[1:]:
     model.blocks[9].conv.weight[a*10:a*10+5]=old['blocks.9.conv.weight'][a*6:a*6+5]
     model.blocks[9].conv.bias[a*10:a*10+5]=old['blocks.9.conv.bias'][a*6:a*6+5]
 protocol={'seed':args.seed,'side':160,'width':.075,'classes':CLASSES,'channels':model.channels,'fields':10,'geometry':args.geometry,
 'first_last_weights':8,'hidden_weights':4,'hidden_activations':4,'input_scale':1/256,'hidden_scale':.25,'logit_scale':1/256,
 'fp32_epochs':args.epochs,'qat_epochs':args.qat_epochs,'data_file':data.name,'warmstart_sha256':sha(warm),
 'data_manifest_sha256':sha(BASE/'data'/('five_'+args.geometry+'_manifest.json')),
 'selection':'VAL only: 0.7 joint five-class macroAP50 + 0.3 BCCD localizationAP50','test_opened':False,
 'untyped_BCCD':'box/objectness only; never invent class labels','mosaic_probability':.30,'wide_head':args.wide_head,'BCCD_training_weight':args.bccd_weight}
 js(out/'protocol.json',protocol);(out/'data_manifest.json').write_bytes((BASE/'data'/('five_'+args.geometry+'_manifest.json')).read_bytes())
 history=[];best_state=None;start=time.monotonic()
 for phase,epochs,lr in [('fp32',args.epochs,7e-4),('qat',args.qat_epochs,7e-5)]:
  if phase=='qat':model.load_state_dict(best_state);model.enable_qat()
  best=-1.;opt=torch.optim.AdamW(model.parameters(),lr=lr,weight_decay=1e-4);sched=torch.optim.lr_scheduler.CosineAnnealingLR(opt,epochs)
  for ep in range(1,epochs+1):
   model.train();ids=torch.multinomial(pp,len(tx),True);total=0.
   for j in range(0,len(ids),64):
    ii=ids[j:j+64];a,b,n,c=mosaic(tx[ii],tb[ii],tn[ii],tc[ii],tx,tb,tn,tc,pool)
    a,b,n,c=augment(a,b,n,c);opt.zero_grad(set_to_none=True);l=loss(model(a),b,n,160,c);l.backward();torch.nn.utils.clip_grad_norm_(model.parameters(),10);opt.step();total+=float(l.detach())*len(ii)
   sched.step()
   if ep==1 or ep%5==0 or ep==epochs:
    metrics=evaluate(model,vx,d['val_boxes'],d['val_n'],d['val_classes'],d['val_domain']);score=metrics['selection_score']
    if score>best:
     best=score;best_state=copy.deepcopy(model.state_dict());best_metrics=metrics;best_ep=ep
     torch.save({'state':best_state,'protocol':protocol,'epoch':ep,'phase':phase,'validation':metrics},out/(phase+'_best.pt'))
    row={'phase':phase,'epoch':ep,'loss':total/len(tx),'validation':metrics,'best':best,'seconds':time.monotonic()-start};history.append(row);js(out/'history.json',history);print(json.dumps(row),flush=True)
  js(out/(phase+'_validation.json'),{'epoch':best_ep,'validation':best_metrics})
 model.load_state_dict(best_state);torch.save({'state':best_state,'protocol':protocol,'phase':'qat','validation':best_metrics},out/'detector.pt')
 arrays={};spec=[]
 for i,b in enumerate(model.blocks):
  w=b.conv.weight.detach().cpu().numpy();bi=b.conv.bias.detach().cpu().numpy();s=b.shift.cpu().numpy();factor=(b.ins/b.outs)*np.exp2(s)[:,None,None,None];limit=2**(b.bits-1)-1
  arrays[f'w{i}']=np.clip(np.floor(w*factor+.5),-limit,limit).astype(np.int8)
  qb=np.floor(bi/b.outs*np.exp2(s)+.5);assert abs(qb).max()<2**31
  arrays[f'b{i}']=qb.astype(np.int32);arrays[f's{i}']=s.astype(np.uint8)
  spec.append({'layer':i,'shape':list(w.shape),'bits':b.bits,'pool':i<4})
 np.savez(out/'quantized.npz',**arrays);js(out/'layers.json',spec)
 js(out/'frozen.json',{'validation':best_metrics,'quantized_sha256':sha(out/'quantized.npz'),'checkpoint_sha256':sha(out/'detector.pt'),'test_opened':False,'elapsed_seconds':time.monotonic()-start})
 print('FIVE_MODEL_FROZEN',out,flush=True)
if __name__=='__main__':
 ap=argparse.ArgumentParser();ap.add_argument('--name',required=True);ap.add_argument('--geometry',choices=['center640','fullframe'],required=True)
 ap.add_argument('--epochs',type=int,default=250);ap.add_argument('--qat-epochs',type=int,default=60);ap.add_argument('--seed',type=int,default=20261020)
 ap.add_argument('--qat-warmstart',action='store_true');ap.add_argument('--wide-head',action='store_true');ap.add_argument('--bccd-weight',type=float,default=.30);main(ap.parse_args())

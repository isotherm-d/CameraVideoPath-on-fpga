"""Two-source training without Raabin data/weights; FP32 followed by exact QAT."""
import argparse,copy,hashlib,json,random,sys,time
from pathlib import Path
import numpy as np
import torch
from torch.nn import functional as F
BASE=Path(__file__).resolve().parents[1];sys.path.insert(0,str(BASE))
from model import Detector,loss
from train import augment
from five.train import mosaic
from five.calibrate import logits,metrics as original_metrics
from export import decode_int
from robust.train import backgrounds
from robust.balanced.train import camera_augment
HOME=BASE/'wbc_bccd';CLASSES=['BAS','EOS','LYM','MON','NEU']
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def save(p,v):p.write_text(json.dumps(v,indent=2),encoding='utf8')
def checkpoint(p,v):
 tmp=p.with_suffix('.writing');torch.save(v,tmp);tmp.replace(p)

def measure(logs,data,threshold):
 m,rows=original_metrics(logs,data,'val',threshold);m['WBCAtt']=m.pop('Raabin')
 total_neg=m['WBCAtt']['negative_images']+m['BCCD']['negative_images']
 neg_fp=m['WBCAtt']['false_positive_negative_images']+m['BCCD']['false_positive_negative_images']
 m['acquired_negative_image_FP_rate']=neg_fp/max(total_neg,1)
 return m,rows

def main(args):
 run=BASE/'runs'/args.name
 if run.exists():raise FileExistsError('Keep existing runs immutable: '+str(run))
 protocol=json.loads((HOME/'protocol.json').read_text(encoding='utf8'));manifest=json.loads((HOME/'data_manifest.json').read_text(encoding='utf8'))
 assert manifest['sources']==['WBCAtt','BCCD'] and manifest['no_Raabin_rows']
 assert sha(BASE/'data/wbc_bccd160.npz')==manifest['npz_sha256']
 run.mkdir(parents=True);torch.set_num_threads(4);seed=args.seed
 random.seed(seed);np.random.seed(seed);torch.manual_seed(seed);torch.cuda.manual_seed_all(seed)
 torch.backends.cudnn.benchmark=True;torch.backends.cuda.matmul.allow_tf32=False;torch.backends.cudnn.allow_tf32=False
 warm=BASE/'runs/wbcatt160_seed20261021/fp32_best.pt';ck=torch.load(warm,weights_only=False,map_location='cuda')
 assert ck['protocol']['dataset']=='WBCAtt+ only; PBC-Normal image source' and ck['protocol']['warmstart'] is None
 model=Detector(.075,160,5,False).cuda();model.load_state_dict(ck['state'])
 d=np.load(BASE/'data/wbc_bccd160.npz');tx=torch.tensor(d['train_x'],device='cuda').permute(0,3,1,2).float()/256
 tb=torch.tensor(d['train_boxes'],device='cuda');tn=torch.tensor(d['train_n'],device='cuda');tc=torch.tensor(d['train_classes'],device='cuda');td=torch.tensor(d['train_domain'],device='cuda')
 assert (tc[td==0]==-1).all()
 pp=torch.zeros(len(tx),device='cuda')
 for c in range(5):mask=(td==1)&(tn>0)&(tc[:,0]==c);pp[mask]=(.50/5)/mask.sum()
 mask=(td==1)&(tn==0);pp[mask]=.10/mask.sum();pp[td==0]=.25/(td==0).sum();pool=torch.where((td==1)&(tn>0))[0]
 gen=torch.Generator(device='cuda').manual_seed(protocol['procedural_VAL_seed']);empty=backgrounds(256,generator=gen)
 protocol.update(seed=seed,name=args.name,side=160,width=.075,classes=CLASSES,channels=model.channels,fields=10,geometry='fullframe',wide_head=False,
  first_last_weights=8,hidden_weights=4,hidden_activations=4,input_scale=1/256,hidden_scale=.25,logit_scale=1/256,
  data_file='wbc_bccd160.npz',fp32_epochs=args.epochs,qat_epochs=args.qat_epochs,warmstart_sha256=sha(warm),
  warmstart_training_source='WBCAtt+ only',data_manifest_sha256=sha(HOME/'data_manifest.json'))
 save(run/'protocol.json',protocol);(run/'data_manifest.json').write_bytes((HOME/'data_manifest.json').read_bytes())
 files=[Path(__file__),HOME/'protocol.json',HOME/'prepare.py',BASE/'model.py',BASE/'train.py',BASE/'five/train.py',BASE/'five/calibrate.py',BASE/'export.py',BASE/'robust/train.py',BASE/'robust/balanced/train.py']
 pins={p.relative_to(BASE.parent).as_posix():sha(p) for p in files};save(run/'training_source_hashes.json',pins)
 history=[];start=time.monotonic();best_state=None
 for phase,epochs,lr in [('fp32',args.epochs,2e-4),('qat',args.qat_epochs,5e-5)]:
  if phase=='qat':model.load_state_dict(best_state);model.enable_qat()
  best=-1e9;opt=torch.optim.AdamW(model.parameters(),lr=lr,weight_decay=1e-4);sched=torch.optim.lr_scheduler.CosineAnnealingLR(opt,epochs)
  for ep in range(1,epochs+1):
   model.train();ids=torch.multinomial(pp,len(tx),True);total=0.
   for j in range(0,len(ids),64):
    ii=ids[j:j+64];a0,b0,n0,c0=tx[ii],tb[ii],tn[ii],tc[ii];domain=td[ii]
    pos=torch.where((domain==1)&(n0>0))[0]
    if len(pos):
     aa,bb,nn,cc=mosaic(a0[pos],b0[pos],n0[pos],c0[pos],tx,tb,tn,tc,pool)
     a0=a0.clone();b0=b0.clone();n0=n0.clone();c0=c0.clone();a0[pos]=aa;b0[pos]=bb;n0[pos]=nn;c0[pos]=cc
    a,b,n,c=augment(a0,b0,n0,c0)
    photo=torch.where(torch.rand(len(a),device='cuda')<torch.where(domain==1,.5,.25))[0]
    if len(photo):
     aa,bb,nn,cc=camera_augment(a0[photo],b0[photo],n0[photo],c0[photo]);a[photo]=aa;b[photo]=bb;n[photo]=nn;c[photo]=cc
    proc=torch.rand(len(a),device='cuda')<.15
    a[proc]=backgrounds(int(proc.sum()));b[proc]=0;n[proc]=0;c[proc]=-1
    opt.zero_grad(set_to_none=True);raw=model(a);ll=loss(raw,b,n,160,c)
    if (n==0).any():ll=ll+.5*F.softplus(raw[n==0,...,4].flatten(1).topk(20,dim=1).values).mean()
    ll.backward();torch.nn.utils.clip_grad_norm_(model.parameters(),10);opt.step();total+=float(ll.detach())*len(ii)
   sched.step()
   if ep==1 or ep%5==0 or ep==epochs:
    model.eval();logs=logits(model,d['val_x']);m,_=measure(logs,d,45518)
    with torch.no_grad():e=model(empty).permute(0,1,4,2,3).reshape(len(empty),30,10,10).cpu().numpy()
    e=np.rint(e*256).clip(-32768,32767).astype(np.int16)
    fp=sum((decode_int(v,'fullframe',True)[1]>=45518).any() for v in e)/len(e)
    score=.7*m['joint_macro_F1']+.3*m['BCCD']['F1']-.3*fp-.1*m['acquired_negative_image_FP_rate']
    if score>best:
     best=score;best_state=copy.deepcopy(model.state_dict());best_m=m;best_fp=fp;best_ep=ep
     checkpoint(run/(phase+'_best.pt'),{'state':best_state,'protocol':protocol,'phase':phase,'epoch':ep,'validation':m,'procedural_VAL_FP_rate':float(fp)})
    row={'phase':phase,'epoch':ep,'loss':total/len(tx),'WBCAtt_VAL_macro_F1':m['joint_macro_F1'],'BCCD_VAL_recall':m['BCCD']['recall'],'BCCD_VAL_precision':m['BCCD']['precision'],'BCCD_VAL_F1':m['BCCD']['F1'],'procedural_VAL_FP':float(fp),'objective':float(score),'best':float(best),'seconds':time.monotonic()-start}
    history.append(row);save(run/'history.json',history);print(json.dumps(row),flush=True)
  save(run/(phase+'_validation.json'),{'epoch':best_ep,'metrics':best_m,'procedural_VAL_FP_rate':float(best_fp)})
 model.load_state_dict(best_state);checkpoint(run/'detector.pt',{'state':best_state,'protocol':protocol,'phase':'qat','validation':best_m})
 arrays={}
 for i,b in enumerate(model.blocks):
  w=b.conv.weight.detach().cpu().numpy();bi=b.conv.bias.detach().cpu().numpy();s=b.shift.cpu().numpy();factor=(b.ins/b.outs)*np.exp2(s)[:,None,None,None];lim=2**(b.bits-1)-1
  arrays[f'w{i}']=np.clip(np.floor(w*factor+.5),-lim,lim).astype(np.int8);qb=np.floor(bi/b.outs*np.exp2(s)+.5);assert abs(qb).max()<2**31
  arrays[f'b{i}']=qb.astype(np.int32);arrays[f's{i}']=s.astype(np.uint8)
 np.savez(run/'quantized.npz',**arrays)
 save(run/'frozen.json',{'checkpoint_sha256':sha(run/'detector.pt'),'quantized_sha256':sha(run/'quantized.npz'),'validation':best_m,'procedural_VAL_FP_rate':float(best_fp),'TEST_used_for_selection':False,'seconds':time.monotonic()-start})
 for n,w in pins.items():assert sha(BASE.parent/n)==w,n
 print('TWO_SOURCE_TRAINING_FROZEN',args.name,flush=True)
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--name',default='wbc_bccd160_20261021');p.add_argument('--epochs',type=int,default=120);p.add_argument('--qat-epochs',type=int,default=80);p.add_argument('--seed',type=int,default=2026102103);main(p.parse_args())

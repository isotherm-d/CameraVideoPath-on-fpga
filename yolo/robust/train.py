"""WBCAtt-only fine tuning for empty scenes and photographed microscope panels.

No PC runtime changes. Procedural backgrounds are training augmentation, not a
second acquired dataset. Existing frozen WBCAtt experiment is never overwritten.
"""
import argparse,copy,hashlib,json,random,sys,time
from pathlib import Path
import numpy as np
import torch
from torch.nn import functional as F
BASE=Path(__file__).resolve().parents[1];sys.path.insert(0,str(BASE))
from model import Detector,loss
from train import augment
from five.train import mosaic
from five.calibrate import logits
from export import decode_int,integer
from wbcatt.evaluate import metrics
HOME=BASE/'robust'

def save(p,v):p.write_text(json.dumps(v,indent=2),encoding='utf8')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()

def backgrounds(n,device='cuda',generator=None):
 def rand(*shape):return torch.rand(*shape,device=device,generator=generator)
 base=rand(n,3,1,1);gray=rand(n,1,1,1)
 base=torch.where(rand(n,1,1,1)<.7,gray.expand(-1,3,-1,-1),base)
 coarse=F.interpolate(rand(n,1,5,5),size=(160,160),mode='bicubic',align_corners=False)
 textured=(base+(coarse-.5)*rand(n,1,1,1)*.7).clamp(0,1)
 yy=torch.linspace(0,1,160,device=device).view(1,1,160,1)
 xx=torch.linspace(0,1,160,device=device).view(1,1,1,160)
 for _ in range(2):
  x0=rand(n,1,1,1);y0=rand(n,1,1,1);w=.1+rand(n,1,1,1)*.8;h=.1+rand(n,1,1,1)*.8
  mask=(xx>x0)&(xx<x0+w)&(yy>y0)&(yy<y0+h)
  textured=torch.where(mask,textured*(.15+rand(n,1,1,1)*.7),textured)
 kind=rand(n,1,1,1)
 x=torch.where(kind<.25,base.expand(-1,-1,160,160),textured)
 x=torch.where((kind>=.25)&(kind<.4),rand(n,3,160,160),x)
 x=torch.where(kind>.96,torch.zeros_like(x),x)
 x=(x+torch.randn(x.shape,device=device,generator=generator)*rand(n,1,1,1)*.035).clamp(0,255/256)
 return torch.floor(x*256+.5).clamp(0,255)/256

def camera_augment(x,bb,n,cc):
 # Standard augment preserves targets; negatives cannot be replaced by mosaic.
 x,bb,n,cc=augment(x,bb,n,cc)
 b=len(x);device=x.device;apply=torch.rand(b,device=device)<.65
 sx=.48+torch.rand(b,device=device)*.48;sy=.65+torch.rand(b,device=device)*.35
 sx=torch.where(apply,sx,torch.ones_like(sx));sy=torch.where(apply,sy,torch.ones_like(sy))
 ox=(torch.rand(b,device=device)-.5)*(1-sx);oy=(torch.rand(b,device=device)-.5)*(1-sy)
 theta=torch.zeros(b,2,3,device=device);theta[:,0,0]=1/sx;theta[:,1,1]=1/sy
 theta[:,0,2]=-2*ox/sx;theta[:,1,2]=-2*oy/sy
 grid=F.affine_grid(theta,x.shape,align_corners=False);inside=(grid.abs()<=1).all(-1)[:,None]
 panel=F.grid_sample(x,grid,mode='bilinear',padding_mode='zeros',align_corners=False)
 x=torch.where(inside,panel,backgrounds(b,device))
 factors=torch.stack([sx,sy,sx,sy],1)[:,None]
 offsets=torch.stack([ox+(1-sx)/2,oy+(1-sy)/2,ox+(1-sx)/2,oy+(1-sy)/2],1)[:,None]
 bb=(bb*factors+offsets).clamp(0,1)
 # Exposure/blur/noise seen when a camera photographs another display.
 gain=.4+torch.rand(b,1,1,1,device=device)*1.0
 x=(x*gain).clamp(0,255/256).pow(.65+torch.rand(b,1,1,1,device=device)*.95)
 blurred=F.avg_pool2d(F.pad(x,(2,2,2,2),mode='replicate'),5,stride=1)
 x=torch.where(torch.rand(b,1,1,1,device=device)<.4,blurred,x)
 x=(x+torch.randn_like(x)*torch.rand(b,1,1,1,device=device)*.025).clamp(0,255/256)
 return torch.floor(x*256+.5).clamp(0,255)/256,bb,n,cc

def main(args):
 out=BASE/'runs'/args.name
 if out.exists():raise FileExistsError('Preserve previous run: '+str(out))
 out.mkdir(parents=True);torch.set_num_threads(4)
 seed=2026102101;random.seed(seed);np.random.seed(seed);torch.manual_seed(seed);torch.cuda.manual_seed_all(seed)
 torch.backends.cudnn.benchmark=True;torch.backends.cuda.matmul.allow_tf32=False;torch.backends.cudnn.allow_tf32=False
 protocol=json.loads((HOME/'protocol.json').read_text(encoding='utf8'));warm=BASE/'runs/wbcatt160_seed20261021/fp32_best.pt'
 ck=torch.load(warm,map_location='cuda',weights_only=False);model=Detector(.075,160,5,False).cuda();model.load_state_dict(ck['state'])
 d=np.load(BASE/'data/wbcatt160.npz');tx=torch.tensor(d['train_x'],device='cuda').permute(0,3,1,2).float()/256
 tb=torch.tensor(d['train_boxes'],device='cuda');tn=torch.tensor(d['train_n'],device='cuda');tc=torch.tensor(d['train_classes'],device='cuda')
 pp=torch.zeros(len(tx),device='cuda')
 for c in range(5):pp[tc[:,0]==c]=.8/5/(tc[:,0]==c).sum()
 pp[tn==0]=.2/(tn==0).sum();pool=torch.where(tn>0)[0]
 generator=torch.Generator(device='cuda').manual_seed(2026102191);vx=backgrounds(256,generator=generator)
 vdata={k:d[k] for k in ['val_n','val_boxes','val_classes']};history=[];start=time.monotonic();best_state=None
 protocol.update(warmstart_sha256=sha(warm),data_file='wbcatt160.npz',data_manifest_sha256=sha(BASE/'wbcatt/data_manifest.json'),
  seed=seed,name=args.name,fp32_epochs=args.epochs,qat_epochs=args.qat_epochs)
 save(out/'protocol.json',protocol)
 sources=[Path(__file__),HOME/'protocol.json',BASE/'model.py',BASE/'train.py',BASE/'five/train.py',BASE/'export.py',BASE/'five/calibrate.py',BASE/'wbcatt/evaluate.py']
 pins={p.relative_to(BASE.parent).as_posix():sha(p) for p in sources};save(out/'training_source_hashes.json',pins)
 for phase,epochs,lr in [('fp32',args.epochs,2e-4),('qat',args.qat_epochs,5e-5)]:
  if phase=='qat':model.load_state_dict(best_state);model.enable_qat()
  best=-1e9;opt=torch.optim.AdamW(model.parameters(),lr=lr,weight_decay=1e-4);sched=torch.optim.lr_scheduler.CosineAnnealingLR(opt,epochs)
  for ep in range(1,epochs+1):
   model.train();ids=torch.multinomial(pp,len(tx),True);total=0.
   for j in range(0,len(ids),64):
    ii=ids[j:j+64];a,b,n,c=tx[ii],tb[ii],tn[ii],tc[ii]
    # Mosaic is restricted to existing positive slots; negative rate stays fixed.
    pos=torch.where(n>0)[0]
    if len(pos):
     aa,bb,nn,cc=mosaic(a[pos],b[pos],n[pos],c[pos],tx,tb,tn,tc,pool)
     a=a.clone();b=b.clone();n=n.clone();c=c.clone();a[pos]=aa;b[pos]=bb;n[pos]=nn;c[pos]=cc
    a,b,n,c=camera_augment(a,b,n,c)
    synth=torch.rand(len(a),device='cuda')<.25
    a[synth]=backgrounds(int(synth.sum()));b[synth]=0;n[synth]=0;c[synth]=-1
    opt.zero_grad(set_to_none=True);ll=loss(model(a),b,n,160,c);ll.backward();torch.nn.utils.clip_grad_norm_(model.parameters(),10);opt.step();total+=float(ll.detach())*len(ii)
   sched.step()
   if ep==1 or ep%5==0 or ep==epochs:
    model.eval();logs=logits(model,d['val_x']);decoded=[decode_int(v,'fullframe',True) for v in logs]
    m,_,_,_=metrics(decoded,vdata,'val',52020)
    with torch.no_grad():ql=model(vx).permute(0,1,4,2,3).reshape(len(vx),30,10,10).cpu().numpy()
    ql=np.rint(ql*256).clip(-32768,32767).astype(np.int16)
    negfp=sum(bool((decode_int(v,'fullframe',True)[1]>=52020).any()) for v in ql)/len(ql)
    score=m['joint_macro_F1']-.6*negfp-.1*m['WBCAtt']['negative_image_FP_rate']
    if score>best:
     best=score;best_state=copy.deepcopy(model.state_dict());best_m=m;best_neg=negfp;best_ep=ep
     torch.save({'state':best_state,'phase':phase,'protocol':protocol,'validation':m,'procedural_VAL_FP_rate':negfp},out/(phase+'_best.pt'))
    row={'phase':phase,'epoch':ep,'loss':total/len(tx),'VAL_macro_F1':m['joint_macro_F1'],'VAL_correct_recall':m['joint_correct_recall'],'VAL_RBC_negative_FP':m['WBCAtt']['negative_image_FP_rate'],'procedural_VAL_FP':negfp,'objective':score,'best':best,'seconds':time.monotonic()-start}
    history.append(row);save(out/'history.json',history);print(json.dumps(row),flush=True)
  save(out/(phase+'_validation.json'),{'epoch':best_ep,'metrics':best_m,'procedural_VAL_FP_rate':best_neg})
 model.load_state_dict(best_state);torch.save({'state':best_state,'phase':'qat','protocol':protocol},out/'detector.pt')
 arrays={}
 for i,b in enumerate(model.blocks):
  w=b.conv.weight.detach().cpu().numpy();bi=b.conv.bias.detach().cpu().numpy();s=b.shift.cpu().numpy();factor=(b.ins/b.outs)*np.exp2(s)[:,None,None,None];limit=2**(b.bits-1)-1
  arrays[f'w{i}']=np.clip(np.floor(w*factor+.5),-limit,limit).astype(np.int8);qb=np.floor(bi/b.outs*np.exp2(s)+.5);assert abs(qb).max()<2**31
  arrays[f'b{i}']=qb.astype(np.int32);arrays[f's{i}']=s.astype(np.uint8)
 np.savez(out/'quantized.npz',**arrays)
 save(out/'frozen.json',{'checkpoint_sha256':sha(out/'detector.pt'),'quantized_sha256':sha(out/'quantized.npz'),'validation':best_m,'procedural_VAL_FP_rate':best_neg,'test_used_for_selection':False,'seconds':time.monotonic()-start})
 for p,want in pins.items():assert sha(BASE.parent/p)==want
 print('ROBUST_FROZEN',args.name,flush=True)

if __name__=='__main__':
 ap=argparse.ArgumentParser();ap.add_argument('--name',default='wbcatt_robust_20261021');ap.add_argument('--epochs',type=int,default=80);ap.add_argument('--qat-epochs',type=int,default=30);main(ap.parse_args())

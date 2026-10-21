"""Second two-source candidate: exposure-positive QAT and source-only camera VAL."""
import argparse,copy,json,random,sys,time
from pathlib import Path
import numpy as np
import torch
from torch.nn import functional as F
BASE=Path(__file__).resolve().parents[1];sys.path.insert(0,str(BASE))
from model import Detector,loss
from train import augment
from five.train import mosaic
from five.calibrate import logits
from export import decode_int
from robust.train import backgrounds
from wbc_bccd.train import sha,save,checkpoint,measure
from wbc_bccd.camera_augment import camera_augment
HOME=BASE/'wbc_bccd'
def main(args):
 run=BASE/'runs'/args.name
 if run.exists():raise FileExistsError(run)
 torch.set_num_threads(4);random.seed(args.seed);np.random.seed(args.seed);torch.manual_seed(args.seed);torch.cuda.manual_seed_all(args.seed)
 torch.backends.cudnn.benchmark=True;torch.backends.cuda.matmul.allow_tf32=False;torch.backends.cudnn.allow_tf32=False
 warm=BASE/'runs/wbc_bccd160_20261021/detector.pt';ck=torch.load(warm,weights_only=False,map_location='cuda');protocol=copy.deepcopy(ck['protocol'])
 protocol.update(name=args.name,seed=args.seed,fp32_epochs=0,qat_epochs=args.epochs,previous_stage={'model':'wbc_bccd160_20261021','FP32_epochs':120,'QAT_epochs':80},warmstart_sha256=sha(warm),
  camera_repair='Only WBCAtt+BCCD pixels. More underexposed positive cells and rectangular photographed-panel geometry; no screenshot pixel used for training; screenshots development-only and have influenced augmentation design.',
  augmentation='50% of acquired batches use camera_augment.py with gain0.43..1.15 and gamma0.80..1.45, per-channel variation, blur/noise, 40% dark-surround panels. Other 50% mild; mosaic typed positives only.',
  natural_replay='Extra16 typed natural WBCAtt images per batch, true-box/type loss weighted0.5; no teacher or pseudo label',
  checkpoint_selection='VAL only at0.70; prefer natural macroF1>=.88, BCCD recall>=.85 precision>=.75, proceduralFP<=.01 and cameraVAL jointF1>=.70; then 0.55 natural jointF1 +0.20 BCCD F1 +0.25 camera jointF1 -0.3 proceduralFP -0.1 acquired_negativeFP',
  final_threshold='Same declared grid0.40..0.95 step.025, VAL including fixed cameraVAL only; no TEST or screenshot threshold tuning',camera_VAL_seed=2026102181,
  procedural_VAL_seed=2026102182,procedural_check_seed=2026102183)
 run.mkdir(parents=True);save(run/'protocol.json',protocol);(run/'data_manifest.json').write_bytes((HOME/'data_manifest.json').read_bytes())
 files=[Path(__file__),HOME/'camera_augment.py',HOME/'train.py',HOME/'protocol.json',HOME/'prepare.py',BASE/'model.py',BASE/'train.py',BASE/'five/train.py',BASE/'five/calibrate.py',BASE/'export.py',BASE/'robust/train.py',BASE/'robust/balanced/train.py']
 pins={p.relative_to(BASE.parent).as_posix():sha(p) for p in files};save(run/'training_source_hashes.json',pins)
 d=np.load(BASE/'data/wbc_bccd160.npz');tx=torch.tensor(d['train_x'],device='cuda').permute(0,3,1,2).float()/256
 tb=torch.tensor(d['train_boxes'],device='cuda');tn=torch.tensor(d['train_n'],device='cuda');tc=torch.tensor(d['train_classes'],device='cuda');td=torch.tensor(d['train_domain'],device='cuda');pool=torch.where((td==1)&(tn>0))[0]
 pp=torch.zeros(len(tx),device='cuda')
 for c in range(5):mask=(td==1)&(tn>0)&(tc[:,0]==c);pp[mask]=.10/mask.sum()
 mask=(td==1)&(tn==0);pp[mask]=.10/mask.sum();pp[td==0]=.25/(td==0).sum();replay_p=pp.clone();replay_p[~((td==1)&(tn>0))]=0
 val={k:d[k] for k in d.files if k.startswith('val_')}
 with torch.random.fork_rng(devices=[0]):
  torch.manual_seed(protocol['camera_VAL_seed']);torch.cuda.manual_seed_all(protocol['camera_VAL_seed'])
  indices=[]
  for c in range(5):indices.extend(map(int,np.flatnonzero((val['val_domain']==1)&(val['val_classes'][:,0]==c))[:40]))
  indices.extend(map(int,np.flatnonzero((val['val_domain']==0)&(val['val_n']>0))))
  for dom in [0,1]:indices.extend(map(int,np.flatnonzero((val['val_domain']==dom)&(val['val_n']==0))[:64]))
  vx=torch.tensor(val['val_x'][indices],device='cuda').permute(0,3,1,2).float()/256
  vb=torch.tensor(val['val_boxes'][indices],device='cuda');vn=torch.tensor(val['val_n'][indices],device='cuda');vc=torch.tensor(val['val_classes'][indices],device='cuda')
  vx,vb,vn,vc=camera_augment(vx,vb,vn,vc)
  cam={'val_x':np.rint(vx.permute(0,2,3,1).cpu().numpy()*256).astype(np.uint8),'val_boxes':vb.cpu().numpy(),'val_n':vn.cpu().numpy(),'val_classes':vc.cpu().numpy(),'val_domain':val['val_domain'][indices]}
 np.savez(run/'camera_val.npz',**cam);save(run/'camera_val_manifest.json',{'source':'fixed augmentation of VAL only','source_indices':indices,'seed':protocol['camera_VAL_seed'],'sha256':sha(run/'camera_val.npz'),'screenshot_pixels_used':False})
 del vx,vb,vn,vc
 gen=torch.Generator(device='cuda').manual_seed(protocol['procedural_VAL_seed']);empty=backgrounds(256,generator=gen)
 model=Detector(.075,160,5,False).cuda();model.enable_qat();model.load_state_dict(ck['state']);opt=torch.optim.AdamW(model.parameters(),lr=1e-5,weight_decay=1e-4);sched=torch.optim.lr_scheduler.CosineAnnealingLR(opt,args.epochs)
 history=[];best=(-1,-1e9);start=time.monotonic()
 for ep in range(1,args.epochs+1):
  model.train();ids=torch.multinomial(pp,len(tx),True);total=0.
  for j in range(0,len(ids),64):
   ii=ids[j:j+64];a0,b0,n0,c0=tx[ii],tb[ii],tn[ii],tc[ii];pos=torch.where((td[ii]==1)&(n0>0))[0]
   if len(pos):
    aa,bb,nn,cc=mosaic(a0[pos],b0[pos],n0[pos],c0[pos],tx,tb,tn,tc,pool);a0=a0.clone();b0=b0.clone();n0=n0.clone();c0=c0.clone();a0[pos]=aa;b0[pos]=bb;n0[pos]=nn;c0[pos]=cc
   a,b,n,c=augment(a0,b0,n0,c0);photo=torch.where(torch.rand(len(a),device='cuda')<.5)[0]
   if len(photo):aa,bb,nn,cc=camera_augment(a0[photo],b0[photo],n0[photo],c0[photo]);a[photo]=aa;b[photo]=bb;n[photo]=nn;c[photo]=cc
   proc=torch.rand(len(a),device='cuda')<.15;a[proc]=backgrounds(int(proc.sum()));b[proc]=0;n[proc]=0;c[proc]=-1
   opt.zero_grad(set_to_none=True);raw=model(a);ll=loss(raw,b,n,160,c)
   if (n==0).any():ll=ll+.5*F.softplus(raw[n==0,...,4].flatten(1).topk(20,dim=1).values).mean()
   ri=torch.multinomial(replay_p,16,True);ll=ll+.5*loss(model(tx[ri]),tb[ri],tn[ri],160,tc[ri]);ll.backward();torch.nn.utils.clip_grad_norm_(model.parameters(),10);opt.step();total+=float(ll.detach())*len(ii)
  sched.step()
  if ep==1 or ep%5==0 or ep==args.epochs:
   model.eval();m,_=measure(logits(model,val['val_x']),val,45518);cm,_=measure(logits(model,cam['val_x']),cam,45518)
   with torch.no_grad():e=model(empty).permute(0,1,4,2,3).reshape(len(empty),30,10,10).cpu().numpy()
   e=np.rint(e*256).clip(-32768,32767).astype(np.int16);fp=sum((decode_int(v,'fullframe',True)[1]>=45518).any() for v in e)/len(e)
   objective=.55*m['joint_macro_F1']+.20*m['BCCD']['F1']+.25*cm['joint_macro_F1']-.3*fp-.1*m['acquired_negative_image_FP_rate']
   eligible=m['joint_macro_F1']>=.88 and m['BCCD']['recall']>=.85 and m['BCCD']['precision']>=.75 and fp<=.01 and cm['joint_macro_F1']>=.70;score=(int(eligible),float(objective))
   if score>best:
    best=score;state=copy.deepcopy(model.state_dict());best_m=m;best_cm=cm;best_fp=fp;best_ep=ep;checkpoint(run/'qat_best.pt',{'state':state,'protocol':protocol,'phase':'qat','epoch':ep,'validation':m,'camera_validation':cm})
   row={'phase':'qat','epoch':ep,'loss':total/len(tx),'WBCAtt_VAL_macro_F1':m['joint_macro_F1'],'BCCD_VAL_recall':m['BCCD']['recall'],'BCCD_VAL_precision':m['BCCD']['precision'],'BCCD_VAL_F1':m['BCCD']['F1'],'camera_VAL_macro_F1':cm['joint_macro_F1'],'procedural_VAL_FP':float(fp),'VAL_eligible':bool(eligible),'objective':float(objective),'best':best,'seconds':time.monotonic()-start};history.append(row);save(run/'history.json',history);print(json.dumps(row),flush=True)
 model.load_state_dict(state);checkpoint(run/'detector.pt',{'state':state,'protocol':protocol,'phase':'qat','validation':best_m,'camera_validation':best_cm});arrays={}
 for i,b in enumerate(model.blocks):
  w=b.conv.weight.detach().cpu().numpy();bi=b.conv.bias.detach().cpu().numpy();s=b.shift.cpu().numpy();factor=(b.ins/b.outs)*np.exp2(s)[:,None,None,None];lim=2**(b.bits-1)-1;arrays[f'w{i}']=np.clip(np.floor(w*factor+.5),-lim,lim).astype(np.int8);qb=np.floor(bi/b.outs*np.exp2(s)+.5);assert abs(qb).max()<2**31;arrays[f'b{i}']=qb.astype(np.int32);arrays[f's{i}']=s.astype(np.uint8)
 np.savez(run/'quantized.npz',**arrays);save(run/'qat_validation.json',{'epoch':best_ep,'metrics':best_m,'camera_validation':best_cm,'procedural_VAL_FP_rate':float(best_fp)});save(run/'fp32_validation.json',{'previous_stage_only':True,'run':'wbc_bccd160_20261021'})
 save(run/'frozen.json',{'checkpoint_sha256':sha(run/'detector.pt'),'quantized_sha256':sha(run/'quantized.npz'),'validation':best_m,'camera_validation':best_cm,'procedural_VAL_FP_rate':float(best_fp),'TEST_used_for_selection':False,'seconds':time.monotonic()-start})
 for n,w in pins.items():assert sha(BASE.parent/n)==w,n
 print('TWO_SOURCE_CAMERA_TRAINING_FROZEN',args.name,flush=True)
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--name',default='wbc_bccd160_camera_20261021');p.add_argument('--epochs',type=int,default=60);p.add_argument('--seed',type=int,default=2026102180);main(p.parse_args())

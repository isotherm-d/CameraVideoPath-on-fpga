"""Calibrate only the three objectness filters; preserve geometry and type weights."""
import argparse,copy,json,random,sys,time
from pathlib import Path
import numpy as np
import torch
from torch.nn import functional as F
BASE=Path(__file__).resolve().parents[1];sys.path.insert(0,str(BASE))
from model import Detector,ANCHORS
from train import augment
from five.train import mosaic
from five.calibrate import logits
from five import calibrate
from wbc_bccd.object_reference import predict,decode_int
calibrate.predict=predict
from wbc_bccd.train import sha,save,checkpoint,measure
from wbc_bccd.camera_augment import camera_augment
from robust.train import backgrounds
HOME=BASE/'wbc_bccd'
def obj_loss(raw,gt,n):
 valid=torch.arange(gt.shape[1],device=gt.device)[None]<n[:,None];ids=torch.arange(len(raw),device=gt.device)[:,None].expand_as(valid)[valid];g=gt[valid]
 wh=(g[:,2:]-g[:,:2])*160;anc=torch.tensor(ANCHORS,device=gt.device);inter=torch.minimum(wh[:,None],anc[None]).prod(-1);ai=(inter/(wh.prod(-1)[:,None]+anc.prod(-1)[None]-inter).clamp_min(1e-6)).argmax(1);center=(g[:,:2]+g[:,2:])/2;gx=(center[:,0]*10).long().clamp(0,9);gy=(center[:,1]*10).long().clamp(0,9)
 obj=torch.zeros_like(raw[...,4]);obj[ids,ai,gy,gx]=1;z=raw[...,4];neg=F.binary_cross_entropy_with_logits(z[obj==0],obj[obj==0]);pos=F.softplus(-z[obj==1]).mean() if len(g) else z.sum()*0
 hard=F.softplus(z[n==0].flatten(1).topk(20,dim=1).values).mean() if (n==0).any() else z.sum()*0
 return 2*pos+.5*neg+hard
def main(args):
 run=BASE/'runs'/args.name
 if run.exists():raise FileExistsError(run)
 torch.set_num_threads(4);random.seed(args.seed);np.random.seed(args.seed);torch.manual_seed(args.seed);torch.cuda.manual_seed_all(args.seed);torch.backends.cudnn.benchmark=True;torch.backends.cuda.matmul.allow_tf32=False;torch.backends.cudnn.allow_tf32=False
 prior=BASE/'runs/wbc_bccd160_camera_20261021';warm=prior/'detector.pt';ck=torch.load(warm,weights_only=False,map_location='cuda');protocol=copy.deepcopy(ck['protocol'])
 protocol.update(name=args.name,seed=args.seed,fp32_epochs=0,qat_epochs=args.epochs,warmstart_sha256=sha(warm),training_stages=[{'run':'wbc_bccd160_20261021','FP32':120,'QAT':80},{'run':prior.name,'QAT':60},{'run':args.name,'objectness_only_QAT':args.epochs}],
  frozen_parameters='All first9 layers, final-head bbox filters and all five class filters remain byte-identical; train only head channels4,14,24, weights and bias; no weight decay',
  detection_score='sigmoid_LUT(objectness)*255; five-type argmax independent',sampling_probabilities={'WBCAtt_positive':.40,'WBCAtt_negative':.10,'BCCD':.20,'procedural_empty':.30},
  negative_loss='2*mean positive objectness BCE +0.5*mean negative BCE +1.0*top20 BCE on empty images',
  checkpoint_selection='VAL only at objectness0.85; same gate-aware 0.55 natural jointF1+0.20 BCCD localizationF1+0.25 fixed cameraVAL jointF1-0.3 proceduralVAL_FP-0.1 acquired_negative_FP',procedural_check_seed=2026102183,extra_procedural_check_seed=2026102185)
 run.mkdir(parents=True);save(run/'protocol.json',protocol)
 for n in ['data_manifest.json','camera_val.npz','camera_val_manifest.json']:(run/n).write_bytes((prior/n).read_bytes())
 files=[Path(__file__),HOME/'camera_augment.py',HOME/'object_reference.py',HOME/'train.py',BASE/'model.py',BASE/'train.py',BASE/'five/train.py',BASE/'five/calibrate.py',BASE/'export.py',BASE/'robust/train.py',BASE/'robust/balanced/train.py'];pins={p.relative_to(BASE.parent).as_posix():sha(p) for p in files};save(run/'training_source_hashes.json',pins)
 manifest=json.loads((run/'data_manifest.json').read_text(encoding='utf8'));assert sha(BASE/'data/wbc_bccd160.npz')==manifest['npz_sha256']
 d=np.load(BASE/'data/wbc_bccd160.npz');tx=torch.tensor(d['train_x'],device='cuda').permute(0,3,1,2).float()/256;tb=torch.tensor(d['train_boxes'],device='cuda');tn=torch.tensor(d['train_n'],device='cuda');tc=torch.tensor(d['train_classes'],device='cuda');td=torch.tensor(d['train_domain'],device='cuda');pool=torch.where((td==1)&(tn>0))[0]
 pp=torch.zeros(len(tx),device='cuda')
 for c in range(5):mask=(td==1)&(tn>0)&(tc[:,0]==c);pp[mask]=.08/mask.sum()
 mask=(td==1)&(tn==0);pp[mask]=.10/mask.sum();pp[td==0]=.20/(td==0).sum();replay_p=pp.clone();replay_p[~((td==1)&(tn>0))]=0
 val={k:d[k] for k in d.files if k.startswith('val_')};cf=np.load(run/'camera_val.npz');cam={k:cf[k] for k in cf.files};gen=torch.Generator(device='cuda').manual_seed(protocol['procedural_VAL_seed']);empty=backgrounds(256,generator=gen)
 model=Detector(.075,160,5,False).cuda();model.enable_qat();model.load_state_dict(ck['state'])
 for p in model.parameters():p.requires_grad_(False)
 head=model.blocks[9].conv;head.weight.requires_grad_(True);head.bias.requires_grad_(True);mask=torch.zeros_like(head.bias);mask[[4,14,24]]=1
 head.weight.register_hook(lambda g:g*mask[:,None,None,None]);head.bias.register_hook(lambda g:g*mask)
 opt=torch.optim.AdamW([head.weight,head.bias],lr=3e-5,weight_decay=0);sched=torch.optim.lr_scheduler.CosineAnnealingLR(opt,args.epochs);history=[];best=(-1,-1e9);start=time.monotonic()
 for ep in range(1,args.epochs+1):
  model.train();ids=torch.multinomial(pp,len(tx),True);total=0.
  for j in range(0,len(ids),64):
   ii=ids[j:j+64];a0,b0,n0,c0=tx[ii],tb[ii],tn[ii],tc[ii];pos=torch.where((td[ii]==1)&(n0>0))[0]
   if len(pos):
    aa,bb,nn,cc=mosaic(a0[pos],b0[pos],n0[pos],c0[pos],tx,tb,tn,tc,pool);a0=a0.clone();b0=b0.clone();n0=n0.clone();c0=c0.clone();a0[pos]=aa;b0[pos]=bb;n0[pos]=nn;c0[pos]=cc
   a,b,n,c=augment(a0,b0,n0,c0);photo=torch.where(torch.rand(len(a),device='cuda')<.5)[0]
   if len(photo):aa,bb,nn,cc=camera_augment(a0[photo],b0[photo],n0[photo],c0[photo]);a[photo]=aa;b[photo]=bb;n[photo]=nn;c[photo]=cc
   proc=torch.rand(len(a),device='cuda')<.30;a[proc]=backgrounds(int(proc.sum()));b[proc]=0;n[proc]=0;c[proc]=-1
   opt.zero_grad(set_to_none=True);ll=obj_loss(model(a),b,n);ri=torch.multinomial(replay_p,16,True);ll=ll+.5*obj_loss(model(tx[ri]),tb[ri],tn[ri]);ll.backward();torch.nn.utils.clip_grad_norm_([head.weight,head.bias],10);opt.step();total+=float(ll.detach())*len(ii)
  sched.step()
  if ep==1 or ep%5==0 or ep==args.epochs:
   model.eval();m,_=measure(logits(model,val['val_x']),val,55271);cm,_=measure(logits(model,cam['val_x']),cam,55271)
   with torch.no_grad():e=model(empty).permute(0,1,4,2,3).reshape(len(empty),30,10,10).cpu().numpy()
   e=np.rint(e*256).clip(-32768,32767).astype(np.int16);fp=sum(len(predict(v,55271)[0])>0 for v in e)/len(e);objective=.55*m['joint_macro_F1']+.2*m['BCCD']['F1']+.25*cm['joint_macro_F1']-.3*fp-.1*m['acquired_negative_image_FP_rate'];eligible=m['joint_macro_F1']>=.88 and m['BCCD']['recall']>=.85 and m['BCCD']['precision']>=.75 and fp<=.01 and cm['joint_macro_F1']>=.7;score=(int(eligible),float(objective))
   if score>best:best=score;state=copy.deepcopy(model.state_dict());best_m=m;best_cm=cm;best_fp=fp;best_ep=ep;checkpoint(run/'qat_best.pt',{'state':state,'protocol':protocol,'phase':'qat','epoch':ep,'validation':m,'camera_validation':cm})
   row={'phase':'qat','epoch':ep,'loss':total/len(tx),'WBCAtt_VAL_macro_F1':m['joint_macro_F1'],'BCCD_VAL_recall':m['BCCD']['recall'],'BCCD_VAL_precision':m['BCCD']['precision'],'BCCD_VAL_F1':m['BCCD']['F1'],'camera_VAL_macro_F1':cm['joint_macro_F1'],'procedural_VAL_FP':float(fp),'VAL_eligible':bool(eligible),'objective':float(objective),'best':best,'seconds':time.monotonic()-start};history.append(row);save(run/'history.json',history);print(json.dumps(row),flush=True)
 model.load_state_dict(state)
 for key,value in ck['state'].items():
  if key in ['blocks.9.conv.weight','blocks.9.conv.bias']:assert torch.equal(value[mask==0],state[key][mask==0]),key
  else:assert torch.equal(value,state[key]),key
 checkpoint(run/'detector.pt',{'state':state,'protocol':protocol,'phase':'qat','validation':best_m,'camera_validation':best_cm});arrays={}
 for i,b in enumerate(model.blocks):
  w=b.conv.weight.detach().cpu().numpy();bi=b.conv.bias.detach().cpu().numpy();s=b.shift.cpu().numpy();factor=(b.ins/b.outs)*np.exp2(s)[:,None,None,None];lim=2**(b.bits-1)-1;arrays[f'w{i}']=np.clip(np.floor(w*factor+.5),-lim,lim).astype(np.int8);qb=np.floor(bi/b.outs*np.exp2(s)+.5);assert abs(qb).max()<2**31;arrays[f'b{i}']=qb.astype(np.int32);arrays[f's{i}']=s.astype(np.uint8)
 np.savez(run/'quantized.npz',**arrays);save(run/'qat_validation.json',{'epoch':best_ep,'metrics':best_m,'camera_validation':best_cm,'procedural_VAL_FP_rate':float(best_fp)});save(run/'fp32_validation.json',{'previous_stages':protocol['training_stages']});save(run/'frozen.json',{'checkpoint_sha256':sha(run/'detector.pt'),'quantized_sha256':sha(run/'quantized.npz'),'validation':best_m,'camera_validation':best_cm,'procedural_VAL_FP_rate':float(best_fp),'geometry_and_type_parameters_unchanged':True,'TEST_used_for_selection':False,'seconds':time.monotonic()-start})
 for n,w in pins.items():assert sha(BASE.parent/n)==w,n
 print('TWO_SOURCE_OBJECTNESS_TRAINING_FROZEN',args.name,flush=True)
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--name',default='wbc_bccd160_object_20261021');p.add_argument('--epochs',type=int,default=40);p.add_argument('--seed',type=int,default=2026102184);main(p.parse_args())

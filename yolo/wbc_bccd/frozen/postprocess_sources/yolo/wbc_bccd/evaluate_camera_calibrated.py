"""Freeze a VAL-only confidence choice, assess regression, then gated RTL export."""
import argparse,hashlib,json,sys,shutil
from pathlib import Path
from types import SimpleNamespace
import numpy as np
import torch
from PIL import Image
BASE=Path(__file__).resolve().parents[1];sys.path.insert(0,str(BASE))
from model import Detector
from export import integer,writehex
from wbc_bccd.object_reference import decode_int,predict
from five import calibrate as scoring
scoring.predict=predict
import export as exporter
from five.calibrate import logits
from wbc_bccd.train import measure
from robust.train import backgrounds
from train import iou
HOME=BASE/'wbc_bccd';HDL=BASE.parent/'08_csi_dsi_cs500_7cun/user_source/hdl_source/yolo'
NAMES=['Basophil','Eosinophil','Lymphocyte','Monocyte','Neutrophil']
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def save(p,v):p.write_text(json.dumps(v,indent=2),encoding='utf8')
def read(p):return json.loads(p.read_text(encoding='utf8'))
def screenshot(p):
 a=np.asarray(Image.open(p).convert('RGB'))[35:755,4:1284];assert a.shape==(720,1280,3)
 return a[(2+4*np.arange(160)+np.arange(160)//2)[:,None],(4+8*np.arange(160))[None,:]]
def synthetic(model,count,seed):
 gen=torch.Generator(device='cuda').manual_seed(seed)
 with torch.no_grad():x=backgrounds(count,generator=gen).permute(0,2,3,1).cpu().numpy()
 return np.asarray(logits(model,np.rint(x*256).astype(np.uint8)))
def single_static(logs,data,th):
 correct=total=0
 for i in np.flatnonzero((data['val_domain']==1)&(data['val_n']>0)):
  assert data['val_n'][i]==1;total+=1;bb,s,c=predict(logs[i],th)
  if len(bb):
   k=int(np.argmin(abs((bb[:,0]+bb[:,2])//2-640)+abs((bb[:,1]+bb[:,3])//2-360)))
   correct+=int(c[k]==data['val_classes'][i,0] and iou(data['val_boxes'][i,0],bb/np.array([1280,720,1280,720]))[k]>=.5)
 return {'correct':correct,'objects':total,'correct_recall':correct/max(total,1),'selection':'Static new identity: nearest center; does not simulate temporal tracking'}
def main(args):
 run=BASE/'runs'/args.name;f=read(run/'frozen.json');protocol=read(run/'protocol.json')
 assert sha(run/'detector.pt')==f['checkpoint_sha256'] and sha(run/'quantized.npz')==f['quantized_sha256']
 post=read(run/'postprocess_protocol.json');assert post['checkpoint_sha256']==f['checkpoint_sha256'] and post['quantized_sha256']==f['quantized_sha256']
 for n,w in post['source_hashes'].items():assert sha(BASE.parent/n)==w,n
 if (run/'acceptance.json').exists():raise FileExistsError('Candidate evaluation already frozen')
 for n,w in read(run/'training_source_hashes.json').items():assert sha(BASE.parent/n)==w,n
 torch.set_num_threads(4);torch.backends.cuda.matmul.allow_tf32=False;torch.backends.cudnn.allow_tf32=False
 ck=torch.load(run/'detector.pt',weights_only=False,map_location='cuda');model=Detector(.075,160,5,False).cuda();model.enable_qat();model.load_state_dict(ck['state']);model.eval()
 assert sha(BASE/'data/wbc_bccd160.npz')==read(run/'data_manifest.json')['npz_sha256']
 d=np.load(BASE/'data/wbc_bccd160.npz');q=np.load(run/'quantized.npz')
 # Load once: NpzFile does not cache arrays across [] operations.
 data={k:d[k] for k in d.files if k.startswith('val_')};logs=np.asarray(logits(model,data['val_x']));np.savez(run/'val_logits.npz',logits=logs)
 nlogs=synthetic(model,256,protocol['procedural_VAL_seed'])
 # The two provided screenshots are explicitly DEVELOPMENT calibration data.
 devbase=Path('C:/Users/cqm87/AppData/Local/Temp');devroom=screenshot(devbase/'codex-clipboard-a2250e09-512f-45eb-ae0c-faf47340da82.png');devcell=screenshot(devbase/'codex-clipboard-d8d930c9-e2b8-487f-8b84-5de8743f4d8c.png')
 roomlog=integer(devroom,q)[0];celllog=integer(devcell,q)[0];devroi=np.array([540,210,830,525])
 ux=[np.full((160,160,3),v,np.uint8) for v in [0,16,32,64,96,128,192,255]]+[np.broadcast_to(np.array(c,np.uint8),(160,160,3)).copy() for c in [[255,0,0],[0,255,0],[0,0,255],[48,40,56]]];ulogs=[integer(x,q)[0] for x in ux]
 camera_data=None;camera_logs=None
 if (run/'camera_val.npz').exists():
  assert sha(run/'camera_val.npz')==read(run/'camera_val_manifest.json')['sha256']
  cf=np.load(run/'camera_val.npz');camera_data={k:cf[k] for k in cf.files};camera_logs=np.asarray(logits(model,camera_data['val_x']))
 choices=[]
 for step in range(23):
  threshold=.4+.025*step;score_q16=round(threshold*65025);m,_=measure(logs,data,score_q16)
  fp=sum(len(predict(v,score_q16)[0])>0 for v in nlogs)/len(nlogs)
  objective=.7*m['joint_macro_F1']+.3*m['BCCD']['F1']-.3*fp-.1*m['acquired_negative_image_FP_rate']
  cell_boxes=predict(celllog,score_q16)[0];devhit=bool(len(cell_boxes) and iou(devroi,cell_boxes).max(initial=0)>=.5);devempty=len(predict(roomlog,score_q16)[0])==0;uniformempty=all(len(predict(v,score_q16)[0])==0 for v in ulogs)
  feasible=m['joint_macro_F1']>=.88 and m['BCCD']['recall']>=.85 and m['BCCD']['precision']>=.75 and fp<=.02 and devhit and devempty and uniformempty
  cm=None
  if camera_data is not None:
   cm,_=measure(camera_logs,camera_data,score_q16);objective=.55*m['joint_macro_F1']+.20*m['BCCD']['F1']+.25*cm['joint_macro_F1']-.3*fp-.1*m['acquired_negative_image_FP_rate'];feasible=feasible and cm['joint_macro_F1']>=.70
  choices.append({'threshold':threshold,'score_q16':score_q16,'metrics':m,'camera_metrics':cm,'procedural_VAL_FP_rate':fp,'development_cell_IoU50':devhit,'development_room_empty':devempty,'uniform_empty':uniformempty,'objective':objective,'VAL_feasible':feasible})
 eligible=[v for v in choices if v['VAL_feasible']];best=max(eligible or choices,key=lambda v:(v['objective'],v['score_q16']));th=best['score_q16'];val=best['metrics']
 val['static_single_cell']=single_static(logs,data,th)
 save(run/'integer_validation.json',{'selection':'Public/fixed-augmented VAL and provided DEVELOPMENT screenshots; weight fixed, TEST not used; 256-image procedural VAL screening<=2%, both larger1024-image final regressions still<=1%','selected':best,'choices':choices,'TEST_used_for_selection':False,'screenshots_used_for_development_calibration':True})
 # Freeze threshold before looking at these checks or the reused TEST regression.
 final=synthetic(model,1024,protocol['procedural_check_seed']);negative_fp=sum(len(predict(v,th)[0])>0 for v in final)
 extra_final=None
 if 'extra_procedural_check_seed' in protocol:
  extra=synthetic(model,1024,protocol['extra_procedural_check_seed']);extra_fp=sum(len(predict(v,th)[0])>0 for v in extra);extra_final={'seed':protocol['extra_procedural_check_seed'],'images':1024,'false_positive_images':extra_fp,'FP_rate':extra_fp/1024,'artificial_stress_only':True}
 probe_images=[(f'uniform_{v}',np.full((160,160,3),v,np.uint8)) for v in [0,16,32,64,96,128,192,255]]
 probe_images += [('uniform_rgb_'+str(c),np.broadcast_to(np.array(c,np.uint8),(160,160,3)).copy()) for c in [[255,0,0],[0,255,0],[0,0,255],[48,40,56]]]
 probes=[]
 for name,x in probe_images:
  log,_=integer(x,q);bb,s,c=predict(log,th);probes.append({'name':name,'boxes':bb.tolist(),'scores':s.tolist(),'classes':c.tolist()})
 development={}
 for name,file in {'user_empty_scene':'codex-clipboard-a2250e09-512f-45eb-ae0c-faf47340da82.png','historical_cell_unknown_true_class':'codex-clipboard-d8d930c9-e2b8-487f-8b84-5de8743f4d8c.png'}.items():
  p=Path('C:/Users/cqm87/AppData/Local/Temp')/file;x=screenshot(p);log,_=integer(x,q);bb,s,c=predict(log,th)
  development[name]={'screenshot_sha256':sha(p),'boxes':bb.tolist(),'scores':s.tolist(),'classes':c.tolist(),'limitation':'Contains OSD; approximate replay, no clean raw stream or independent class label'}
  np.savez(run/(name+'_probe.npz'),rgb=x,logits=log)
 cell=np.array(development['historical_cell_unknown_true_class']['boxes'],dtype=int).reshape(-1,4)
 hit=any(540<=(b[0]+b[2])/2<=830 and 210<=(b[1]+b[3])/2<=525 and (b[2]-b[0])<600 and (b[3]-b[1])<550 for b in cell)
 checks={'VAL_choice_meets_declared_gates':bool(eligible),'VAL_macro_F1_at_least_088':val['joint_macro_F1']>=.88,
  'BCCD_VAL_recall_at_least_085':val['BCCD']['recall']>=.85,'BCCD_VAL_precision_at_least_075':val['BCCD']['precision']>=.75,
  'all_uniform_probes_no_boxes':all(not p['boxes'] for p in probes),'procedural_final_FP_at_most_001':negative_fp/1024<=.01,
  'user_empty_scene_no_boxes':not development['user_empty_scene']['boxes'],'historical_cell_localization_development_sanity':hit}
 if camera_data is not None:checks['source_only_camera_VAL_macroF1_at_least_070']=best['camera_metrics']['joint_macro_F1']>=.70
 if extra_final is not None:checks['extra_procedural_FP_at_most_001']=extra_final['FP_rate']<=.01
 result={'model':args.name,'checkpoint_sha256':sha(run/'detector.pt'),'quantized_sha256':sha(run/'quantized.npz'),'threshold_q16':th,'validation':val,
  'procedural_final':{'seed':protocol['procedural_check_seed'],'images':1024,'false_positive_images':negative_fp,'FP_rate':negative_fp/1024,'not_independent_camera_data':True},
  'uniform_probes':probes,'development_screenshots':development,'postprocess':post,'camera_augmented_VAL':best['camera_metrics'],'extra_procedural_final':extra_final,'checks':checks,'gate_passed':all(checks.values()),'threshold_uses_provided_development_frames':True,'development_is_not_independent_camera_validation':True,'camera_accuracy_validated':False,'new_TEST_claim':False}
 save(run/'acceptance.json',result);print('TWO_SOURCE_ACCEPTANCE',json.dumps(result),flush=True)
 if not result['gate_passed']:return
 # Reused public TEST regression, after the weight and threshold decisions.
 test={k:d[k] for k in d.files if k.startswith('test_')};tl=np.asarray(logits(model,test['test_x']))
 testm,testrows=measure(tl,{k.replace('test_','val_',1):v for k,v in test.items()},th)
 testm['static_single_cell']=single_static(tl,{k.replace('test_','val_',1):v for k,v in test.items()},th)
 save(run/'test_regression.json',{'metrics':testm,'threshold_q16':th,'weights_sha256':sha(run/'quantized.npz'),'reused_TEST_not_new_untouched':True,'used_for_selection':False})
 np.savez(run/'test_logits.npz',logits=tl)
 # Fourteen full layer-by-layer replays: ten typed, two BCCD scenes, two empty.
 indices=[]
 for c in range(5):
  good=[int(i) for i in np.flatnonzero((data['val_domain']==1)&(data['val_classes'][:,0]==c)) if c in predict(logs[i],th)[2]];assert len(good)>=2
  indices+=good[:2]
 good=[int(i) for i in np.flatnonzero((data['val_domain']==0)&(data['val_n']>0)) if len(predict(logs[i],th)[0])>0];assert len(good)>=2;indices+=good[:2]
 indices+=list(map(int,np.flatnonzero(data['val_n']==0)[:2]));assert len(indices)==len(set(indices))==14
 for i in indices:assert np.array_equal(integer(data['val_x'][i],q)[0],logs[i]),i
 target=run/'rtl_assets';exporter.main(SimpleNamespace(name=args.name,hdl=target,vector_indices=indices))
 (target/'yolo160_threshold.vh').write_text(f'`define YOLO_SCORE_THRESHOLD {th}\n`define YOLO_NMS_Q8 103\n`define YOLO_OBJECTNESS_ONLY 1\n',encoding='ascii')
 for j,i in enumerate(indices):
  folder=run/f'vectors/v{j}';bb,s,c=predict(logs[i],th);words=[sum(int(z)<<(12*(3-k)) for k,z in enumerate(b)) for b in bb]+[0xffffffffffff]*(5-len(bb))
  writehex(folder/'expected_boxes.hex',[sum(z<<(48*k) for k,z in enumerate(words))],60)
  writehex(folder/'expected_classes.hex',[sum(int(z)<<(3*k) for k,z in enumerate(c.tolist()+[5]*(5-len(c))))],4)
  writehex(folder/'expected_scores.hex',[sum(int(z)<<(16*k) for k,z in enumerate(s.tolist()+[0]*(5-len(s))))],20)
  save(folder/'expected_boxes.json',{'boxes_global720p':bb.tolist(),'classes':c.tolist(),'scores':s.tolist()})
 active=read(target/'model/active_model.json');active.update(threshold_q16=th,checkpoint_sha256=sha(run/'detector.pt'),accuracy_gate_report='yolo/runs/'+args.name+'/acceptance.json',
  postprocess={'detection_score':'objectness*255','class_selection':'argmax of five class logits; same neural network','protocol':'postprocess_protocol.json'},runtime={'video_fps_configured':30,'inference_interval_frames':2,'YOLO_Hz':15,'held_missed_detections':2,'display_atomic_snapshot':True,'max_display_cells':1,'full_English_names':NAMES,'selection_policy':'keep identity; otherwise nearest center'})
 active['assets']={p.relative_to(target).as_posix():sha(p) for p in [*(target/'model').glob('*'),*target.glob('*.vh')] if p.is_file() and p.name!='active_model.json'};save(target/'model/active_model.json',active)
 if args.activate:
  for p in target.rglob('*'):
   if p.is_file():dest=HDL/p.relative_to(target);dest.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(p,dest)
 print('TWO_SOURCE_EXPORTED',args.name,'active' if args.activate else 'isolated',flush=True)
if __name__=='__main__':
 ap=argparse.ArgumentParser();ap.add_argument('--name',default='wbc_bccd160_devcam_20261021');ap.add_argument('--activate',action='store_true');main(ap.parse_args())

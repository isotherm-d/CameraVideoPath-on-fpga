"""Additional exact RTL replays of development screenshots and uniform inputs."""
import argparse,hashlib,json,shutil,subprocess,sys
from pathlib import Path
import numpy as np
BASE=Path(__file__).resolve().parents[1];sys.path.insert(0,str(BASE))
from export import integer,writehex
from wbc_bccd.object_reference import predict
def save(p,v):p.write_text(json.dumps(v,indent=2),encoding='utf8')
def main(name):
 run=BASE/'runs'/name;alias=name+'_development_probes';out=BASE/'runs'/alias
 if out.exists():raise FileExistsError(out)
 q=np.load(run/'quantized.npz');accept=json.loads((run/('board_trial_acceptance.json' if (run/'board_trial_acceptance.json').exists() else 'acceptance.json')).read_text(encoding='utf8'));assert accept['gate_passed'];th=accept['threshold_q16']
 images=[('black',np.zeros((160,160,3),np.uint8)),('gray',np.full((160,160,3),128,np.uint8)),('white',np.full((160,160,3),255,np.uint8))]
 images += [(n,np.load(run/(n+'_probe.npz'))['rgb']) for n in ['user_empty_scene','historical_cell_unknown_true_class']]
 for j,(n,x) in enumerate(images):
  folder=out/f'vectors/v{j}';folder.mkdir(parents=True);log,fs=integer(x,q,True);bb,s,c=predict(log,th)
  if j<4:assert len(bb)==0,n
  writehex(folder/'rgb.hex',(int(p[0])<<16|int(p[1])<<8|int(p[2]) for p in x.reshape(-1,3)),6)
  for i,a in enumerate(fs):
   if i<9:
    chw=a.transpose(1,2,0);padded=np.pad(chw,((0,0),(0,0),(0,(-chw.shape[2])%8))).reshape(-1,8)
    writehex(folder/f'layer{i}.hex',(sum(int(v)<<(4*k) for k,v in enumerate(row)) for row in padded),8)
   else:writehex(folder/'logits.hex',(int(z)&65535 for z in a.transpose(1,2,0).ravel()),4)
  words=[sum(int(z)<<(12*(3-k)) for k,z in enumerate(b)) for b in bb]+[0xffffffffffff]*(5-len(bb))
  writehex(folder/'expected_boxes.hex',[sum(z<<(48*k) for k,z in enumerate(words))],60)
  writehex(folder/'expected_classes.hex',[sum(int(z)<<(3*k) for k,z in enumerate(c.tolist()+[5]*(5-len(c))))],4)
  writehex(folder/'expected_scores.hex',[sum(int(z)<<(16*k) for k,z in enumerate(s.tolist()+[0]*(5-len(s))))],20)
  save(folder/'expected_boxes.json',{'probe':n,'boxes_global720p':bb.tolist(),'classes':c.tolist(),'scores':s.tolist()})
 save(out/'vectors/manifest.json',{'vectors':len(images),'model_weights':name,'purpose':'Development probes, not independent camera accuracy data'})
 subprocess.run([sys.executable,str(BASE/'wbc_bccd/run_all_vectors.py'),'--name',alias],cwd=BASE.parent,check=True)
 dest=BASE.parent/'08_csi_dsi_cs500_7cun/reports/yolo_wbc_bccd15/development_probes';dest.mkdir(parents=True)
 for j,(n,x) in enumerate(images):
  src=BASE/f'tmp/five_v{j}';r=json.loads((src/'results.json').read_text(encoding='utf8'));assert r['model']==alias and r['status']=='PASS'
  target=dest/f'v{j}_{n}';target.mkdir()
  for p in [src/'results.json',*src.glob('*.log'),out/f'vectors/v{j}/expected_boxes.json']:shutil.copy2(p,target/p.name)
 save(dest/'summary.json',{'model':name,'alias':alias,'probes':len(images),'exact_10_layer_RTL_replay_pass':True,'camera_accuracy_validated':False})
 print('TWO_SOURCE_DEVELOPMENT_RTL_PROBES_PASS',flush=True)
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--name',default='wbc_bccd160_20261021');main(p.parse_args().name)

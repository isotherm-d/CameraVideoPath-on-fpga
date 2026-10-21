"""Activate an accepted, isolated model after confirming the saved current state."""
import argparse,hashlib,json,shutil,datetime
from pathlib import Path
BASE=Path(__file__).resolve().parents[1];BOARD=BASE.parent/'08_csi_dsi_cs500_7cun';HOME=BASE/'wbc_bccd';HDL=BOARD/'user_source/hdl_source/yolo'
def read(p):return json.loads(p.read_text(encoding='utf8'))
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main(name):
 run=BASE/'runs'/name;accept=read(run/('board_trial_acceptance.json' if (run/'board_trial_acceptance.json').exists() else 'acceptance.json'));assert accept['gate_passed'] and all(accept['checks'].values())
 baseline=read(HOME/'baseline/manifest.json');assert sha(BOARD/'td_project/camera_to_dsi_display.al')==baseline['project_sha256'],'Project changed since baseline'
 for n,w in baseline['backup_files'].items():assert sha(BASE.parent/n)==w,'Baseline changed before activation: '+n
 for n,w in read(run/'training_source_hashes.json').items():assert sha(BASE.parent/n)==w,n
 target=run/'rtl_assets';active=read(target/'model/active_model.json');assert active['run']==name
 assert sha(run/'quantized.npz')==accept['quantized_sha256']==active['quantized_sha256']
 assert sha(run/'detector.pt')==accept['checkpoint_sha256']==active['checkpoint_sha256']
 for n,w in active['assets'].items():assert sha(target/n)==w,n
 changes=[]
 for p in target.rglob('*'):
  if p.is_file():changes.append((p,HDL/p.relative_to(target)))
 # Publish the descriptor last; no runtime programming occurs here.
 changes.sort(key=lambda z:z[0].name=='active_model.json')
 for p,dest in changes:dest.parent.mkdir(exist_ok=True,parents=True);shutil.copy2(p,dest);assert sha(p)==sha(dest)
 (HOME/'activation.json').write_text(json.dumps({'recorded_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'model':name,'accepted':True,'files':[str(d.relative_to(BOARD)) for p,d in changes],'prior_bit_preserved':True,'board_programmed':False},indent=2),encoding='utf8')
 print('TWO_SOURCE_SOURCE_ACTIVATED_NO_PROGRAMMING',name,flush=True)
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--name',default='wbc_bccd160_20261021');main(p.parse_args().name)

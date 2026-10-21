"""Preserve the working SRAM bit and current source before activating new ROMs."""
import datetime,hashlib,json,shutil,subprocess
from pathlib import Path
BASE=Path(__file__).resolve().parents[1];REPO=BASE.parent;BOARD=REPO/'hardware/mainboard';OUT=BASE/'wbc_bccd/baseline';HDL=BOARD/'user_source/hdl_source/yolo'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def read(p):return json.loads(p.read_text(encoding='utf8'))
if __name__=='__main__':
 if OUT.exists():raise FileExistsError('Baseline already captured; keep it immutable')
 state=read(BOARD/'deployment_state.json');assert state['model']=='five_fullframe_seed0' and state['program_sram_success']
 bit=Path(state['bit_path']);assert sha(bit)==state['bit_sha256']=='60d25f6ff3056fea9c2f621ace6666f2d9cb29771813617c2aa542433ed77ff6'
 assert read(HDL/'model/active_model.json')['run']==state['model']
 files=[p for p in HDL.rglob('*') if p.is_file()]+[BOARD/'deployment_state.json',BOARD/'td_project/camera_to_dsi_display.al',BOARD/'td_project/camera_to_dsi_display.sdc',BOARD/'user_source/constraints_source/pin.adc',BOARD/'reports/yolo_rollback_20261021/programming.json',BOARD/'reports/yolo_rollback_20261021/program_jtag.log']
 OUT.mkdir(parents=True);sources={}
 for p in files:
  rel=p.relative_to(REPO);dest=OUT/'repo'/rel;dest.parent.mkdir(exist_ok=True,parents=True);shutil.copy2(p,dest);assert sha(dest)==sha(p);sources[rel.as_posix()]=sha(p)
 shutil.copy2(bit,OUT/'previous_working.bit');assert sha(OUT/'previous_working.bit')==state['bit_sha256']
 source_hashes={p.relative_to(REPO).as_posix():sha(p) for p in (BOARD/'user_source').rglob('*') if p.is_file()}
 record={'recorded_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'repo':str(REPO),'git_head':subprocess.check_output(['git','rev-parse','HEAD'],cwd=REPO,text=True).strip(),'git_branch':subprocess.check_output(['git','branch','--show-current'],cwd=REPO,text=True).strip(),'prior_board_state':state,'backup_files':sources,'all_user_source_hashes':source_hashes,'previous_bit_sha256':sha(OUT/'previous_working.bit'),'project_sha256':sha(BOARD/'td_project/camera_to_dsi_display.al')}
 (OUT/'manifest.json').write_text(json.dumps(record,indent=2),encoding='utf8');print('TWO_SOURCE_BASELINE_CAPTURED',len(files),flush=True)

"""Freeze previous run-cache evidence before the existing project is rebuilt."""
import datetime,hashlib,json,shutil
from pathlib import Path
BASE=Path(__file__).resolve().parents[1];BOARD=BASE.parent/'08_csi_dsi_cs500_7cun';CACHE=BOARD/'td_project/camera_to_dsi_display_Runs/phy_1';OUT=BASE/'wbc_bccd/baseline/prior_run_cache'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
if __name__=='__main__':
 if OUT.exists():raise FileExistsError('Keep previous run cache immutable')
 OUT.mkdir();files=[p for p in CACHE.iterdir() if p.is_file() and (p.suffix in ['.bit','.area','.timing','.tcl','.prj'] or p.name in ['build_result.json','source_hashes.json','build.log'])]
 for p in files:shutil.copy2(p,OUT/p.name);assert sha(p)==sha(OUT/p.name)
 state=json.loads((BOARD/'deployment_state.json').read_text(encoding='utf8'))
 record={'recorded_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'cache_is_not_current_board_state':True,'actual_board_bit_sha256':state['bit_sha256'],'files':{p.name:sha(p) for p in files}}
 (OUT/'archive_manifest.json').write_text(json.dumps(record,indent=2),encoding='utf8');print('PREVIOUS_RUN_CACHE_ARCHIVED',len(files),flush=True)

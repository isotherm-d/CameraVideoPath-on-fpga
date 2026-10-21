"""Rerun inherited board regressions and bind them to unchanged source hashes."""
import json,subprocess,sys
from pathlib import Path
BASE=Path(__file__).resolve().parents[1];sys.path.insert(0,str(BASE))
from wbcatt.run_regressions import hashes
BOARD=BASE.parent/'08_csi_dsi_cs500_7cun';OUT=BASE/'tmp/wbc_bccd_regression';OUT.mkdir(exist_ok=True)
before=hashes()
for cmd,file in [([sys.executable,str(BASE/'five/run_legacy_tracks.py')],'legacy_console.log'),
 (['powershell.exe','-NoProfile','-NonInteractive','-File',str(BOARD/'tools/run_v29_regression.ps1'),'-OutputDir',str(OUT/'video')],'video_regression.log'),
 ([sys.executable,'-m','unittest','discover','-s',str(BOARD/'tools'),'-p','test_*.py'],'python_regression.log')]:
 with (OUT/file).open('wb') as f:subprocess.run(cmd,cwd=BASE.parent,stdout=f,stderr=subprocess.STDOUT,check=True)
assert before==hashes(),'Regression sources changed'
(BASE/'wbc_bccd/regression_source_hashes.json').write_text(json.dumps(before,indent=2),encoding='utf8')
print('TWO_SOURCE_ORIGINAL_REGRESSIONS_PASS',flush=True)

"""Check the original default tracking schedule remains compatible."""
import hashlib,json,re,subprocess
from pathlib import Path
BASE=Path(__file__).resolve().parents[1];REPO=BASE.parent;BOARD=REPO/'08_csi_dsi_cs500_7cun';MS=Path('C:/modeltech64_2020.4/win64')
OUT=BASE/'tmp/five_legacy_tracks';OUT.mkdir(parents=True,exist_ok=True)
src=BOARD/'user_source/hdl_source/classify/cvp_cell_tracks.v';tests=['tb_tracks','tb_temporal','tb_temporal5'];files=[src]+[BOARD/'sim/cellnet32'/(n+'.sv') for n in tests]
def hashes():return {str(p.relative_to(REPO)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
before=hashes()
def run(exe,args,name,marker=None):
 p=subprocess.run([str(MS/(exe+'.exe')),*args],cwd=OUT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 (OUT/(name+'.log')).write_text(p.stdout,encoding='utf8')
 if p.returncode or re.search(r'\*\* (?:Fatal|Error)',p.stdout) or (marker and marker not in p.stdout):raise RuntimeError(p.stdout[-3000:])
run('vlib',['work'],'vlib');run('vlog',['-sv',*[str(p) for p in files]],'compile')
for n in tests:
 run('vsim',['-batch','-quiet','work.'+n,'-do','run -all; quit -f'],n,'TEST_RESULT PASS '+n);print('PASS',n,flush=True)
assert before==hashes()
(OUT/'results.json').write_text(json.dumps({'tests':{n:'PASS' for n in tests},'source_hashes':before},indent=2))

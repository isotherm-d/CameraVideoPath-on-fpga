"""Run independent ModelSim checks for timestamps and the physical 595 bitstream."""
import hashlib,json,re,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
REPO=ROOT.parents[1]
MS=Path(r'C:\modeltech64_2020.4\win64')
OUT=REPO/'yolo/tmp/latency_display_20261022'

def main():
    OUT.mkdir(parents=True,exist_ok=True)
    files=[ROOT/'user_source/hdl_source/common/cvp_latency_display.v',
           ROOT/'user_source/hdl_source/common/cvp_mailbox.v',ROOT/'tools/sim/tb_latency_display.sv']
    def run(exe,args,name,marker=None):
        p=subprocess.run([str(MS/(exe+'.exe')),*args],cwd=OUT,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
        (OUT/(name+'.log')).write_text(p.stdout,encoding='utf-8')
        if p.returncode or re.search(r'\*\* (?:Fatal|Error)',p.stdout) or marker and marker not in p.stdout:
            raise RuntimeError(name+'\n'+p.stdout[-2500:])
        print(name,'PASS',flush=True)
    run('vlib',['work'],'vlib')
    run('vlog',['-sv',*[str(p) for p in files]],'compile')
    for tb in ['tb_latency_display','tb_hc595_scan']:
        run('vsim',['-batch','-quiet','work.'+tb,'-do','run -all; quit -f'],tb,'TEST_RESULT PASS '+tb)
    (OUT/'results.json').write_text(json.dumps({'status':'PASS','board_validated':False,
        'source_hashes':{str(p.relative_to(REPO)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files}},indent=2),encoding='utf-8')
if __name__=='__main__':main()

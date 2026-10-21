import argparse,hashlib,json,re,shutil,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parent
HDL=ROOT.parent/'hardware/mainboard/user_source/hdl_source/yolo'
MS=Path(r'C:/modeltech64_2020.4/win64')
def main(args):
 out=ROOT/'tmp'/f'rtl_v{args.vector}';out.mkdir(parents=True,exist_ok=True)
 files=list(HDL.glob('*.v'))+list(HDL.glob('*.vh'))+list((HDL/'model').glob('*.hex'))+[ROOT/'tb_yolo160.sv']
 def hashes():return {str(p.relative_to(ROOT.parent)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
 before=hashes()
 for p in (HDL/'model').glob('*.hex'):shutil.copy2(p,out/p.name)
 for p in (ROOT/'runs'/args.name/'vectors'/f'v{args.vector}').glob('*.hex'):shutil.copy2(p,out/p.name)
 def run(exe,argv,name,marker=None):
  p=subprocess.run([str(MS/(exe+'.exe')),*argv],cwd=out,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
  (out/(name+'.log')).write_text(p.stdout,encoding='utf8')
  if p.returncode or re.search(r'\*\* (?:Fatal|Error)|MISMATCH',p.stdout) or (marker and marker not in p.stdout):raise RuntimeError(name+': '+p.stdout[-3500:])
  print(name,'PASS',p.stdout[-500:],flush=True)
 run('vlib',['work'],'vlib')
 run('vlog',['-sv','+incdir+'+str(HDL),str(HDL/'yolo160_first.v'),str(HDL/'yolo160_core.v'),str(HDL/'yolo160_boxes.v'),str(ROOT/'tb_yolo160.sv')],'compile')
 if not args.compile_only:
  run('vsim',['-batch','-quiet','-l','simulation.transcript','work.tb_yolo160','-do','run -all; quit -f'],'sim','TEST_RESULT PASS')
  log=(out/'sim.log').read_text(encoding='utf8');m=re.search(r'PASS tb_yolo160 cycles=(\d+) logits=(\d+) first_words=(\d+)',log)
  assert before==hashes(),'Source changed during verification'
  report={'vector':args.vector,'cycles':int(m[1]),'logits':int(m[2]),'first_words':int(m[3]),'integer_layers':'all ten layers and final five-box list exact','status':'PASS','source_hashes':before}
  (out/'result.json').write_text(json.dumps(report,indent=2))
if __name__=='__main__':
 ap=argparse.ArgumentParser();ap.add_argument('--name',default='s160_w0075_intqat');ap.add_argument('--vector',type=int,default=0);ap.add_argument('--compile-only',action='store_true');main(ap.parse_args())

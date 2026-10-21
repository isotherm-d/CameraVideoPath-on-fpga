"""Detector controls, bounded postprocess, and full 720p30 FPGA path checks."""
import argparse,hashlib,json,re,shutil,subprocess
from pathlib import Path
import numpy as np
from export import ROOT,HDL,writehex
from calibrate import predict
MS=Path(r'C:/modeltech64_2020.4/win64')
REPO=ROOT.parent;BOARD=REPO/'hardware/mainboard';CELL=HDL.parent/'classify';LEGACY_CELL=REPO/'old/cellnet32/classify'

def main(args):
 out=ROOT/'tmp'/('integration_paced' if args.paced else 'integration_full' if args.full else 'integration_control');out.mkdir(parents=True,exist_ok=True)
 sources=list(HDL.glob('*.v'))+([*CELL.glob('*.v'),*LEGACY_CELL.glob('*.v')] if args.full else [])
 tests=['tb_yolo_full'] if args.full else ['tb_yolo_control','tb_yolo_post']
 files=sources+list(HDL.glob('*.vh'))+list((HDL/'model').glob('*.hex'))+[ROOT/(n+'.sv') for n in tests]
 if args.full:files += list(LEGACY_CELL.glob('*.vh'))+[LEGACY_CELL/'model/wrom.hex']
 def hashes():return {str(p.relative_to(ROOT.parent)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
 before=hashes()
 for p in (HDL/'model').glob('*.hex'):shutil.copy2(p,out/p.name)
 if args.full:
  shutil.copy2(LEGACY_CELL/'model/wrom.hex',out/'wrom.hex')
  run=ROOT/'runs/s160_w0075_intqat';vec=run/'vectors/v0'
  for n in ['rgb.hex','expected_boxes.hex']:shutil.copy2(vec/n,out/n)
  # Independent CellNet ROM-decoded integer golden on the same fixed480 view.
  image=np.load(vec/'golden.npz')['rgb'];xy=np.arange(32)*15
  xx,yy=np.meshgrid((407+xy-320)//4,(127+xy-40)//4);rgb=image[yy,xx]
  writehex(out/'class_bytes.hex',rgb.transpose(2,0,1).ravel(),2)
  header=(LEGACY_CELL/'cellnet32_params.vh').read_text()
  def param(n):return int(re.search(r'\b'+n+r'\s*=\s*(\d+)',header)[1])
  words=np.array([int(v,16) for v in (out/'wrom.hex').read_text().split()],dtype='<u4');a=rgb.transpose(2,0,1).astype(np.int64)
  for layer,ci in [(1,3),(2,6),(3,12)]:
   wb,bb,co=param('BASE_W'+str(layer)),param('BASE_B'+str(layer)),param('C'+str(layer))
   w=words[wb:bb].view(np.int8)[:co*ci*9].reshape(co,3,3,ci).transpose(0,3,1,2).astype(np.int64)
   b=words[bb:bb+co].view('<i4').astype(np.int64);s=param('S'+str(layer))
   win=np.lib.stride_tricks.sliding_window_view(np.pad(a,((0,0),(1,1),(1,1))),(3,3),axis=(1,2))
   a=np.clip((np.einsum('cyxij,ocij->oyx',win,w)+b[:,None,None]+(1<<(s-1)))>>s,0,255)
   if layer<3:
    c,h,w=a.shape;a=a.reshape(c,h//2,2,w//2,2).max((2,4))
  fw=words[param('BASE_FCW'):param('BASE_FCB')].view(np.int8).reshape(5,24).astype(np.int64)
  fb=words[param('BASE_FCB'):param('WROM_WORDS')].view('<i4').astype(np.int64)
  writehex(out/'class_logits.hex',(int(v)&0xffffffff for v in fw@a.sum((1,2))+fb),8)
 else:
  cases=[]
  for t in range(3):
   raw=np.full((10,10,3,6),-32768,dtype=np.int16)
   if t:
    raw[...,0:2]=0;raw[...,2:4]=-256;raw[...,4:6]=32767
   if t==2:
    raw[...,2:4]=256;raw[...,4:6]=1088
    raw[4:8,4:8,:,4:6]=32767
   cases.append(raw.reshape(10,10,18).transpose(2,0,1))
  writehex(out/'post_logits.hex',(int(v)&65535 for c in cases for v in c.transpose(1,2,0).ravel()),4)
  packed=[]
  for c in cases:
   bb,ss=predict(c,62099);coords=np.rint(bb*640).astype(int)
   boxes=[sum(int(v)<<(12*(3-k)) for k,v in enumerate(b)) for b in coords]+[0xffffffffffff]*(5-len(coords))
   packed.append(sum(v<<(48*k) for k,v in enumerate(boxes)))
  writehex(out/'post_boxes.hex',packed,60)
 def run(exe,argv,name,marker=None):
  p=subprocess.run([str(MS/(exe+'.exe')),*argv],cwd=out,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
  (out/(name+'.log')).write_text(p.stdout,encoding='utf8')
  if p.returncode or re.search(r'\*\* (?:Fatal|Error)|MISMATCH',p.stdout) or (marker and marker not in p.stdout):raise RuntimeError(name+': '+p.stdout[-4000:])
  print(name,'PASS',p.stdout[-1000:],flush=True)
 run('vlib',['work'],'vlib')
 run('vlog',['-sv','+incdir+'+str(HDL),'+incdir+'+str(LEGACY_CELL),*[str(p) for p in sources],*[str(ROOT/(t+'.sv')) for t in tests]],'compile')
 for t in tests:
  generics=['-gPIXEL_GAP=3','-gROW_GAP=604'] if args.paced else []
  run('vsim',['-batch','-quiet','-l',t+'.transcript','work.'+t,*generics,'-do','run -all; quit -f'],t,'TEST_RESULT PASS '+t)
 assert before==hashes(),'Sources changed during integration checks'
 (out/'results.json').write_text(json.dumps({'tests':{t:'PASS' for t in tests},'source_hashes':before,'board_validated':False},indent=2))
if __name__=='__main__':
 ap=argparse.ArgumentParser();ap.add_argument('--full',action='store_true');ap.add_argument('--paced',action='store_true');args=ap.parse_args()
 if args.paced:args.full=True
 main(args)

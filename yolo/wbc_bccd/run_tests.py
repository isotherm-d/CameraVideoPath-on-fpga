"""Source-bound ModelSim tests for joint five-class YOLO, without PC video IO."""
import argparse,hashlib,json,re,shutil,subprocess,sys
from pathlib import Path
import numpy as np
BASE=Path(__file__).resolve().parents[1];REPO=BASE.parent;sys.path.insert(0,str(BASE))
from export import writehex
from wbc_bccd.object_reference import predict
HDL=REPO/'hardware/mainboard/user_source/hdl_source';YOLO=HDL/'yolo'
MS=Path('C:/modeltech64_2020.4/win64')
def bench(t):return BASE/('wbc_bccd' if t=='tb_five_post' else 'five')/(t+'.sv')
def main(args):
 kind='unit' if args.unit else 'stream_paced' if args.stream and args.paced else 'stream_burst' if args.stream else 'v'+str(args.vector)
 out=BASE/'tmp'/('five_'+kind);out.mkdir(parents=True,exist_ok=True)
 tests=['tb_five_sampler','tb_five_post','tb_five_tracks','tb_single_cell','tb_full_label'] if args.unit else ['tb_five_stream'] if args.stream else ['tb_five_vector']
 sources=list(YOLO.glob('*.v'))+[HDL/'classify/cvp_cell_tracks.v',HDL/'classify/cvp_cell_label.v']
 assert '`define YOLO_OBJECTNESS_ONLY 1' in (YOLO/'yolo160_threshold.vh').read_text()
 files=sources+list(YOLO.glob('*.vh'))+list((YOLO/'model').glob('*.hex'))+[Path(__file__),BASE/'model.py',BASE/'export.py',BASE/'five/calibrate.py',BASE/'wbc_bccd/object_reference.py']+[bench(t) for t in tests]
 def hashes():return {str(p.relative_to(REPO)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
 before=hashes()
 for p in (YOLO/'model').glob('*.hex'):shutil.copy2(p,out/p.name)
 if args.unit:
  threshold=int(re.search(r'YOLO_SCORE_THRESHOLD\s+(\d+)',(YOLO/'yolo160_threshold.vh').read_text())[1]);cases=[]
  for case in range(6):
   raw=np.full((10,10,3,10),-32768,dtype=np.int16)
   if case:
    raw[...,:2]=0;raw[...,2:4]=-256 if case==1 else 256;raw[...,4]=32767 if case==1 else 1088
    for y in range(10):
     for x in range(10):
      for a in range(3):raw[y,x,a,5+(x+y+a)%5]=32767 if case==1 else 1088
    if case==2:
     raw[4:8,4:8,:,4]=32767
     for y in range(4,8):
      for x in range(4,8):
       for a in range(3):raw[y,x,a,5+(x+y+a)%5]=32767
    if case==3:
     raw[...,4]=-32768;raw[5,5,1:3,2:5]=32767;raw[5,5,1:3,5:]=32767
    if case==4:
     raw.fill(-32768);raw[5,5,1,:4]=0;raw[5,5,1,4]=32767;raw[5,5,1,5:]=-1024;raw[5,5,1,7]=-512
    if case==5:
     raw[...,:4]=0;raw[...,4]=-32768;raw[...,5:]=32767
   cases.append(raw.reshape(10,10,30).transpose(2,0,1))
  writehex(out/'post_logits.hex',(int(v)&65535 for c in cases for v in c.transpose(1,2,0).ravel()),4)
  box_words=[];class_words=[];score_words=[]
  for c in cases:
   bb,ss,cc=predict(c,threshold);boxes=[sum(int(v)<<(12*(3-k)) for k,v in enumerate(b)) for b in bb]+[0xffffffffffff]*(5-len(bb))
   box_words.append(sum(v<<(48*k) for k,v in enumerate(boxes)))
   class_words.append(sum(int(v)<<(3*k) for k,v in enumerate(cc.tolist()+[5]*(5-len(cc)))))
   score_words.append(sum(int(v)<<(16*k) for k,v in enumerate(ss.tolist()+[0]*(5-len(ss)))))
  writehex(out/'post_boxes.hex',box_words,60);writehex(out/'post_classes.hex',class_words,4);writehex(out/'post_scores.hex',score_words,20)
 else:
  run=BASE/'runs'/args.name;vec=run/'vectors'/('v0' if args.stream else 'v'+str(args.vector))
  for p in vec.glob('*.hex'):shutil.copy2(p,out/p.name)
 def run(exe,argv,name,marker=None):
  p=subprocess.run([str(MS/(exe+'.exe')),*argv],cwd=out,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
  (out/(name+'.log')).write_text(p.stdout,encoding='utf8')
  if p.returncode or re.search(r'\*\* (?:Fatal|Error)|MISMATCH',p.stdout) or (marker and marker not in p.stdout):raise RuntimeError(name+': '+p.stdout[-4000:])
  print(name,'PASS',p.stdout[-1200:],flush=True)
 run('vlib',['work'],'vlib')
 run('vlog',['-sv','+incdir+'+str(YOLO),*[str(p) for p in sources],*[str(bench(t)) for t in tests]],'compile')
 for t in tests:
  options=['-gPIXEL_GAP=3','-gROW_GAP=604'] if args.stream and args.paced else []
  if not args.unit and not args.stream:
   layers=json.loads((YOLO/'model/layers.json').read_text())
   options=[f'-gL7_WORDS={100*layers[7]["groups"]}',f'-gL8_WORDS={100*layers[8]["groups"]}']
  run('vsim',['-batch','-quiet','-l',t+'.transcript','work.'+t,*options,'-do','run -all; quit -f'],t,'TEST_RESULT PASS '+t)
 assert before==hashes(),'Sources changed during verification'
 data_files={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in out.glob('*.hex')}
 report={'status':'PASS','tests':{t:'PASS' for t in tests},'source_hashes':before,'input_hex_hashes':data_files,'kind':kind,'model':args.name,'board_validated':False}
 (out/'results.json').write_text(json.dumps(report,indent=2))
if __name__=='__main__':
 parser=argparse.ArgumentParser();parser.add_argument('--name');parser.add_argument('--unit',action='store_true');parser.add_argument('--vector',type=int,default=0);parser.add_argument('--stream',action='store_true');parser.add_argument('--paced',action='store_true');args=parser.parse_args()
 if args.name is None:args.name=json.loads((BASE/'five/model_selection.json').read_text())['selected']['run']
 main(args)

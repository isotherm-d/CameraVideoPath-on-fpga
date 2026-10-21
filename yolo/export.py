"""Export packed RTL ROMs and independent numpy integer detection vectors."""
import argparse,hashlib,json,math
from pathlib import Path
import numpy as np
from numpy.lib.stride_tricks import sliding_window_view
from model import Detector,decode
from train import iou,nms
import torch
ROOT=Path(__file__).resolve().parent
HDL=ROOT.parent/'hardware/mainboard/user_source/hdl_source/yolo'
def writehex(p,words,digits):p.write_text(''.join(f'{int(v):0{digits}x}\n' for v in words),encoding='ascii')
def integer(x,d,collect=False):
 a=x.transpose(2,0,1).astype(np.int64);features=[]
 for i in range(10):
  w,b,s=d[f'w{i}'].astype(np.int64),d[f'b{i}'].astype(np.int64),d[f's{i}'].astype(np.int64)
  k=w.shape[-1];pad=k//2;win=sliding_window_view(np.pad(a,((0,0),(pad,pad),(pad,pad))),(k,k),axis=(1,2))
  acc=np.einsum('cyxkl,ockl->oyx',win,w,dtype=np.int64,optimize=False)+b[:,None,None]
  y=(acc+np.where(s>0,np.left_shift(1,np.maximum(s-1,0)),0)[:,None,None])>>s[:,None,None]
  a=np.clip(y,-32768,32767) if i==9 else np.clip(y,0,15)
  if i<4:a=a.reshape(a.shape[0],a.shape[1]//2,2,a.shape[2]//2,2).max((2,4))
  if collect:features.append(a.astype(np.int16))
 return a.astype(np.int16),features
SIG=np.floor(255/(1+np.exp(-(np.arange(256)-128)/16))+.5).astype(np.int64)
ANCH=np.array([[20,24],[40,48],[80,88]])
def decode_int(logits,geometry='center640',return_classes=False):
 fields=logits.shape[0]//3
 raw=logits.transpose(1,2,0).reshape(10,10,3,fields).transpose(2,0,1,3).astype(np.int64)
 s=SIG[np.clip((raw>>4)+128,0,255)];yy,xx=np.meshgrid(np.arange(10),np.arange(10),indexing='ij')
 xq=(xx[None]*256+2*s[...,0]-128)*16;yq=(yy[None]*256+2*s[...,1]-128)*16
 wq=(s[...,2]**2*ANCH[:,None,None,0])>>6;hq=(s[...,3]**2*ANCH[:,None,None,1])>>6
 # Native detector local coordinates are in the original center640 view.
 if geometry=='fullframe':
  boxes=np.stack([((xq-wq//2)>>5).clip(0,1279),(((yq-hq//2)*9)>>9).clip(0,719),
                  ((xq+wq//2)>>5).clip(0,1279),(((yq+hq//2)*9)>>9).clip(0,719)],-1)
 else:boxes=np.stack([(xq-wq//2)>>6,(yq-hq//2)>>6,(xq+wq//2)>>6,(yq+hq//2)>>6],-1).clip(0,639)
 boxes=boxes.transpose(1,2,0,3).reshape(-1,4)
 score=(s[...,4]*s[...,5:].max(-1)).transpose(1,2,0).reshape(-1)
 classes=s[...,5:].argmax(-1).transpose(1,2,0).reshape(-1)
 return (boxes,score,classes) if return_classes else (boxes,score)
def main(args):
 global HDL
 if getattr(args,'hdl',None):HDL=Path(args.hdl)
 run=ROOT/'runs'/args.name;out=HDL/'model';out.mkdir(parents=True,exist_ok=True);d=np.load(run/'quantized.npz');protocol=json.loads((run/'protocol.json').read_text())
 if protocol['side']!=160:raise ValueError('This RTL export is the 160/stride16 experiment')
 nclasses=len(protocol['classes']);channels=3*(5+nclasses)
 if protocol['channels'] not in [[8,8,8,16,24,40,80,24,40,channels],[8,8,8,16,24,40,80,40,56,channels]]:raise ValueError('Feature RAM and folded schedule require a supported channel layout')
 bounds=[]
 for i in range(10):
  w=d[f'w{i}'].astype(np.int64);b=d[f'b{i}'].astype(np.int64);s=d[f's{i}'].astype(np.int64)
  bits=32 if i==0 else 24
  bound=np.abs(w).sum((1,2,3))*(255 if i==0 else 15)+np.abs(b)+np.where(s>0,1<<np.maximum(s-1,0),0)
  if bound.max()>=2**(bits-1):raise OverflowError(f'Layer {i} exceeds signed{bits} accumulator/requant range')
  bounds.append({'layer':i,'signed_bits':bits,'maximum_absolute_bound_including_bias_and_rounding':int(bound.max())})
 (out/'accumulator_bounds.json').write_text(json.dumps(bounds,indent=2))
 words=[];head=[];meta=[];layers=[];c1=[]
 for i in range(10):
  w,b,s=d[f'w{i}'],d[f'b{i}'],d[f's{i}'];co,ci,k,_=w.shape;ng=(co+7)//8
  layers.append({'layer':i,'cin':ci,'cout':co,'groups':ng,'kernel':k,'wbase':len(words),'mbase':len(meta),'input_dim':160//(2**min(i,4)),'pool':i<4})
  for g in range(ng):
   for lane in range(8):
    ch=g*8+lane;bias=int(b[ch]) if ch<co else 0;shift=int(s[ch]) if ch<co else 0
    meta.append((shift<<32)|(bias&0xffffffff))
   for ky in range(k):
    for kx in range(k):
     for ic in range(ci):
      vec=[int(w[g*8+j,ic,ky,kx]) if g*8+j<co else 0 for j in range(8)]
      if i==0:continue
      if i==9:head.append(sum((v&255)<<(8*j) for j,v in enumerate(vec)))
      else:words.append(sum((v&15)<<(4*j) for j,v in enumerate(vec)))
 for ky in range(3):
  for kx in range(3):c1.append(sum((int(d['w0'][o,c,ky,kx])&255)<<(8*(o*3+c)) for o in range(8) for c in range(3)))
 writehex(out/'weights4.hex',words,8);writehex(out/'head8.hex',head,16);writehex(out/'meta.hex',meta,10);writehex(out/'first8.hex',c1,48);writehex(out/'sigmoid.hex',SIG,2)
 config=['// Generated from the frozen W4A4 experiment.','`ifndef YOLO160_CONFIG_VH','`define YOLO160_CONFIG_VH',f'`define YOLO_CLASSES {nclasses}',f'`define YOLO_CHANNELS {channels}',f'`define YOLO_FULL_FRAME {int(protocol.get("geometry")=="fullframe")}',f'`define YOLO_W4_WORDS {len(words)}',f'`define YOLO_HEAD_WORDS {len(head)}',f'`define YOLO_META_WORDS {len(meta)}']
 for i in range(8):config.extend([f'`define YOLO_C1_B{i} 32\'h{int(d["b0"][i])&0xffffffff:08x}',f'`define YOLO_C1_S{i} {int(d["s0"][i])}'])
 config.append('`endif');(HDL/'yolo160_config.vh').write_text('\n'.join(config)+'\n',encoding='ascii')
 # Case statements keep layer arithmetic constant and avoid address multipliers.
 lines=[]
 for l in layers[1:]:
  dim=l['input_dim'];ig=l['cin']//8;od=dim//2 if l['pool'] else dim
  lines.append(f'{l["layer"]}: begin dim<={dim};cin<={l["cin"]};cout<={l["cout"]};ng<={l["groups"]};ig<={ig};rw<={dim*ig};odim<={od};pool_en<={int(l["pool"])};kernel_one<={int(l["kernel"]==1)};weight_base<={l["wbase"]};meta_base<={l["mbase"]};end')
 (HDL/'yolo160_layers.vh').write_text('\n'.join(lines)+'\n',encoding='ascii');(out/'layers.json').write_text(json.dumps(layers,indent=2))
 vec=run/'vectors';vec.mkdir(exist_ok=True);data=np.load(ROOT/'data'/protocol['data_file'])
 selection=[]
 if nclasses==5:
  for c in range(5):selection+=list(map(int,np.where(data['val_classes'][:,0]==c)[0][:2]))
  selection+=list(map(int,np.where((data['val_domain']==0)&(data['val_n']>0))[0][:2]))
 else:
  for dom in [0,1]:
   ids=np.where((data['val_domain']==dom)&(data['val_n']>0))[0][:2];selection.extend(map(int,ids))
 selection+=list(map(int,np.where(data['val_n']==0)[0][:2]))
 if getattr(args,'vector_indices',None) is not None:selection=list(args.vector_indices)
 for j,idx in enumerate(selection):
  im=data['val_x'][idx];log,fs=integer(im,d,True);folder=vec/f'v{j}';folder.mkdir(exist_ok=True)
  writehex(folder/'rgb.hex',(int(p[0])<<16|int(p[1])<<8|int(p[2]) for p in im.reshape(-1,3)),6)
  for i,a in enumerate(fs):
   if i<9:
    chw=a.transpose(1,2,0);padded=np.pad(chw,((0,0),(0,0),(0,(-chw.shape[2])%8))).reshape(-1,8)
    writehex(folder/f'layer{i}.hex',(sum(int(v)<<(4*k) for k,v in enumerate(row)) for row in padded),8)
   else:writehex(folder/'logits.hex',(int(z)&65535 for z in a.transpose(1,2,0).ravel()),4)
  np.savez(folder/'golden.npz',rgb=im,logits=log,boxes=data['val_boxes'][idx],n=data['val_n'][idx],classes=data['val_classes'][idx] if nclasses==5 else np.full(8,-1))
 (vec/'manifest.json').write_text(json.dumps({'indices':selection,'source':'VAL only; no TEST selection','vectors':len(selection)},indent=2))
 assets={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in out.glob('*') if p.is_file() and p.name!='active_model.json'}
 (out/'active_model.json').write_text(json.dumps({'run':args.name,'protocol':protocol,'quantized_sha256':hashlib.sha256((run/'quantized.npz').read_bytes()).hexdigest(),'assets':assets,'status':'exported_not_RTL_verified'},indent=2))
 print('YOLO_ROM_EXPORTED',len(words),len(head),len(meta),'vectors',len(selection),flush=True)
if __name__=='__main__':
 ap=argparse.ArgumentParser();ap.add_argument('--name',default='s160_w0075_intqat');main(ap.parse_args())

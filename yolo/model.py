"""Small, single-scale anchor detector; operator layout follows the LPYOLO study.

This is a fresh PyTorch/RTL-oriented implementation, not a port of FINN IP.
W4A4 hidden convolutions; first/last weights W8; RGB input A8.
"""
import math
import torch
from torch import nn
from torch.nn import functional as F

ANCHORS=((20,24),(40,48),(80,88)) # at 160 input; scale with input side
def ste(x,q):return q.detach()+(x-x.detach())
class Block(nn.Module):
 def __init__(self,ci,co,k,first=False,last=False):
  super().__init__();self.conv=nn.Conv2d(ci,co,k,padding=k//2,bias=last)
  self.bn=nn.Identity() if last else nn.BatchNorm2d(co)
  self.first=first;self.last=last;self.qat=False
  self.ins=1/256 if first else .25;self.outs=1/256 if last else .25
  self.bits=8 if first or last else 4
  self.register_buffer('shift',torch.zeros(co,dtype=torch.int64))
 def forward(self,x):
  if self.qat:
   sf=torch.pow(2.,self.shift.float())
   f=(self.ins/self.outs)*sf[:,None,None,None]
   qmax=2**(self.bits-1)-1
   wi=ste(self.conv.weight*f,torch.floor(self.conv.weight*f+.5).clamp(-qmax,qmax))
   bf=sf/self.outs;bi=ste(self.conv.bias*bf,torch.floor(self.conv.bias*bf+.5))
   # Exact integer accumulator in float64, including rounding ties. Float32
   # convolution algorithms can otherwise disagree at half-LSB boundaries.
   acc=F.conv2d((x/self.ins).double(),wi.double(),bi.double(),padding=self.conv.kernel_size[0]//2)
   z=acc/sf.double()[None,:,None,None];q=ste(z,torch.floor(z+.5))
   q=q.clamp(-32768,32767) if self.last else q.clamp(0,15)
   return q.to(x.dtype)*self.outs
  else:x=self.bn(self.conv(x))
  if not self.last:x=x.clamp(0,3.75)
  if self.qat:
   q=torch.floor(x/self.outs+.5).clamp(-32768,32767) if self.last else torch.floor(x/self.outs+.5).clamp(0,15)
   x=ste(x,q*self.outs)
  return x
 @torch.no_grad()
 def enable_qat(self):
  if not self.last:
   bn=self.bn;factor=bn.weight/torch.sqrt(bn.running_var+bn.eps)
   w=self.conv.weight*factor[:,None,None,None];b=bn.bias-bn.running_mean*factor
   c=nn.Conv2d(self.conv.in_channels,self.conv.out_channels,self.conv.kernel_size[0],padding=self.conv.kernel_size[0]//2,bias=True).to(device=w.device,dtype=w.dtype)
   c.weight.copy_(w);c.bias.copy_(b);self.conv=c;self.bn=nn.Identity()
  effective=self.conv.weight.abs().flatten(1).amax(1)*(self.ins/self.outs)
  self.shift.copy_(torch.floor(torch.log2((2**(self.bits-1)-1)/effective.clamp_min(1e-12))).long().clamp(0,24))
  self.qat=True
class Detector(nn.Module):
 def __init__(self,width=.1,side=160,classes=1,wide_head=False):
  super().__init__();self.width=width;self.side=side;self.qat=False;self.classes=classes;self.fields=5+classes
  self.channels=[math.ceil(c*width/8)*8 for c in [16,32,64,128,256,512,1024,256,512]]+[3*self.fields]
  if wide_head:self.channels[7:9]=[40,56]
  ci=3;blocks=[]
  for i,co in enumerate(self.channels):
   blocks.append(Block(ci,co,1 if i==7 or (i==9 and wide_head) else 3,i==0,i==9));ci=co
  self.blocks=nn.ModuleList(blocks)
  with torch.no_grad():
   self.blocks[-1].conv.weight.mul_(.1)
   for a in range(3):
    self.blocks[-1].conv.bias[a*self.fields+4]=-4.
    self.blocks[-1].conv.bias[a*self.fields+5:(a+1)*self.fields]=2. if classes==1 else 0.
 def forward(self,x):
  for i,b in enumerate(self.blocks):
   x=b(x)
   if i<4:x=F.max_pool2d(x,2)
  return x.reshape(len(x),3,self.fields,x.shape[-2],x.shape[-1]).permute(0,1,3,4,2).contiguous()
 def enable_qat(self):
  self.eval()
  for b in self.blocks:b.enable_qat()
  self.qat=True
def decode(raw,side):
 h,w=raw.shape[2:4];yy,xx=torch.meshgrid(torch.arange(h,device=raw.device),torch.arange(w,device=raw.device),indexing='ij')
 grid=torch.stack([xx,yy],-1)[None,None]
 anchor=torch.tensor(ANCHORS,device=raw.device).view(1,3,1,1,2)*side/160
 p=raw.sigmoid();xy=(p[...,:2]*2-.5+grid)*16;wh=(p[...,2:4]*2).square()*anchor
 boxes=torch.cat([xy-wh/2,xy+wh/2],-1)/side
 return boxes,p[...,4]*p[...,5:].amax(-1)

def decode_classes(raw,side):
 boxes,score=decode(raw,side)
 return boxes,score,raw[...,5:].argmax(-1)
def giou(a,b):
 lo=torch.maximum(a[...,:2],b[...,:2]);hi=torch.minimum(a[...,2:],b[...,2:]);inter=(hi-lo).clamp_min(0).prod(-1)
 aa=(a[...,2:]-a[...,:2]).clamp_min(0).prod(-1);bb=(b[...,2:]-b[...,:2]).clamp_min(0).prod(-1);union=aa+bb-inter
 c=(torch.maximum(a[...,2:],b[...,2:])-torch.minimum(a[...,:2],b[...,:2])).clamp_min(0).prod(-1)
 return inter/union.clamp_min(1e-8)-(c-union)/c.clamp_min(1e-8)
def loss(raw,gt,n,side,labels=None):
 batch,_,h,w,_=raw.shape;valid=torch.arange(gt.shape[1],device=gt.device)[None]<n[:,None]
 ids=torch.arange(batch,device=gt.device)[:,None].expand_as(valid)[valid];g=gt[valid]
 wh=(g[:,2:]-g[:,:2])*side;anchors=torch.tensor(ANCHORS,device=gt.device)*side/160
 inter=torch.minimum(wh[:,None],anchors[None]).prod(-1);shape_iou=inter/(wh.prod(-1)[:,None]+anchors.prod(-1)[None]-inter).clamp_min(1e-6)
 ai=shape_iou.argmax(1);center=(g[:,:2]+g[:,2:])/2;gx=(center[:,0]*w).long().clamp(0,w-1);gy=(center[:,1]*h).long().clamp(0,h-1)
 obj=torch.zeros_like(raw[...,4]);obj[ids,ai,gy,gx]=1
 neg=F.binary_cross_entropy_with_logits(raw[...,4][obj==0],obj[obj==0])
 if len(g):
  boxes,_=decode(raw,side);bl=(1-giou(boxes[ids,ai,gy,gx],g)).mean()
  pos=F.binary_cross_entropy_with_logits(raw[ids,ai,gy,gx,4],torch.ones_like(ai,dtype=raw.dtype))
  if raw.shape[-1]==6:
   cls=F.binary_cross_entropy_with_logits(raw[ids,ai,gy,gx,5],torch.ones_like(ai,dtype=raw.dtype))
  else:
   target=labels[valid];typed=target>=0
   logits=raw[ids[typed],ai[typed],gy[typed],gx[typed],5:]
   onehot=F.one_hot(target[typed],raw.shape[-1]-5).to(raw.dtype)
   cls=F.binary_cross_entropy_with_logits(logits,onehot) if typed.any() else raw.sum()*0
 else:bl=raw.sum()*0;pos=bl;cls=bl
 return 5*bl+pos+.5*neg+(.2 if raw.shape[-1]==6 else 2.)*cls

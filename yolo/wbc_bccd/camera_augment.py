"""Camera exposure/panel augmentation; all pixels still come from the two sources."""
import torch
from torch.nn import functional as F
from train import augment
def camera_augment(x,bb,n,cc):
 x,bb,n,cc=augment(x,bb,n,cc);b=len(x);device=x.device
 # Full-frame 16:9 sampling compresses a photographed square display in x.
 panel=torch.rand(b,device=device)<.40
 sx=.38+torch.rand(b,device=device)*.44;sy=.62+torch.rand(b,device=device)*.37
 sx=torch.where(panel,sx,torch.ones_like(sx));sy=torch.where(panel,sy,torch.ones_like(sy))
 ox=(torch.rand(b,device=device)-.5)*(1-sx);oy=(torch.rand(b,device=device)-.5)*(1-sy)
 theta=torch.zeros(b,2,3,device=device);theta[:,0,0]=1/sx;theta[:,1,1]=1/sy;theta[:,0,2]=-2*ox/sx;theta[:,1,2]=-2*oy/sy
 grid=F.affine_grid(theta,x.shape,align_corners=False);inside=(grid.abs()<=1).all(-1)[:,None]
 image=F.grid_sample(x,grid,mode='bilinear',padding_mode='zeros',align_corners=False)
 bg=torch.rand(b,3,1,1,device=device)*.18
 x=torch.where(inside,image,bg)
 factors=torch.stack([sx,sy,sx,sy],1)[:,None];offsets=torch.stack([ox+(1-sx)/2,oy+(1-sy)/2,ox+(1-sx)/2,oy+(1-sy)/2],1)[:,None];bb=(bb*factors+offsets).clamp(0,1)
 # Train low-light positives, not merely low-light empty backgrounds.
 gain=.43+torch.rand(b,1,1,1,device=device)*.72
 x=(x*gain*(.85+torch.rand(b,3,1,1,device=device)*.30)).clamp(0,255/256).pow(.80+torch.rand(b,1,1,1,device=device)*.65)
 blur=F.avg_pool2d(F.pad(x,(1,1,1,1),mode='replicate'),3,stride=1);x=torch.where(torch.rand(b,1,1,1,device=device)<.45,blur,x)
 x=(x+torch.randn_like(x)*torch.rand(b,1,1,1,device=device)*.02).clamp(0,255/256)
 return torch.floor(x*256+.5).clamp(0,255)/256,bb,n,cc

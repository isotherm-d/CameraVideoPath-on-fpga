import numpy as np
from pathlib import Path
from PIL import Image,ImageDraw
BASE=Path(__file__).resolve().parents[1];d=np.load(BASE/'data/wbc_bccd160.npz');x,b,n,c,dom=(d['train'+s] for s in ['_x','_boxes','_n','_classes','_domain']);inds=[int(np.flatnonzero((dom==1)&(c[:,0]==k))[0]) for k in range(5)]+list(np.flatnonzero((dom==0)&(n>0))[:5]);sheet=Image.new('RGB',(800,660),'white')
for j,i in enumerate(inds):
 im=Image.fromarray(x[i]).resize((200,200));draw=ImageDraw.Draw(im)
 for box in b[i,:n[i]]:draw.rectangle(tuple((box*200).astype(int)),outline='lime',width=2)
 draw.text((3,3),('WB '+str(c[i,0])) if dom[i] else 'BCCD',fill='black');sheet.paste(im,((j%4)*200,(j//4)*220))
p=np.load(BASE/'runs/wbc_bccd160_20261021/historical_cell_unknown_true_class_probe.npz')['rgb'];sheet.paste(Image.fromarray(p).resize((200,200)),(400,440));sheet.save(BASE/'wbc_bccd/domain_preview.png')

from pathlib import Path
import random
import argparse
p=Path(__file__).resolve().parents[2]
args=argparse.ArgumentParser()
args.add_argument("--output",type=Path,default=Path.cwd())
out=args.parse_args().output
out.mkdir(parents=True,exist_ok=True)
w,h=16,8
rng=random.Random(26135)
image=[[[rng.randrange(256) for c in range(3)] for x in range(w)] for y in range(h)]
def at(x,y):return image[max(0,min(h-1,y))][max(0,min(w-1,x))]
def lum(p):return (77*p[0]+150*p[1]+29*p[2]+128)>>8
def reference(mode,x,y):
 p=at(x,y);Y=lum(p)
 ns=[at(x+dx,y+dy) for dy in (-1,0,1) for dx in (-1,0,1)]
 ys=list(map(lum,ns))
 gx=ys[2]+2*ys[5]+ys[8]-ys[0]-2*ys[3]-ys[6]
 gy=ys[6]+2*ys[7]+ys[8]-ys[0]-2*ys[1]-ys[2]
 edge=abs(gx)+abs(gy)>=190
 if mode==0:return p
 if mode==1:return [Y]*3
 if mode==2:return [255 if Y>=130 else 0]*3
 if mode==3:return [255 if edge else 0]*3
 if mode==4:
  if edge:return [0]*3
  med=[sorted(v[c] for v in ns)[4] for c in range(3)]
  return [(v>>5)*36+((v>>5)>>1) for v in med]
 if mode==5:return [0 if edge else 255]*3
 return [min(255,(sum(c*v for c,v in zip(row,p))+128)>>8) for row in ((101,197,48),(89,176,43),(70,137,34))]
def rgbhex(p):return ''.join(f'{x:02x}' for x in p)
(out/'style_input.mem').write_text('\n'.join(rgbhex(at(x,y)) for m in range(7) for y in range(h) for x in range(w))+'\n')
(out/'style_expected.mem').write_text('\n'.join(rgbhex(reference(m,x,y)) for m in range(7) for y in range(h) for x in range(w))+'\n')

"""Prepare WBC boxes from BCCD plus existing Raabin TRAIN/VAL masks only."""
import hashlib,io,json,urllib.request,zipfile
import xml.etree.ElementTree as ET
from pathlib import Path
import numpy as np
from PIL import Image

ROOT=Path(__file__).resolve().parent
OLD=Path(r'C:/Users/cqm87/Desktop/2026/cellnet')
SIDE=160
BCCD_COMMIT='d272fb14cdff6e473fafeeeba32aba5f560e9e43'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def fetch(url):
 req=urllib.request.Request(url,headers={'User-Agent':'CellNet-YOLO-experiment'})
 with urllib.request.urlopen(req,timeout=60) as r:return r.read()
def download():
 dest=ROOT/'data/BCCD_Dataset'
 if (dest/'BCCD/Annotations').is_dir():return dest
 commit=BCCD_COMMIT
 raw=fetch(f'https://codeload.github.com/Shenggan/BCCD_Dataset/zip/{commit}')
 if hashlib.sha256(raw).hexdigest()!='e2ed144a0a2c6dbe351f3ddb09fb8ff2c9ad4f947bdf42b6a52dd4f38a996ba9':raise ValueError('BCCD archive hash mismatch')
 with zipfile.ZipFile(io.BytesIO(raw)) as z:
  for entry in z.infolist():
   rel=Path(*Path(entry.filename).parts[1:])
   if not rel.parts or entry.is_dir():continue
   path=(dest/rel).resolve()
   if not path.is_relative_to(dest.resolve()):raise ValueError('Unsafe archive path')
   path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(z.read(entry))
 (dest/'source.json').write_text(json.dumps({'repo':'Shenggan/BCCD_Dataset','commit':commit,'zip_sha256':hashlib.sha256(raw).hexdigest()},indent=2))
 return dest
def frame(im,boxes):
 a=np.asarray(im.convert('RGB'));h,w=a.shape[:2]
 side=max(h,w);padx=(side-w)//2;pady=(side-h)//2
 a=np.pad(a,((pady,side-h-pady),(padx,side-w-padx),(0,0)),mode='edge')
 # Exact center-nearest resampling, the same convention as the hardware sampler.
 coords=((2*np.arange(SIDE)+1)*side//(2*SIDE)).clip(0,side-1)
 a=a[coords[:,None],coords[None,:]]
 b=np.asarray(boxes,dtype=np.float32).reshape(-1,4)
 if len(b):b=(b+np.array([padx,pady,padx,pady]))/side
 return a,b
def main():
 data=download();records=[];images=[];targets=[];splits=[]
 official={}
 for s in ['train','val','test']:
  p=data/f'BCCD/ImageSets/Main/{s}.txt'
  if p.exists():
   for name in p.read_text().split():official[name]=s
 seen={}
 for p in sorted((data/'BCCD/Annotations').glob('*.xml')):
  xml=ET.parse(p).getroot();ip=data/'BCCD/JPEGImages'/xml.findtext('filename')
  boxes=[]
  for obj in xml.findall('object'):
   if obj.findtext('name')!='WBC':continue
   bb=obj.find('bndbox');boxes.append([int(bb.findtext(k)) for k in ['xmin','ymin','xmax','ymax']])
  digest=sha(ip);s=official.get(p.stem)
  if s is None:raise ValueError('BCCD has no official split for '+p.stem)
  if digest in seen:
   if seen[digest]!=s:raise ValueError('Exact image leakage across official BCCD splits')
   continue
  seen[digest]=s
  with Image.open(ip) as im:x,b=frame(im,boxes)
  records.append({'source':'BCCD','name':ip.name,'sha256':digest,'split':s,'boxes':len(b)})
  images.append(x);targets.append(b);splits.append(s)
  # Real background/RBC crops, strictly outside every annotated WBC rectangle.
  # Crops inherit their source frame split. No masking or label erasure.
  with Image.open(ip) as im:
   iw,ih=im.size;cw,ch=iw//2,ih//2;nc=0
   for cx,cy in [(0,0),(iw-cw,0),(0,ih-ch),(iw-cw,ih-ch)]:
    if any(max(0,min(cx+cw,z[2])-max(cx,z[0]))*max(0,min(cy+ch,z[3])-max(cy,z[1]))>0 for z in boxes):continue
    nx,nb=frame(im.crop((cx,cy,cx+cw,cy+ch)),[])
    images.append(nx);targets.append(nb);splits.append(s)
    records.append({'source':'BCCD','name':ip.name+f':negative{cx},{cy}','sha256':digest,'split':s,'boxes':0,'crop':[cx,cy,cx+cw,cy+ch]});nc+=1
    if nc==2:break
 manifest=json.loads((OLD/'runs/tightcrop_20261018/locator_data_manifest.json').read_text())
 for rec in manifest['records']:
  mp=OLD/rec['mask'];ip=OLD/'data/raabin'/rec['path']
  with Image.open(mp) as im:mask=np.asarray(im.convert('RGB')).max(2)>32
  yy,xx=np.where(mask)
  if not len(xx):raise ValueError('Empty ground truth')
  with Image.open(ip) as im:x,b=frame(im,[[xx.min(),yy.min(),xx.max()+1,yy.max()+1]])
  records.append({'source':'Raabin_train','name':rec['path'],'sha256':sha(ip),'split':rec['split'],'source_group':rec['source_group'],'boxes':1})
  images.append(x);targets.append(b);splits.append(rec['split'])
 out={}
 for s in ['train','val','test']:
  ids=[i for i,t in enumerate(splits) if t==s];x=np.stack([images[i] for i in ids]);b=np.zeros((len(ids),8,4),np.float32);n=np.zeros(len(ids),np.int64)
  for j,i in enumerate(ids):
   if len(targets[i])>8:raise ValueError('Target capacity exceeded')
   n[j]=len(targets[i]);b[j,:n[j]]=targets[i]
  out[s+'_x']=x;out[s+'_boxes']=b;out[s+'_n']=n;out[s+'_domain']=np.array([records[i]['source']=='Raabin_train' for i in ids],np.int64)
 p=ROOT/'data/wbc160_v2.npz';np.savez_compressed(p,**out)
 info={'side':SIDE,'task':'one-class whole WBC detection','sources':records,'counts':{s:int(len(out[s+'_n'])) for s in ['train','val','test']},'official_Raabin_test_masks_opened':False,'Raabin_manifest_sha256':sha(OLD/'runs/tightcrop_20261018/locator_data_manifest.json'),'npz_sha256':sha(p),'limitations':['BCCD official scene split is not verified patient split','Raabin mask pairs are single-cell views, not live multi-cell camera scenes','BCCD test remains held out from training and checkpoint selection']}
 (ROOT/'data/manifest_v2.json').write_text(json.dumps(info,ensure_ascii=False,indent=2),encoding='utf8')
 print('DETECT_DATA_READY',info['counts'],flush=True)
if __name__=='__main__':main()

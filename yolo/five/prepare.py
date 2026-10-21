"""Five-class boxes from existing TRAIN/VAL masks; BCCD positives stay untyped."""
import argparse,hashlib,json,sys
from pathlib import Path
import numpy as np
from PIL import Image
BASE=Path(__file__).resolve().parents[1];OLD=Path('C:/Users/cqm87/Desktop/2026/cellnet')
CLASSES=['Basophil','Eosinophil','Lymphocyte','Monocyte','Neutrophil']
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def sample(im,boxes,geometry):
 a=np.array(im.convert('RGB'));h,w=a.shape[:2];b=np.array(boxes,np.float32).reshape(-1,4)
 if geometry=='center640':
  side=max(h,w);dx=(side-w)//2;dy=(side-h)//2
  a=np.pad(a,((dy,side-h-dy),(dx,side-w-dx),(0,0)),mode='edge')
  if len(b):b+=np.array([dx,dy,dx,dy])
  h=w=side
 xx=((2*np.arange(160)+1)*w//320).clip(0,w-1);yy=((2*np.arange(160)+1)*h//320).clip(0,h-1)
 if len(b):b/=np.array([w,h,w,h])
 return a[yy[:,None],xx[None,:]],b
def main(args):
 original=json.loads((BASE/'data/manifest_v2.json').read_text(encoding='utf8'))
 records=[];images=[];boxes=[];labels=[]
 # Keep the old official scene partition and negative-crop grouping exactly.
 for rec in original['sources']:
  source=rec['source'];name=rec['name'];r=dict(rec)
  if source=='BCCD':
   ip=BASE/'data/BCCD_Dataset/BCCD/JPEGImages'/name.split(':')[0]
   if 'crop' in rec:
    with Image.open(ip) as im:a,b=sample(im.crop(rec['crop']),[],args.geometry)
   else:
    import xml.etree.ElementTree as ET
    xml=ET.parse(BASE/'data/BCCD_Dataset/BCCD/Annotations'/(ip.stem+'.xml')).getroot()
    bb=[[int(o.find('bndbox').findtext(k)) for k in ['xmin','ymin','xmax','ymax']] for o in xml.findall('object') if o.findtext('name')=='WBC']
    with Image.open(ip) as im:a,b=sample(im,bb,args.geometry)
   cc=[-1]*len(b);r['class_annotation']='untyped WBC: box/objectness only, no five-class loss'
  else:
   parts=Path(name).parts;cid=CLASSES.index(parts[1]);ip=OLD/'data/raabin'/name
   mp=OLD/'data/raabin_gt/GrTh/Ground Truth'/parts[1]/parts[-1]
   with Image.open(mp) as im:m=np.asarray(im.convert('RGB')).max(2)>32
   y,x=np.where(m);assert len(x)
   with Image.open(ip) as im:a,b=sample(im,[[x.min(),y.min(),x.max()+1,y.max()+1]],args.geometry)
   cc=[cid];r['class_id']=cid;r['mask_sha256']=sha(mp)
  records.append(r);images.append(a);boxes.append(b);labels.append(cc)
 arrays={};counts={}
 for split in ['train','val','test']:
  ids=[i for i,r in enumerate(records) if r['split']==split]
  arrays[split+'_x']=np.stack([images[i] for i in ids]);bb=np.zeros((len(ids),8,4),np.float32);cc=np.full((len(ids),8),-1,np.int64);nn=np.zeros(len(ids),np.int64)
  for j,i in enumerate(ids):nn[j]=len(boxes[i]);bb[j,:nn[j]]=boxes[i];cc[j,:nn[j]]=labels[i]
  arrays[split+'_boxes']=bb;arrays[split+'_classes']=cc;arrays[split+'_n']=nn
  arrays[split+'_domain']=np.array([records[i]['source']=='Raabin_train' for i in ids],np.int64)
  counts[split]={'images':len(ids),'typed_by_class':{c:int((cc==k).sum()) for k,c in enumerate(CLASSES)},'untyped_objects':int(sum(nn))-int((cc>=0).sum())}
 target=BASE/'data'/('five_'+args.geometry+'.npz');np.savez_compressed(target,**arrays)
 manifest={'classes':CLASSES,'geometry':args.geometry,'input_size':160,'counts':counts,'sources':records,
  'source_manifest_sha256':sha(BASE/'data/manifest_v2.json'),'npz_sha256':sha(target),
  'BCCD_classes':'not available; never treated as Basophil or pseudo-classified','official_Raabin_TEST_masks_opened':False,
  'annotation':'whole-cell mask bounding rectangles, class from original TRAIN directory'}
 (BASE/'data'/('five_'+args.geometry+'_manifest.json')).write_text(json.dumps(manifest,ensure_ascii=False,indent=2),encoding='utf8')
 print('FIVE_DATA_READY',target,json.dumps(counts),flush=True)
if __name__=='__main__':
 ap=argparse.ArgumentParser();ap.add_argument('--geometry',choices=['center640','fullframe'],required=True);main(ap.parse_args())

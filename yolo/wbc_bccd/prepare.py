"""Two acquired sources only; preserve partitions and audit parent/input identity."""
import hashlib,json,sys
from pathlib import Path
from collections import Counter,defaultdict
import numpy as np
from PIL import Image
BASE=Path(__file__).resolve().parents[1];HOME=BASE/'wbc_bccd'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def save(p,v):p.write_text(json.dumps(v,ensure_ascii=False,indent=2),encoding='utf8')
def main():
 out=BASE/'data/wbc_bccd160.npz'
 if out.exists() or (HOME/'data_manifest.json').exists():raise FileExistsError('Two-source preparation is immutable')
 wm=json.loads((BASE/'wbcatt/data_manifest.json').read_text());qa=json.loads((BASE/'wbcatt/input_duplicate_audit.json').read_text());bm=json.loads((BASE/'data/five_fullframe_manifest.json').read_text(encoding='utf8'))
 assert sha(BASE/'data/wbcatt160.npz')==wm['npz_sha256']==qa['npz_sha256']
 assert sha(BASE/'data/five_fullframe.npz')==bm['npz_sha256']
 w=np.load(BASE/'data/wbcatt160.npz');b=np.load(BASE/'data/five_fullframe.npz');items=[]
 raw_bccd={}
 for split in ['train','val','test']:
  wr=wm['splits'][split]['records'];keep=range(len(wr)) if split!='test' else qa['test_keep_indices']
  wx,wb,wn,wc=(w[split+s] for s in ['_x','_boxes','_n','_classes'])
  for i in keep:
   r=wr[i];parent=r.get('parent',r['name']);items.append({'source':'WBCAtt','split':split,'parent':'WBCAtt:'+parent,'name':r['name'],'kind':r['kind'],'raw_hash':r.get('pixel_sha256'),
    'x':wx[i],'boxes':wb[i],'n':int(wn[i]),'classes':wc[i]})
  bx,bb,bn,bc,bd=(b[split+s] for s in ['_x','_boxes','_n','_classes','_domain'])
  records=[r for r in bm['sources'] if r['split']==split];ids=np.flatnonzero(bd==0)
  assert len(records)==len(bx)
  for i in ids:
   r=records[i];assert r['source']=='BCCD' and (bc[i]==-1).all()
   parent=r['name'].split(':')[0]
   if parent not in raw_bccd:
    p=BASE/'data/BCCD_Dataset/BCCD/JPEGImages'/parent
    with Image.open(p) as im:raw_bccd[parent]=hashlib.sha256(np.asarray(im.convert('RGB')).tobytes()).hexdigest()
   items.append({'source':'BCCD','split':split,'parent':'BCCD:'+parent,'name':r['name'],'kind':'derived_negative' if 'crop' in r else 'original','raw_hash':raw_bccd[parent] if 'crop' not in r else None,
    'x':bx[i],'boxes':bb[i],'n':int(bn[i]),'classes':bc[i]})
 groups=defaultdict(list);parents=defaultdict(set)
 for i,r in enumerate(items):
  r['input_hash']=hashlib.sha256(r['x'].tobytes()).hexdigest();groups['input:'+r['input_hash']].append(i);parents[r['parent']].add(r['split'])
  if r['raw_hash']:groups['raw:'+r['raw_hash']].append(i)
 assert all(len(v)==1 for v in parents.values())
 excluded={};duplicates=[];priority={'test':0,'val':1,'train':2}
 for key,ids in groups.items():
  if len({items[i]['split'] for i in ids})<=1:continue
  ids=sorted(ids,key=lambda i:(priority[items[i]['split']],items[i]['parent'],items[i]['name']))
  winner=items[ids[0]];duplicates.append({'kind':key[:key.index(':')],'kept_parent':winner['parent'],'members':[{'parent':items[i]['parent'],'split':items[i]['split'],'name':items[i]['name']} for i in ids]})
  for i in ids[1:]:
   if items[i]['split']!=winner['split']:excluded[items[i]['parent']]='cross_split_exact_duplicate_parent'
 kept=[r for r in items if r['parent'] not in excluded];arrays={};manifest={'sources':['WBCAtt','BCCD'],'no_Raabin_rows':True,'BCCD_no_five_class_labels':True,
  'source_npz_sha256':{'WBCAtt':wm['npz_sha256'],'BCCD_filtered_from_frozen_cache':bm['npz_sha256']},
  'WBCAtt_quality_exclusions':qa['test_excluded_ambiguous_parents'],'parent_exclusions':excluded,'cross_split_duplicate_groups_before_exclusion':duplicates,'splits':{}}
 seen={}
 for split in ['train','val','test']:
  rows=[r for r in kept if r['split']==split];arrays[split+'_x']=np.stack([r['x'] for r in rows]);arrays[split+'_boxes']=np.stack([r['boxes'] for r in rows]);arrays[split+'_classes']=np.stack([r['classes'] for r in rows]);arrays[split+'_n']=np.array([r['n'] for r in rows],np.int64);arrays[split+'_domain']=np.array([int(r['source']=='WBCAtt') for r in rows],np.int64)
  for row in rows:
   assert row['input_hash'] not in seen or seen[row['input_hash']]==split
   seen[row['input_hash']]=split
  records=[{k:v for k,v in row.items() if k not in ['x','boxes','classes']} for row in rows]
  stats={src:{'original_images':sum(z['source']==src and z['kind']=='original' for z in rows),'derived_negatives':sum(z['source']==src and z['kind']!='original' for z in rows),'positive_images':sum(z['source']==src and z['n']>0 for z in rows),'objects':sum(z['n'] for z in rows if z['source']==src)} for src in ['WBCAtt','BCCD']}
  stats['WBCAtt_by_class']=dict(Counter(int(z['classes'][0]) for z in rows if z['source']=='WBCAtt' and z['n']>0));manifest['splits'][split]={'stats':stats,'records':records}
 np.savez(out,**arrays);manifest['npz_sha256']=sha(out);manifest['cross_split_actual_RGB160_duplicates_after_exclusion']=0;manifest['TEST_performance_used']=False
 save(HOME/'data_manifest.json',manifest);print('TWO_SOURCE_DATA_READY',json.dumps({s:m['stats'] for s,m in manifest['splits'].items()}),flush=True)
if __name__=='__main__':main()

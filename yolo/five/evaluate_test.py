"""After selection freeze, evaluate official TestA boxes/types and BCCD TEST."""
import hashlib,json,sys
from pathlib import Path
import numpy as np
import torch
from PIL import Image
BASE=Path(__file__).resolve().parents[1];sys.path.insert(0,str(BASE))
from model import Detector
from export import integer
from five.prepare import OLD,CLASSES,sample
from five.calibrate import logits,metrics
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 selection=json.loads((BASE/'five/model_selection.json').read_text());name=selection['selected']['run'];run=BASE/'runs'/name
 assert 'exact integer' in selection['criterion']
 assert selection['selected']['checkpoint_sha256']==sha(run/'detector.pt')
 confidence=json.loads((run/'integer_validation.json').read_text());threshold=confidence['selected']['score_q16']
 assert threshold==selection['selected']['integer_confidence']['score_q16']
 p=json.loads((run/'protocol.json').read_text());frozen_files=['detector.pt','quantized.npz','protocol.json','integer_validation.json']
 hashes={n:sha(run/n) for n in frozen_files};hashes['model_selection.json']=sha(BASE/'five/model_selection.json')
 old_manifest=json.loads((run/'data_manifest.json').read_text(encoding='utf8'))
 groups={r['source_group'] for r in old_manifest['sources'] if r['source']=='Raabin_train'}
 train_hashes={r['sha256'] for r in old_manifest['sources'] if r['source']=='Raabin_train'}
 # Define every test item and group exclusion before opening mask contents.
 pairs=[]
 for c,category in enumerate(CLASSES):
  folder=OLD/'data/raabin_gt/GrTh/Ground Truth'/category
  for mp in sorted(folder.glob('*')):
   ip=OLD/'data/raabin/TestA'/category/mp.name
   if not ip.is_file():continue
   group=mp.stem.rsplit('_',1)[0]
   pairs.append({'image':str(ip),'mask':str(mp),'class_id':c,'source_group':group,'overlap_with_TRAIN_or_VAL_group':group in groups})
 assert len(pairs)==228,'Unexpected official TestA mask pairing inventory'
 (run/'five_test_partition.json').write_text(json.dumps({'selection_sha256':hashes['model_selection.json'],'pairs':pairs,'rule':'report all official TestA pairs and acquisition-group-disjoint subset'},indent=2))
 images=[];boxes=[];labels=[];disjoint=[]
 for i,r in enumerate(pairs):
  ip,mp=Path(r['image']),Path(r['mask']);r['image_sha256']=sha(ip);r['mask_sha256']=sha(mp)
  r['exact_image_seen_in_TRAIN_or_VAL']=r['image_sha256'] in train_hashes
  with Image.open(mp) as im:m=np.asarray(im.convert('RGB')).max(2)>32
  yy,xx=np.where(m);assert len(xx)
  with Image.open(ip) as im:a,b=sample(im,[[xx.min(),yy.min(),xx.max()+1,yy.max()+1]],'fullframe')
  images.append(a);boxes.append(b[0]);labels.append(r['class_id'])
  if not r['overlap_with_TRAIN_or_VAL_group'] and not r['exact_image_seen_in_TRAIN_or_VAL']:disjoint.append(i)
 count=len(images);test={'test_x':np.stack(images),'test_boxes':np.zeros((count,8,4),np.float32),'test_classes':np.full((count,8),-1,np.int64),'test_n':np.ones(count,np.int64),'test_domain':np.ones(count,np.int64)}
 test['test_boxes'][:,0]=boxes;test['test_classes'][:,0]=labels
 model=Detector(.075,160,5,p.get('wide_head',False)).cuda();model.enable_qat()
 model.load_state_dict(torch.load(run/'detector.pt',weights_only=False,map_location='cuda')['state']);model.eval()
 torch.backends.cuda.matmul.allow_tf32=False;torch.backends.cudnn.allow_tf32=False
 raw=logits(model,test['test_x']);q=np.load(run/'quantized.npz')
 exact_ids=[]
 for c in range(5):exact_ids.append(int(np.flatnonzero(np.array(labels)==c)[0]))
 for i in exact_ids:
  reference,_=integer(test['test_x'][i],q);assert np.array_equal(reference,raw[i]),'Official TEST QAT/NumPy mismatch'
 result,pred=metrics(raw,test,'test',threshold)
 subset={k:v[disjoint] for k,v in test.items()};strict,_=metrics([raw[i] for i in disjoint],subset,'test',threshold)
 bccd=np.load(BASE/'data'/p['data_file']);braw=logits(model,bccd['test_x']);bresult,bpred=metrics(braw,bccd,'test',threshold)
 assert hashes=={**{n:sha(run/n) for n in frozen_files},'model_selection.json':sha(BASE/'five/model_selection.json')},'Frozen model changed during TEST'
 report={'model':name,'frozen_sha256':hashes,'threshold_q16':threshold,'five_class_TEST_opened_after_integer_selection':True,
 'official_TestA_mask_pairs':count,'group_disjoint_pairs':len(disjoint),'image_group_overlap_count':count-len(disjoint),
 'exact_duplicate_images':sum(r['exact_image_seen_in_TRAIN_or_VAL'] for r in pairs),
 'official_TestA':result,'group_disjoint_TestA':strict,'BCCD_TEST':bresult,'numpy_QAT_exact_TestA_vectors':len(exact_ids),
 'limitations':['Raabin acquisition-group disjoint is not verified patient independence','TestA paired masks are a 228-image subset, not the full classification dataset',
 'BCCD has no five-class labels; its TEST was already evaluated in the preceding one-class experiment','Live camera and HDMI are not validated'],
 'pairs':pairs,'predictions_TestA':pred,'predictions_BCCD':bpred}
 (run/'five_class_test_result.json').write_text(json.dumps(report,indent=2))
 print('FIVE_TEST_RESULT',json.dumps({k:v for k,v in report.items() if k not in ['frozen_sha256','pairs','predictions_TestA','predictions_BCCD']}),flush=True)
if __name__=='__main__':main()

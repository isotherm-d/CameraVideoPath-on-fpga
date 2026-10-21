"""Independent detection confidence for partially class-annotated training data."""
import numpy as np
from export import decode_int as original_decode,SIG
def decode_int(logits,geometry='center640',return_classes=False):
 b,_,c=original_decode(logits,geometry,True);fields=logits.shape[0]//3
 raw=logits.transpose(1,2,0).reshape(10,10,3,fields).astype(np.int64)
 obj=SIG[np.clip((raw[...,4]>>4)+128,0,255)].ravel()*255
 return (b,obj,c) if return_classes else (b,obj)
def predict(logits,threshold):
 b,s,c=decode_int(logits,'fullframe',True);ids=np.flatnonzero((s>=threshold)&(b[:,0]<b[:,2])&(b[:,1]<b[:,3]));ids=ids[np.argsort(-s[ids],kind='stable')[:20]];keep=[]
 while len(ids) and len(keep)<5:
  k=int(ids[0]);keep.append(k);ids=ids[1:];inter=np.maximum(np.minimum(b[k,2:],b[ids,2:])-np.maximum(b[k,:2],b[ids,:2]),0).prod(1);union=(b[k,2:]-b[k,:2]).prod()+(b[ids,2:]-b[ids,:2]).prod(1)-inter;ids=ids[inter*256<=union*103]
 return b[keep],s[keep],c[keep]

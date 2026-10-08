"""Offline integer contour reference, also used for fixed-frame comparisons."""
import numpy as np

def windows(array):
    padded=np.pad(array,1,mode='edge')
    h,w=array.shape
    return [padded[y:y+h,x:x+w] for y in range(3) for x in range(3)]

def contour(image,low,high,width=1,sketch=False):
    rgb=np.asarray(image,dtype=np.int32)
    y=(77*rgb[:,:,0]+150*rgb[:,:,1]+29*rgb[:,:,2]+128)//256
    a=windows(y)
    smooth=(sum(weight*part for weight,part in zip((1,2,1,2,4,2,1,2,1),a))+8)//16
    a=windows(smooth)
    gx=a[2]+2*a[5]+a[8]-a[0]-2*a[3]-a[6]
    gy=a[6]+2*a[7]+a[8]-a[0]-2*a[1]-a[2]
    mag=np.abs(gx)+np.abs(gy)
    strong=mag>=high;weak=mag>=low
    nearby_strong=np.logical_or.reduce([p for n,p in enumerate(windows(strong)) if n!=4])
    nearby_candidate=np.logical_or.reduce([p for n,p in enumerate(windows(weak)) if n!=4])
    connected=np.where(strong&nearby_candidate,2,np.where(weak&nearby_strong,1,0))
    if width==2:connected=np.maximum.reduce(windows(connected))
    out=np.where(connected==2,0,np.where(connected==1,96,255)) if sketch else np.where(connected>0,255,0)
    return np.repeat(out[:,:,None],3,axis=2).astype(np.uint8)

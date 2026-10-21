"""Fixed-scene V27 threshold/AWB/I2C checks and rotating-mode reception test."""
import argparse,json,time
from pathlib import Path
import numpy as np
from validate_v26_board import Harness
from v27_client import V27Control

def main():
    p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True)
    p.add_argument('--stress-seconds',type=int,default=300);args=p.parse_args()
    args.output.mkdir(parents=True,exist_ok=True)
    h=Harness(V27Control);records={};started=time.monotonic()
    def shot(name,wait=1):
        records[name]=h.capture(args.output/(name+'.png'),wait)
        with h.lock:image=h.frame.copy()
        records[name]['edge_fraction']=float(np.mean(image[:,:,0]>0))
        records[name]['flat_box_fraction']=float(np.mean(image[250:400,150:420,0]>0))
        print(json.dumps({'capture':name,'frame':records[name]['status']['frame_id'],'complete':h.complete}),flush=True)
        return image
    try:
        deadline=time.monotonic()+12
        while time.monotonic()<deadline:
            state=h.control.snapshot()
            if state and state.get('firmware')==27 and state['diag_flags']&8:break
            time.sleep(.1)
        state=h.control.snapshot();assert state and state.get('firmware')==27,'No V27 extension'
        records['boot']=state
        assert not state['diag_flags']&1,('Initialization failed',state)
        assert not state['flags']&48,('Startup stream/sensor error',state)
        h.apply({0:0,1:0,2:0,3:1800,4:80,9:0,10:0,11:0})
        preset=shot('preset',2)
        for high in (190,90,60):
            h.apply({0:3,13:high//2,14:high,17:1});shot(f'edge_{high}')
        assert records['edge_190']['edge_fraction']<records['edge_90']['edge_fraction']<records['edge_60']['edge_fraction'],'Threshold response'
        h.apply({13:45,14:90,17:2});shot('edge_thick')
        assert records['edge_thick']['edge_fraction']>records['edge_90']['edge_fraction'],'Stroke control'
        h.apply({0:5,15:50,16:100,18:1});shot('sketch')
        state=h.control.snapshot()
        assert (state['edge_low'],state['edge_high'],state['edge_width'])==(45,90,2)
        assert (state['sketch_low'],state['sketch_high'],state['sketch_width'])==(50,100,1)
        h.apply({0:0,2:3});auto=shot('auto',4)
        state=h.control.snapshot()
        assert 327<=state['gain_r']<=361 and 428<=state['gain_b']<=474,('Preset anchored AWB',state)
        assert not state['flags']&48 and not state['diag_flags']&7
        records['awb_vs_preset']={'mean_rgb_preset':preset.mean(axis=(0,1)).tolist(),'mean_rgb_auto':auto.mean(axis=(0,1)).tolist()}
        h.apply({1:1});shot('ae_auto',3)
        h.apply({13:45,14:90,17:1,15:50,16:100,18:1,11:1})
        begin=time.monotonic();first=h.count;last_progress=begin;last_switch=begin;mode=0
        while time.monotonic()-begin<args.stress_seconds:
            time.sleep(.25);state=h.control.snapshot()
            assert state and time.monotonic_ns()-state['received_ns']<2_000_000_000,'Status stale'
            assert not state['flags']&48 and not state['diag_flags']&7,('Runtime error',state)
            if time.monotonic()-last_switch>=10:
                mode=(mode+1)%7;h.apply({0:mode});last_switch=time.monotonic()
            if time.monotonic()-last_progress>=30:
                print(json.dumps({'stress_seconds':round(time.monotonic()-begin),'frames':h.count-first,'complete':h.complete,'mode':mode}),flush=True);last_progress=time.monotonic()
        elapsed=time.monotonic()-begin;fps=(h.count-first)/elapsed
        records['stress']={'seconds':elapsed,'frames':h.count-first,'fps':fps,'complete':h.complete,'modes_rotated':7,'ae':True,'awb':True}
        assert 29<=fps<=30.5 and h.complete>=99.9,records['stress']
        h.apply({0:0,1:1,2:0,10:1,11:1});records['restored']=h.control.snapshot()
        records['passed']=True
    except Exception as error:
        records['passed']=False;records['error']=str(error);raise
    finally:
        records['total_seconds']=time.monotonic()-started
        (args.output/'hardware_validation.json').write_text(json.dumps(records,ensure_ascii=False,indent=2),encoding='utf-8')
        h.close()
if __name__=='__main__':main()

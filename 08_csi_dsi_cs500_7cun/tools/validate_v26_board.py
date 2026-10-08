"""V26 SRAM hardware checks; saves personal scene frames only to the chosen output."""
import argparse,json,socket,threading,time
from pathlib import Path
import numpy as np
from PIL import Image
from frame_tools import FrameAssembler
from v26_client import V26Control

class Harness:
    def __init__(self):
        self.control=V26Control()
        self.sock=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET,socket.SO_RCVBUF,64<<20)
        self.sock.bind(("",6000));self.sock.settimeout(.2)
        self.lock=threading.Lock();self.frame=None;self.sequence=None;self.stamp=0;self.count=0;self.complete=0
        self.run=True
        threading.Thread(target=self.receive,daemon=True).start()
    def receive(self):
        a=FrameAssembler()
        while self.run:
            try:p,addr=self.sock.recvfrom(65536)
            except socket.timeout:continue
            except OSError:return
            if addr[0]!="192.168.1.66":continue
            now=time.monotonic_ns();image=a.accept(p,now/1e9)
            if image is not None:
                with self.lock:self.frame=image;self.sequence=a.sequence;self.stamp=now;self.count+=1;self.complete=a.complete_percent
    def apply(self,changes):
        old=self.control.snapshot()
        if old is None:raise RuntimeError("No v26 status")
        previous=old["cfg_id"];self.control.configure(changes)
        end=time.monotonic()+6
        while time.monotonic()<end:
            current=self.control.snapshot()
            if current and current["cfg_id"]!=previous and "已在帧首生效" in self.control.notice:
                return current
            if "失败" in self.control.notice:raise RuntimeError(self.control.notice)
            time.sleep(.02)
        raise TimeoutError(self.control.notice)
    def capture(self,path,wait=1):
        time.sleep(wait)
        with self.lock:
            if self.frame is None:raise RuntimeError("No complete RGB frames")
            f=self.frame.copy();seq=self.sequence;stamp=self.stamp
        if time.monotonic_ns()-stamp>1_000_000_000:raise RuntimeError("Camera stopped")
        state=self.control.snapshot()
        if state["flags"]&32:raise RuntimeError(f"Frame integrity fault: {state}")
        Image.fromarray(f).save(path)
        metadata=self.control.frame_metadata(seq,stamp)
        roi=f[40:680,600:1240].mean(axis=(0,1))
        return {"status":state,"metadata":metadata,"roi_mean_rgb":roi.tolist(),"complete":self.complete}
    def close(self):
        self.run=False;self.sock.close();self.control.close()

def main():
    p=argparse.ArgumentParser();p.add_argument("--output",type=Path,required=True)
    p.add_argument("--stress-seconds",type=int,default=60);args=p.parse_args()
    args.output.mkdir(parents=True,exist_ok=True)
    h=Harness();results={};started=time.monotonic()
    try:
        deadline=time.monotonic()+10
        while h.control.snapshot() is None and time.monotonic()<deadline:time.sleep(.1)
        if h.control.snapshot() is None:raise RuntimeError("UDP6002 status not received")
        h.apply({0:0,1:0,2:0,3:500,4:108,9:0,10:0,11:0})
        for mode in range(7):
            h.apply({0:mode})
            results[f"mode_{mode}"]=h.capture(args.output/f"mode_{mode}.png",.7)
            assert results[f"mode_{mode}"]["status"]["mode"]==mode
            print(json.dumps({"mode":mode,"frames":h.count,"complete":h.complete}),flush=True)
        h.apply({0:0,1:0,2:2,3:300,6:256,7:256,8:256})
        results["unit_gain"]=h.capture(args.output/"unit_gain.png")
        h.apply({6:128})
        results["red_half"]=h.capture(args.output/"red_half.png")
        ratio=results["red_half"]["roi_mean_rgb"][0]/results["unit_gain"]["roi_mean_rgb"][0]
        assert .4<ratio<.65,("manual red gain",ratio)
        h.apply({2:3,1:1})
        results["awb"]=h.capture(args.output/"awb.png",3)
        assert results["awb"]["status"]["wb_mode"]==3
        assert all(128<=results["awb"]["status"][k]<=1024 for k in ("gain_r","gain_g","gain_b"))
        h.apply({1:1})
        results["ae_awb"]=h.capture(args.output/"ae_awb.png",3)
        assert results["ae_awb"]["status"]["flags"]&1
        h.apply({10:1})
        results["tone"]=h.capture(args.output/"tone.png")
        h.apply({0:0,1:0,2:0,3:500,4:108,9:0,10:0,11:1})
        results["restored"]=h.capture(args.output/"restored.png")
        begin=time.monotonic();start_count=h.count;deadline=begin+args.stress_seconds;last_progress=begin
        while time.monotonic()<deadline:
            time.sleep(1)
            state=h.control.snapshot()
            assert state and time.monotonic_ns()-state["received_ns"]<2_000_000_000
            assert not state["flags"]&32,("stream error",state)
            assert not state["flags"]&16,("I2C error",state)
            if time.monotonic()-last_progress>=60:
                print(json.dumps({"stress_seconds":round(time.monotonic()-begin),"frames":h.count-start_count,"complete":h.complete}),flush=True)
                last_progress=time.monotonic()
        elapsed=time.monotonic()-begin
        fps=(h.count-start_count)/elapsed
        results["stress"]={"seconds":elapsed,"frames":h.count-start_count,"fps":fps,"complete":h.complete}
        assert 29<=fps<=30.5,("30fps requirement",fps)
        assert h.complete>=99.9,("complete frames",h.complete)
        results["passed"]=True
    except Exception as error:
        results["passed"]=False;results["error"]=str(error)
        raise
    finally:
        results["total_seconds"]=time.monotonic()-started
        (args.output/"hardware_validation.json").write_text(json.dumps(results,indent=2,ensure_ascii=False),encoding="utf-8")
        h.close()

if __name__=="__main__":main()

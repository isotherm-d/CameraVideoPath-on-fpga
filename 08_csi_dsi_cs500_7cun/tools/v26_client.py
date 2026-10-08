"""V26 acknowledged configuration, telemetry and explicit latency time mapping."""
import collections
import queue
import socket
import threading
import time
from v26_protocol import command, status

class ClockMapping:
    def __init__(self):
        self.samples=collections.deque(maxlen=16)
    def reset(self):
        self.samples.clear()
    def add(self,t1,t2,t3,t4):
        rtt=(t4-t1)-(t3-t2)*10
        if rtt<0 or rtt>1_000_000_000:
            return
        offset=((t1+t4)-(t2+t3)*10)/2
        self.samples.append((rtt,offset,t4))
    def map(self,board_tick,now_ns):
        fresh=[x for x in self.samples if now_ns-x[2]<10_000_000_000]
        if not fresh:
            return None
        best=min(fresh)
        # RTT/2 covers unknown asymmetry. Add packet scheduling and empirical drift.
        drift=max((abs(x[1]-best[1]) for x in fresh),default=0)
        return board_tick*10+best[1],(best[0]/2+50_000+drift)/1e6

class V26Control:
    parse_status=staticmethod(status)
    LIMITS=((0,6),(0,1),(0,3),(62,1800),(16,143),(25,100),
            (64,1024),(64,1024),(64,1024),(0,1),(0,1),(0,1),
            (0,255),(0,2040),(0,2040))
    def __init__(self,target=("192.168.1.255",6001)):
        self.target=target
        self.tx=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
        self.tx.setsockopt(socket.SOL_SOCKET,socket.SO_BROADCAST,1)
        self.rx=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
        if hasattr(socket,"SO_EXCLUSIVEADDRUSE"):
            self.rx.setsockopt(socket.SOL_SOCKET,socket.SO_EXCLUSIVEADDRUSE,1)
        self.rx.bind(("",6002))
        self.rx.settimeout(.1)
        self.cv=threading.Condition()
        self.latest=None
        self.frames=collections.OrderedDict()
        self.results=collections.OrderedDict()
        self.transmitted=collections.OrderedDict()
        self.clock=ClockMapping()
        self.req=time.monotonic_ns()&65535
        self.running=True
        self.error=""
        self.notice="等待 v26 板端状态"
        self.jobs=queue.Queue()
        self.sync_sent={}
        self.previous_tick=None
        self.threads=[
            threading.Thread(target=self.receive,daemon=True),
            threading.Thread(target=self.work,daemon=True)]
        for t in self.threads:
            t.start()

    def receive(self):
        while self.running:
            try:
                packet,address=self.rx.recvfrom(65536)
                stamp=time.monotonic_ns()
            except socket.timeout:
                continue
            except OSError as error:
                if self.running:
                    self.error=str(error)
                return
            if address[0]!="192.168.1.66":
                continue
            parsed=self.parse_status(packet)
            if parsed is None:
                continue
            parsed["received_ns"]=stamp
            with self.cv:
                if self.previous_tick is not None and parsed["snapshot_tick"]<self.previous_tick:
                    self.frames.clear();self.results.clear();self.transmitted.clear();self.clock.reset();self.sync_sent.clear()
                self.previous_tick=parsed["snapshot_tick"]
                self.latest=parsed
                if parsed["tx_frame_id"]!=0xffffffff:
                    self.transmitted[parsed["tx_frame_id"]]=parsed["tx_tick"]
                    while len(self.transmitted)>64:self.transmitted.popitem(last=False)
                if parsed["frame_id"]!=0xffffffff:
                    self.frames[parsed["frame_id"]]=parsed
                    while len(self.frames)>32:
                        self.frames.popitem(last=False)
                sid=parsed["sync_id"]
                if sid in self.sync_sent:
                    sent=self.sync_sent.pop(sid)
                    self.clock.add(sent,parsed["sync_rx_tick"],parsed["snapshot_tick"],stamp)
                if parsed["result_valid"]&1:
                    key=(parsed["result_frame"],parsed["result_roi"])
                    self.results[key]=parsed
                    while len(self.results)>64:
                        self.results.popitem(last=False)
                self.cv.notify_all()

    def snapshot(self):
        with self.cv:
            return None if self.latest is None else dict(self.latest)

    def frame_metadata(self,sequence,completed_ns):
        with self.cv:
            candidates=[dict(p) for fid,p in self.frames.items()
                        if (fid&255)==sequence and abs(p["received_ns"]-completed_ns)<500_000_000]
        if not candidates:
            return None
        chosen=max(candidates,key=lambda p:p["received_ns"])
        with self.cv:
            sent=self.transmitted.get(chosen["frame_id"])
        if sent is not None:
            chosen["matched_tx_tick"]=sent
        return chosen

    def inference_results(self,fid):
        with self.cv:
            return [dict(p) for (frame,roi),p in self.results.items() if frame==fid]

    def estimated_submission(self,metadata,submit_ns):
        with self.cv:
            mapped=self.clock.map(metadata["capture_tick"],submit_ns)
        if mapped is None:
            return None
        capture_ns,error_ms=mapped
        delay=(submit_ns-capture_ns)/1e6
        return (delay,error_ms) if delay>=-error_ms else None

    def next_request(self):
        self.req=(self.req+1)&65535
        return self.req

    def request(self,cfg,op,addr=0,value=0,applied=False):
        req=self.next_request()
        packet=command(req,cfg,op,addr,value)
        for attempt in range(3):
            sent_ns=time.monotonic_ns()
            self.tx.sendto(packet,self.target)
            deadline=time.monotonic()+.5
            with self.cv:
                while self.running and time.monotonic()<deadline:
                    current=self.latest
                    if current and current["reply_req"]==req and current["received_ns"]>=sent_ns:
                        code=current["reply_status"]
                        if code in (3,4):
                            raise RuntimeError(f"板端状态 {code}：req={req} cfg={cfg} op={op} addr={addr} value={value}")
                        if not applied or code==2:
                            return dict(current)
                    self.cv.wait(.05)
        raise TimeoutError("板端未确认生效；请检查比特流、网线和 UDP6002")

    def configure(self,changes):
        self.jobs.put(dict(changes))
        self.notice="配置待提交"
    def apply_once(self,changes):
        current=self.snapshot()
        if current is None:
            raise RuntimeError("尚未收到 v26 状态，未发送配置")
        cfg=(current["cfg_id"]+1)&65535
        for addr,value in changes.items():
            self.request(cfg,1,int(addr),int(value))
        confirmed=self.request(cfg,2,applied=True)
        for addr,value in changes.items():
            readback=self.request(cfg,3,int(addr))
            if readback["reply_value"]!=int(value):
                raise RuntimeError(f"参数 {addr} 回读不一致：请求 {value}，板端 {readback['reply_value']}")
        self.notice=f"配置 {confirmed['cfg_id']} 已在帧首生效"
        return confirmed

    def apply(self,changes):
        limits=self.LIMITS
        for addr,value in changes.items():
            if not 0<=int(addr)<len(limits) or not limits[int(addr)][0]<=int(value)<=limits[int(addr)][1]:
                raise ValueError(f"参数 {addr} 超出合法范围")
        last=None
        for attempt in range(3):
            try:
                return self.apply_once(changes)
            except (RuntimeError,TimeoutError) as error:
                last=error
                time.sleep(.1)
        raise last

    def work(self):
        next_sync=0
        while self.running:
            try:
                changes=self.jobs.get(timeout=.1)
            except queue.Empty:
                changes=None
            if changes is not None:
                try:
                    self.notice="等待板端确认…"
                    self.apply(changes)
                except (OSError,RuntimeError,TimeoutError,ValueError) as error:
                    self.notice=f"配置失败：{error}"
            if time.monotonic()>=next_sync and self.snapshot() is not None:
                try:
                    req=self.next_request()
                    with self.cv:
                        self.sync_sent[req]=time.monotonic_ns()
                        while len(self.sync_sent)>8:
                            self.sync_sent.pop(next(iter(self.sync_sent)))
                    self.tx.sendto(command(req,0,4),self.target)
                except OSError as error:
                    self.error=str(error)
                next_sync=time.monotonic()+2

    def close(self):
        self.running=False
        with self.cv:
            self.cv.notify_all()
        self.rx.close();self.tx.close()

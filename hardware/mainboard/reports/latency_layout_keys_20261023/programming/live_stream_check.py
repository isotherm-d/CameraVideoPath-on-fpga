"""Read-only post-download video/telemetry check; no configuration writes."""
from pathlib import Path
import json,socket,sys,time
import numpy as np
REPO=Path(r'C:\Users\cqm87\Desktop\2026\cvp\camera processing unit')
sys.path.insert(0,str(REPO/'hardware/mainboard/tools'))
from frame_tools import FrameAssembler
from v27_protocol import status
out=REPO/'hardware/mainboard/reports/latency_layout_keys_20261023/programming'
video=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
telemetry=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
video.setsockopt(socket.SOL_SOCKET,socket.SO_RCVBUF,64<<20)
video.bind(('',6000));video.settimeout(.05)
telemetry.bind(('',6002));telemetry.setblocking(False)
assembler=FrameAssembler();frames=[];states=[];nonblack=0;measurement_start=None
start=time.monotonic()
try:
    while time.monotonic()-start<12:
        try:
            packet,address=video.recvfrom(65536)
            if address[0]=='192.168.1.66':
                now=time.monotonic()
                if measurement_start is None and now-start>=2 and len(packet)>=6 and packet[1]==1 and int.from_bytes(packet[2:6],'big')==0:
                    assembler=FrameAssembler();measurement_start=now
                frame=assembler.accept(packet,now) if measurement_start is not None else None
                if frame is not None:
                    frames.append(time.monotonic());nonblack+=bool(np.any(frame))
        except socket.timeout:pass
        while True:
            try:
                packet,address=telemetry.recvfrom(65536)
                if address[0]=='192.168.1.66':
                    parsed=status(packet)
                    if parsed and measurement_start is not None:states.append(parsed)
            except BlockingIOError:break
finally:video.close();telemetry.close()
fps=(len(frames)-1)/(frames[-1]-frames[0]) if len(frames)>1 else 0
result={'duration_seconds':time.monotonic()-(measurement_start or start),'warmup_seconds':None if measurement_start is None else measurement_start-start,'frames':len(frames),'nonblack_frames':nonblack,
        'fps':fps,'complete_percent':assembler.complete_percent,'status_packets':len(states),
        'read_only':True,'board_display_mode_validated':False}
if states:
    result.update(stream_error_start=states[0]['stream_errors'],stream_error_end=states[-1]['stream_errors'],
                  sensor_error_start=states[0]['sensor_errors'],sensor_error_end=states[-1]['sensor_errors'],
                  stream_fault_end=bool(states[-1]['flags']&32),latest_frame_id=states[-1]['frame_id'])
result['status']='PASS' if len(frames)>=200 and nonblack==len(frames) and 29<=fps<=31 and assembler.complete_percent>=99.9 and states and not result['stream_fault_end'] and result['stream_error_end']==result['stream_error_start'] else 'NOT_VERIFIED'
(out/'live_stream_check.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
print(json.dumps(result,indent=2))
assert result['status']=='PASS','Live video acceptance not met'



from pathlib import Path
import json,socket,sys,time
REPO=Path(r'C:\Users\cqm87\Desktop\2026\cvp\camera processing unit')
sys.path.insert(0,str(REPO/'hardware/mainboard/tools'))
from v27_client import V27Control
from frame_tools import FrameAssembler
OUT=REPO/'hardware/mainboard/reports/latency_mode_20261022/programming'
control=V27Control()
video=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
video.setsockopt(socket.SOL_SOCKET,socket.SO_RCVBUF,64<<20)
video.bind(('',6000));video.settimeout(.05)
assembler=FrameAssembler();frames=0;records=[];initial=None
def drain():
    global frames
    try:
        packet,address=video.recvfrom(65536)
        if address[0]=='192.168.1.66' and assembler.accept(packet,time.monotonic()) is not None:frames+=1
    except socket.timeout:pass
def set_mode(mode):
    before=control.snapshot();wanted=(before['cfg_id']+1)&65535
    control.configure({0:mode})
    start=time.monotonic();stable=None;first_frame=frames
    while time.monotonic()-start<8:
        drain();state=control.snapshot()
        if '配置失败' in control.notice:raise RuntimeError(control.notice)
        if state and state['cfg_id']==wanted and state['frame_cfg_id']==wanted and state['mode']==mode:
            if stable is None:stable=time.monotonic();first_frame=frames
            if time.monotonic()-stable>=.35 and frames-first_frame>=5:
                assert not state['flags']&32
                record={'requested_mode':mode,'cfg_id':wanted,'frame_cfg_id':state['frame_cfg_id'],'actual_mode':state['mode'],'frame_id':state['frame_id'],'completed_frames_while_stable':frames-first_frame,'stream_errors':state['stream_errors'],'sensor_errors':state['sensor_errors']}
                records.append(record);print(json.dumps(record),flush=True);return
        else:stable=None
    raise TimeoutError(f'Mode {mode} not confirmed: {control.snapshot()}')
error=None
try:
    deadline=time.monotonic()+5
    while control.snapshot() is None and time.monotonic()<deadline:drain()
    initial=control.snapshot();assert initial and initial['firmware']==27
    for mode in range(7):set_mode(mode)
except Exception as exc:error=str(exc)
finally:
    if initial:
        try:set_mode(initial['mode'])
        except Exception as exc:error=(error or '')+' restore: '+str(exc)
    final=control.snapshot();video.close();control.close()
result={'status':'PASS' if not error and len(records)==8 else 'NOT_VERIFIED','initial_mode':None if not initial else initial['mode'],'restored_mode':None if not final else final['mode'],'completed_frames':frames,'modes':records,'error':error,'physical_digit_visual_confirmation':False}
(OUT/'live_mode_check.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
print(json.dumps(result,indent=2),flush=True)
assert result['status']=='PASS',error

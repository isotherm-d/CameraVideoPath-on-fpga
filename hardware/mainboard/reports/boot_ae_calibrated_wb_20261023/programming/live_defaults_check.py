"""Passive video/status acceptance: no configuration or time-sync requests."""
from pathlib import Path
import json,socket,sys,time
import numpy as np
REPO=Path(r'C:\Users\cqm87\Desktop\2026\cvp\camera processing unit')
sys.path.insert(0,str(REPO/'hardware/mainboard/tools'))
from frame_tools import FrameAssembler
from v27_protocol import status
stage=sys.argv[1]
assert stage in ('sram','flash')
out=REPO/'hardware/mainboard/reports/boot_ae_calibrated_wb_20261023/programming'
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
                if frame is not None:frames.append(time.monotonic());nonblack+=bool(np.any(frame))
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
defaults=bool(states) and all(p['firmware']==27 and p['cfg_id']==0 and p['frame_cfg_id']==0 and p['mode']==0 and p['flags']&1 and p['wb_mode']==0 and [p['gain_r'],p['gain_g'],p['gain_b']]==[344,256,451] for p in states)
result={'stage':stage,'duration_seconds':time.monotonic()-(measurement_start or start),
        'frames':len(frames),'nonblack_frames':nonblack,'fps':fps,'complete_percent':assembler.complete_percent,
        'status_packets':len(states),'read_only':True,'host_configuration_sent':False,
        'all_status_packets_match_power_on_defaults':defaults,'cold_boot_validated':False}
if states:
    result.update(stream_error_start=states[0]['stream_errors'],stream_error_end=states[-1]['stream_errors'],
                  sensor_error_start=states[0]['sensor_errors'],sensor_error_end=states[-1]['sensor_errors'],
                  stream_fault_end=bool(states[-1]['flags']&32),first_frame_id=states[0]['frame_id'],latest_frame_id=states[-1]['frame_id'],
                  first_snapshot_tick=states[0]['snapshot_tick'],last_snapshot_tick=states[-1]['snapshot_tick'],
                  exposure_first=states[0]['sensor_exp'],exposure_last=states[-1]['sensor_exp'],mean_last=states[-1]['mean'],
                  cfg_id=states[-1]['cfg_id'],ae_enabled=bool(states[-1]['flags']&1),wb_mode=states[-1]['wb_mode'],
                  calibrated_rgb_q8=[states[-1]['gain_r'],states[-1]['gain_g'],states[-1]['gain_b']])
result['status']='PASS' if len(frames)>=200 and nonblack==len(frames) and 29<=fps<=31 and assembler.complete_percent>=99.9 and defaults and not result['stream_fault_end'] and result['stream_error_end']==result['stream_error_start'] and result['sensor_error_end']==result['sensor_error_start'] else 'NOT_VERIFIED'
(out/f'live_{stage}_defaults.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
print(json.dumps(result,indent=2),flush=True)
assert result['status']=='PASS','Live video/power-on default acceptance not met'

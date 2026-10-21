"""Compatible CV26 prefix, followed by a 64-byte V27 extension."""
import struct
from v26_protocol import status as legacy_status,command,MODE_NAMES
EXT=struct.Struct('>4sBBH5HBBB3x4HBBIBB24x')
assert EXT.size==64
NAMES=('extension_magic','extension_version','extension_flags','extension_reserved',
       'init_errors','init_retries','runtime_nacks','runtime_timeouts','last_register',
       'last_byte','last_error_code','diag_flags','edge_low','edge_high','sketch_low','sketch_high',
       'edge_width','sketch_width','neutral_count','awb_reason','awb_regions')
DEFAULT_PROFILES={3:(45,90,1),5:(50,100,1)}
STREAM=struct.Struct('>4s4B4I')
STREAM_NAMES=('stream_magic','stream_diag_version','stream_error_history',
              'stream_error_last','stream_recovery','stream_bad_groups',
              'stream_bad_frame','stream_bad_pixels','stream_reserved')
STREAM_ERRORS=('RAW组数','RGB帧边界','风格缓存','亮度统计','网口缓存','输出帧长度')

def stream_error_text(mask):
    return '/'.join(name for bit,name in enumerate(STREAM_ERRORS) if mask&(1<<bit)) or '无'
def status(packet):
    parsed=legacy_status(packet)
    if parsed is None:return None
    parsed['firmware']=26
    if packet[134:138]!=b'V27!':return parsed
    fields=dict(zip(NAMES,EXT.unpack(packet[134:198])))
    if fields['extension_version']!=1:return None
    fields['extension_magic']='V27!';parsed.update(fields);parsed['firmware']=27
    if fields['extension_flags']&1:
        parsed['hardware_build']=fields['extension_reserved']>>8
        parsed['ae_target_mean']=fields['extension_reserved']&255
    if packet[174:178]==b'STRM':
        stream=dict(zip(STREAM_NAMES,STREAM.unpack(packet[174:198])))
        if stream['stream_diag_version']==1:
            stream['stream_magic']='STRM';parsed.update(stream)
            if stream['stream_reserved']&255==0xae:
                parsed['ae_digital_gain_q8']=stream['stream_reserved']>>16
                parsed['ae_pid_flags']=(stream['stream_reserved']>>8)&255
    return parsed

def profile_fields(mode,low,high,width):
    if mode not in (3,5):raise ValueError('只有边缘、素描使用轮廓参数')
    if not 1<=low<=high<=2040 or width not in (1,2):raise ValueError('阈值须满足 1≤低阈值≤高阈值≤2040')
    return {13 if mode==3 else 15:int(low),14 if mode==3 else 16:int(high),17 if mode==3 else 18:int(width)}

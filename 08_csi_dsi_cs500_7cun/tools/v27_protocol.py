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
def status(packet):
    parsed=legacy_status(packet)
    if parsed is None:return None
    parsed['firmware']=26
    if packet[134:138]!=b'V27!':return parsed
    fields=dict(zip(NAMES,EXT.unpack(packet[134:198])))
    if fields['extension_version']!=1:return None
    fields['extension_magic']='V27!';parsed.update(fields);parsed['firmware']=27
    return parsed

def profile_fields(mode,low,high,width):
    if mode not in (3,5):raise ValueError('只有边缘、素描使用轮廓参数')
    if not 1<=low<=high<=2040 or width not in (1,2):raise ValueError('阈值须满足 1≤低阈值≤高阈值≤2040')
    return {13 if mode==3 else 15:int(low),14 if mode==3 else 16:int(high),17 if mode==3 else 18:int(width)}

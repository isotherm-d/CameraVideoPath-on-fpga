"""V26 wire protocol. Pixel data retains the V25 UDP6000 six-byte header."""
import struct
CONTROL_MAGIC=bytes.fromhex("c5a55002")
STATUS_MAGIC=b"CV26"
MODE_NAMES=("原图","灰度","二值化","边缘","卡通","素描","复古暖色")
FIELDS=[["magic","4s"],["version","B"],["mode","B"],["wb_mode","B"],["flags","B"],["frame_id","I"],["cfg_id","H"],["reply_req","H"],["reply_status","B"],["sensor_gain","B"],["sensor_exp","H"],["gain_r","H"],["gain_g","H"],["gain_b","H"],["width","H"],["height","H"],["fps","H"],["mean","B"],["black","B"],["white","B"],["awb_state","B"],["capture_tick","Q"],["process_delta","I"],["eof_delta","I"],["snapshot_tick","Q"],["sync_rx_tick","Q"],["sync_id","H"],["reserved","H"],["stream_errors","I"],["sensor_errors","I"],["tx_frame_id","I"],["tx_tick","Q"],["result_valid","B"],["result_class","B"],["result_roi","H"],["result_frame","I"],["result_bbox","Q"],["result_score","i"],["result_tick","Q"],["frame_cfg_id","H"],["reply_value","I"],["padding","2s"]]
STATUS_STRUCT=struct.Struct(">"+ "".join(fmt for _,fmt in FIELDS))
assert STATUS_STRUCT.size==128
def command(req,cfg,op,addr=0,value=0):
    if not (0<=req<=65535 and 0<=cfg<=65535 and 0<=op<=255 and 0<=addr<=255 and 0<=value<=0xffffffff):
        raise ValueError("Control field out of range")
    return CONTROL_MAGIC+struct.pack(">HHBBHI",req,cfg,op,addr,0,value)
def status(packet):
    if len(packet)!=1446 or packet[1]!=0x26:
        return None
    fields=dict(zip((name for name,_ in FIELDS),STATUS_STRUCT.unpack(packet[6:134])))
    if fields["magic"]!=STATUS_MAGIC or fields["version"]!=1:
        return None
    fields.pop("padding")
    fields["magic"]="CV26"
    fields["process_tick"]=fields["capture_tick"]+fields["process_delta"]
    fields["eof_tick"]=fields["capture_tick"]+fields["eof_delta"]
    return fields

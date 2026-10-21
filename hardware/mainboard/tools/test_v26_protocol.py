import struct,time,unittest
from v26_protocol import FIELDS,STATUS_STRUCT,command,status
from v26_client import ClockMapping
def packet(**updates):
    data={n:(b"\0"*int(f[:-1]) if f.endswith("s") else 0) for n,f in FIELDS}
    data.update(magic=b"CV26",version=1,frame_id=42,capture_tick=100000,process_delta=1000,eof_delta=2000)
    data.update(updates)
    payload=STATUS_STRUCT.pack(*(data[n] for n,_ in FIELDS))
    return bytes((0,0x26))+bytes(4)+payload+bytes(1440-128)
class ProtocolTests(unittest.TestCase):
    def test_control_fields(self):
        p=command(0xabcd,0x1234,1,6,1024)
        self.assertEqual(len(p),16)
        self.assertEqual(p[:4],bytes.fromhex("c5a55002"))
        self.assertEqual(struct.unpack(">HHBBHI",p[4:]),(0xabcd,0x1234,1,6,0,1024))
    def test_reject_out_of_range(self):
        for args in ((65536,0,1,0,0),(0,0,256,0,0),(0,0,1,0,-1)):
            with self.assertRaises(ValueError):command(*args)
    def test_status_and_signed_score(self):
        s=status(packet(result_score=-123,result_valid=1))
        self.assertEqual(s["frame_id"],42)
        self.assertEqual(s["process_tick"],101000)
        self.assertEqual(s["eof_tick"],102000)
        self.assertEqual(s["result_score"],-123)
    def test_malformed_status(self):
        self.assertIsNone(status(packet()[:-1]))
        p=bytearray(packet());p[6]=0;self.assertIsNone(status(p))
        p=bytearray(packet());p[1]=1;self.assertIsNone(status(p))
    def test_clock_mapping_with_board_processing(self):
        m=ClockMapping()
        m.add(1_000_000_000,50_100_000,50_200_000,1_003_000_000)
        mapped,error=m.map(50_000_000,1_020_000_000)
        self.assertEqual(mapped,1_000_000_000)
        self.assertGreaterEqual(error,1.)
        self.assertIsNone(m.map(50_000_000,20_000_000_000))
        m.reset();self.assertIsNone(m.map(50_000_000,1_020_000_000))
    def test_reject_invalid_sync(self):
        m=ClockMapping();m.add(100,10000,20000,200)
        self.assertFalse(m.samples)
if __name__=="__main__":unittest.main()

import unittest
import numpy as np
from v26_protocol import FIELDS,STATUS_STRUCT,status as old_status
from v27_protocol import EXT,NAMES,STREAM,status,profile_fields,stream_error_text
from v27_reference import contour

def packet(extended=True,version=1):
    values=[]
    for name,fmt in FIELDS:
        value=b'CV26' if name=='magic' else b'\0\0' if name=='padding' else 1 if name=='version' else 0
        values.append(value)
    data=bytearray(b'\0\x26'+b'\0'*4+STATUS_STRUCT.pack(*values)+b'\0'*(1440-128))
    if extended:
        fields=dict.fromkeys(NAMES,0)
        fields.update(extension_magic=b'V27!',extension_version=version,init_errors=1,init_retries=1,
                      last_register=0x0100,last_byte=4,last_error_code=1,diag_flags=88,
                      edge_low=45,edge_high=90,sketch_low=50,sketch_high=100,edge_width=1,sketch_width=2,neutral_count=10000)
        data[134:198]=EXT.pack(*(fields[name] for name in NAMES))
    return bytes(data)

class WireTests(unittest.TestCase):
    def test_stream_diagnostics_reserved_extension(self):
        p=bytearray(packet())
        p[174:198]=STREAM.pack(b'STRM',1,0x21,1,3,230399,42,921600,0)
        parsed=status(bytes(p))
        self.assertEqual(parsed['stream_error_history'],0x21)
        self.assertEqual(parsed['stream_bad_groups'],230399)
        self.assertEqual(parsed['stream_bad_frame'],42)
        self.assertEqual(parsed['stream_bad_pixels'],921600)
        self.assertEqual(parsed['edge_high'],90)
        self.assertEqual(stream_error_text(0x21),'RAW组数/输出帧长度')
        self.assertNotIn('stream_diag_version',status(packet()))
    def test_pid_digital_gain_extension(self):
        p=bytearray(packet())
        p[174:198]=STREAM.pack(b'STRM',1,0,0,0,0,0,0,(768<<16)|(0x84<<8)|0xae)
        parsed=status(bytes(p))
        self.assertEqual(parsed['ae_digital_gain_q8'],768)
        self.assertEqual(parsed['ae_pid_flags'],0x84)
        self.assertNotIn('ae_digital_gain_q8',status(packet()))
    def test_prefix_is_compatible_with_v26(self):
        p=packet();self.assertIsNotNone(old_status(p));self.assertEqual(status(p)['firmware'],27)
        self.assertEqual(status(p)['last_register'],0x0100)
        self.assertEqual(status(p)['edge_high'],90);self.assertEqual(status(p)['sketch_width'],2)
    def test_legacy_and_unknown_extension(self):
        self.assertEqual(status(packet(False))['firmware'],26)
        self.assertIsNone(status(packet(version=2)))
    def test_modes_have_independent_addresses(self):
        e=profile_fields(3,45,90,1);s=profile_fields(5,50,100,2)
        self.assertFalse(set(e)&set(s));self.assertEqual(e,{13:45,14:90,17:1})
    def test_invalid_profiles(self):
        for args in ((0,1,2,1),(3,0,10,1),(3,100,50,1),(5,20,2041,1),(5,20,50,0)):
            with self.assertRaises(ValueError):profile_fields(*args)

class AdaptiveAETelemetryTests(unittest.TestCase):
    def test_build_and_protective_target_in_reserved_extension(self):
        data=bytearray(packet())
        data[139]=1
        data[140:142]=bytes((36,83))
        parsed=status(data)
        self.assertEqual(parsed['hardware_build'],36)
        self.assertEqual(parsed['ae_target_mean'],83)

class ImageTests(unittest.TestCase):
    def test_constant_has_no_contours(self):
        frame=np.full((32,48,3),100,np.uint8)
        self.assertTrue(np.all(contour(frame,45,90)==0));self.assertTrue(np.all(contour(frame,45,90,sketch=True)==255))
    def test_low_contrast_step_requires_lower_threshold(self):
        frame=np.full((32,48,3),100,np.uint8);frame[:,24:]=120
        self.assertFalse(np.any(contour(frame,95,190)))
        self.assertTrue(np.all(contour(frame,20,40)[:,23:25]==255))
    def test_small_noise_is_rejected(self):
        rng=np.random.default_rng(27);frame=(100+rng.integers(-2,3,(32,48,1))).astype(np.uint8).repeat(3,axis=2)
        self.assertFalse(np.any(contour(frame,45,90)))
    def test_stroke_expands_without_mutating_input(self):
        frame=np.full((32,48,3),80,np.uint8);frame[:,24:]=180;original=frame.copy()
        self.assertGreater(np.count_nonzero(contour(frame,45,90,2)),np.count_nonzero(contour(frame,45,90,1)))
        np.testing.assert_array_equal(frame,original)
if __name__=='__main__':unittest.main()

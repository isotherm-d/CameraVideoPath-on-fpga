"""Diagnostic result packets must never repaint FPGA video in either viewer."""
import collections
import threading
import time
import unittest
from unittest.mock import Mock, patch
import numpy as np
from cam_gui_v26 import App as V26App
from cam_gui_v27 import App as V27App


class PreviewOverlayTests(unittest.TestCase):
    def test_diagnostic_bbox_does_not_paint_received_rgb(self):
        for viewer in (V26App, V27App):
            with self.subTest(viewer=viewer.__module__):
                app=viewer.__new__(viewer)
                app._ready=False
                app.lock=threading.Lock()
                app.frame=np.full((720,1280,3),73,dtype=np.uint8)
                # Preserve annotations already painted by the board as well.
                app.frame[300:302,500:700]=(0,255,255)
                original=app.frame.copy()
                now=time.monotonic_ns()
                app.record={'sequence':10,'complete_ns':now,'first_ns':now-1000,'assembly_ms':1.0}
                metadata={'frame_id':10,'flags':0,'process_tick':1000,'capture_tick':0,'mode':0}
                app.control=Mock(notice='test')
                app.control.snapshot.return_value=None
                app.control.frame_metadata.return_value=metadata
                app.control.estimated_submission.return_value=None
                app.control.inference_results.return_value=[{
                    'result_bbox':(315<<48)|(485<<32)|(615<<16)|700,
                    'result_class':3,'result_roi':0}]
                app.fps=30.0;app.complete=100.0;app.overlay_font=None
                app.submissions=collections.OrderedDict();app.delays=collections.deque()
                app.last_measurement=None;app.rx_error='';app.running=False
                app.video=Mock();app.command=Mock();app.status=Mock()
                with patch('cam_gui_v26.ImageTk.PhotoImage',side_effect=lambda image:image.copy()):
                    app.update()
                displayed=np.asarray(app.photo)
                # FPS status at the top is allowed; image content below it is exact.
                np.testing.assert_array_equal(displayed[90:],original[90:])
                np.testing.assert_array_equal(app.frame,original)
                app.control.inference_results.assert_not_called()


if __name__=='__main__':unittest.main()

"""Exercise the real Tk callbacks and RGB preview without opening a visible window."""
import socket
import tkinter as tk
import unittest
from unittest.mock import Mock, patch
from PIL import ImageTk
from cam_gui import App


class GuiTests(unittest.TestCase):
    def setUp(self):
        self.root = tk.Tk()
        self.root.withdraw()
        self.command_sock, self.receive_sock = Mock(), Mock()
        self.patches = [
            patch("socket.socket", side_effect=[self.command_sock, self.receive_sock]),
            patch("threading.Thread"), patch("camera_commands.time.sleep")]
        for p in self.patches:
            p.start()
        self.app = App(self.root)

    def tearDown(self):
        self.app.quit()
        for p in reversed(self.patches):
            p.stop()

    def sent(self):
        return [(call.args[0][4], int.from_bytes(call.args[0][5:], "big"))
                for call in self.command_sock.sendto.call_args_list]

    def test_gain_slider_enters_manual_mode(self):
        for ch, value in zip("RGB", (400, 300, 200)):
            self.app.gain_vars[ch].set(value)
        self.app.send_gain()
        self.assertEqual(self.app.wb_var.get(), 2)
        self.assertEqual(self.sent(), [(7, 0), (2, 400), (3, 300), (4, 200), (6, 0)])

    def test_kelvin_slider_and_preset(self):
        self.app.k_var.set(40)
        self.app.send_kelvin()
        self.assertEqual(self.app.wb_var.get(), 1)
        self.app.wb_var.set(0)
        self.app.send_wb_mode()
        self.assertEqual(self.sent(), [(7, 40), (6, 0), (6, 1)])

    def test_actual_preview_preserves_red_and_blue(self):
        self.app.frame[200, 300] = (255, 0, 0)
        self.app.frame[400, 500] = (0, 0, 255)
        self.app.update_video()
        image = ImageTk.getimage(self.app.photo)
        self.assertEqual(image.getpixel((300, 200))[:3], (255, 0, 0))
        self.assertEqual(image.getpixel((500, 400))[:3], (0, 0, 255))

    def test_send_error_is_visible_and_does_not_claim_success(self):
        self.command_sock.sendto.side_effect = OSError("test send failure")
        self.app.send_exp()
        self.assertIn("test send failure", self.app.command_lbl.cget("text"))
        self.assertNotIn("已发送", self.app.command_lbl.cget("text"))

    def test_apply_all_stops_on_first_failure(self):
        self.command_sock.sendto.side_effect = OSError("first command failed")
        self.app.apply_all()
        self.assertEqual(self.command_sock.sendto.call_count, 1)
        self.assertIn("first command failed", self.app.command_lbl.cget("text"))


if __name__ == "__main__":
    unittest.main()

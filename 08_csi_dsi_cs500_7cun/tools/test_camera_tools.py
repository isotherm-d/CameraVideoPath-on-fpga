import socket
import unittest
from unittest.mock import Mock, patch

import numpy as np
from PIL import Image
from camera_commands import CameraCommands, MAGIC
from color_model import load_profile, temperature_gains
from frame_tools import FrameAssembler
from calibrate_reference import fit_gains


def packet(sequence, offset, data, fmt=1):
    return bytes([sequence, fmt]) + offset.to_bytes(4, "big") + bytes(data)


class FrameTests(unittest.TestCase):
    def test_complete_frames_do_not_mix(self):
        receiver = FrameAssembler(4, 2, 12)
        self.assertIsNone(receiver.accept(packet(1, 0, [10] * 12)))
        self.assertIsNone(receiver.accept(packet(2, 12, [20] * 12)))
        image = receiver.accept(packet(2, 0, [20] * 12))
        self.assertTrue(np.all(image == 20))
        receiver.accept(packet(3, 0, [30] * 12))
        self.assertTrue(np.all(image == 20))  # Published image owns its storage.

    def test_duplicates_wrap_and_old_packets(self):
        receiver = FrameAssembler(4, 2, 12)
        receiver.accept(packet(255, 12, range(12, 24)), 1)
        receiver.accept(packet(255, 12, range(12, 24)), 1)
        image = receiver.accept(packet(255, 0, range(12)), 1)
        np.testing.assert_array_equal(image.reshape(-1), np.arange(24))
        self.assertIsNone(receiver.accept(packet(255, 0, range(12)), 1))
        receiver.accept(packet(0, 0, [40] * 12), 1.1)
        self.assertIsNone(receiver.accept(packet(255, 12, [99] * 12), 1.1))
        self.assertTrue(np.all(receiver.accept(packet(0, 12, [40] * 12), 1.1) == 40))

    def test_bad_packets_are_ignored(self):
        receiver = FrameAssembler(4, 2, 12)
        for data in (b"", packet(1, 0, [1]), packet(1, 1, [1] * 12),
                     packet(1, 24, [1] * 12), packet(1, 0, [1] * 12, 2)):
            self.assertIsNone(receiver.accept(data))
        self.assertEqual(receiver.complete_frames, 0)

    def test_completeness_measures_finished_frames(self):
        receiver = FrameAssembler(4, 2, 12)
        for seq in (1, 2):
            receiver.accept(packet(seq, 0, [seq] * 12))
            receiver.accept(packet(seq, 12, [seq] * 12))
        receiver.accept(packet(3, 0, [3] * 12))
        receiver.accept(packet(4, 0, [4] * 12))
        self.assertEqual(receiver.complete_percent, 50)

    def test_board_restart_after_silence(self):
        receiver = FrameAssembler(4, 2, 12)
        receiver.accept(packet(80, 0, [80] * 12), 1)
        receiver.accept(packet(0, 0, [20] * 12), 2)
        self.assertTrue(np.all(receiver.accept(packet(0, 12, [20] * 12), 2) == 20))

    def test_rgb_preview_and_png_have_same_channel_order(self):
        receiver = FrameAssembler(2, 1, 6)
        rgb = receiver.accept(packet(1, 0, [255, 0, 0, 0, 0, 255]))
        image = Image.fromarray(rgb)
        self.assertEqual(image.getpixel((0, 0)), (255, 0, 0))
        self.assertEqual(image.getpixel((1, 0)), (0, 0, 255))


class ControlTests(unittest.TestCase):
    def setUp(self):
        self.sock = Mock()
        self.control = CameraCommands(self.sock)

    def values(self):
        packets = [call.args[0] for call in self.sock.sendto.call_args_list]
        self.assertTrue(all(p[:4] == MAGIC and len(p) == 8 for p in packets))
        return [(p[4], int.from_bytes(p[5:], "big")) for p in packets]

    @patch("camera_commands.time.sleep")
    def test_manual_mode_clears_kelvin_and_sends_all_gains(self, sleep):
        self.control.white_balance("rgb", gains=(291, 256, 246))
        self.sock.setsockopt.assert_called_once_with(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        self.assertEqual(self.values(), [(7, 0), (2, 291), (3, 256), (4, 246), (6, 0)])

    @patch("camera_commands.time.sleep")
    def test_kelvin_and_preset_modes(self, sleep):
        self.control.white_balance("kelvin", 6500)
        self.control.white_balance("preset")
        self.assertEqual(self.values(), [(7, 65), (6, 0), (6, 1)])

    @patch("camera_commands.time.sleep")
    def test_exposure_and_gain_bounds(self, sleep):
        self.control.exposure(0)
        self.control.exposure(9999)
        self.control.white_balance("rgb", gains=(0, 256, 999))
        self.assertEqual(self.values(), [(1, 62), (1, 1800), (7, 0), (2, 64), (3, 256), (4, 511), (6, 0)])


class TemperatureTests(unittest.TestCase):
    def test_calibrated_reference_and_monotonic_curve(self):
        profile = load_profile()
        self.assertEqual(temperature_gains(profile["reference_kelvin"], profile), tuple(profile["base_gains_q8"]))
        gains = [temperature_gains(k, profile) for k in range(2500, 10001, 100)]
        self.assertTrue(all(a[0] <= b[0] and a[2] >= b[2] for a, b in zip(gains, gains[1:])))
        self.assertTrue(all(64 <= v <= 511 for g in gains for v in g))


class CalibrationTests(unittest.TestCase):
    def test_neutral_sensor_with_balanced_reference(self):
        patch = {"rg": 1., "bg": 1.}
        self.assertEqual(fit_gains(patch, patch, (256, 256, 256)), [256, 256, 256])

    def test_recover_sensor_sensitivity_with_existing_gains(self):
        # A sensor sees R=0.8G and B=1.2G. Known existing gains change the
        # observed ratios, but the fitted correction must remain 1/0.8 and 1/1.2.
        target = {"rg": 1., "bg": 1.}
        observed = {"rg": .8*400/300, "bg": 1.2*200/300}
        self.assertEqual(fit_gains(target, observed, (400, 300, 200)), [320, 256, 213])

    def test_unreachable_or_invalid_calibration_is_rejected(self):
        with self.assertRaises(ValueError):
            fit_gains({"rg": 1., "bg": 1.}, {"rg": .1, "bg": .1}, (256, 256, 256))
        with self.assertRaises(ValueError):
            fit_gains({"rg": 1., "bg": 1.}, {"rg": 1., "bg": 1.}, (256, 0, 256))


if __name__ == "__main__":
    unittest.main()

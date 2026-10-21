"""Shared v25 command transport for GUI, CLI and calibration."""
import socket
import time

TARGET = ("192.168.1.255", 6001)
MAGIC = bytes((0xC5, 0xA5, 0x50, 0x01))


def command_packet(command, value):
    if not 0 <= command <= 255 or not 0 <= value <= 0xFFFFFF:
        raise ValueError("Command or value is outside its packet field")
    return MAGIC + bytes([command]) + value.to_bytes(3, "big")


class CameraCommands:
    def __init__(self, sock=None, target=TARGET):
        self.sock = sock if sock is not None else socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.target = target
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)

    def send(self, command, value):
        self.sock.sendto(command_packet(command, value), self.target)
        time.sleep(.003)

    def exposure(self, value):
        self.send(1, max(62, min(1800, int(value))))

    def white_balance(self, mode, kelvin=6500, gains=(256, 256, 256)):
        if mode == "preset":
            self.send(6, 1)
        elif mode == "kelvin":
            self.send(7, max(25, min(100, int(kelvin) // 100)))
            self.send(6, 0)
        elif mode == "rgb":
            self.send(7, 0)
            for command, gain in zip((2, 3, 4), gains):
                self.send(command, max(64, min(511, int(gain))))
            self.send(6, 0)
        else:
            raise ValueError("White-balance mode must be preset, kelvin or rgb")

    def swap(self, enabled):
        self.send(5, int(bool(enabled)))

    def close(self):
        self.sock.close()

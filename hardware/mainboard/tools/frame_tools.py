"""Assemble complete, immutable RGB frames; never publish mixed frame fragments."""
import time
import numpy as np


class FrameAssembler:
    def __init__(self, width=1280, height=720, payload_bytes=1440):
        self.width, self.height, self.payload_bytes = width, height, payload_bytes
        self.total_bytes = width * height * 3
        if self.total_bytes % payload_bytes:
            raise ValueError("Frame size must be a multiple of packet payload size")
        self.chunks = self.total_bytes // payload_bytes
        self.buffer = bytearray(self.total_bytes)
        self.seen = np.zeros(self.chunks, dtype=np.bool_)
        self.sequence = None
        self.unique = self.complete_frames = self.finished_frames = 0
        self.complete_finished_frames = 0
        self.first_frame = True
        self.last_packet_time = 0.0

    @property
    def complete_percent(self):
        if self.finished_frames:
            return 100.0 * self.complete_finished_frames / self.finished_frames
        return 100.0 if self.complete_frames else 0.0

    def accept(self, packet, now=None):
        if len(packet) != self.payload_bytes + 6 or packet[1] != 1:
            return None
        offset = int.from_bytes(packet[2:6], "big")
        if offset % self.payload_bytes or offset >= self.total_bytes:
            return None
        now = time.monotonic() if now is None else now
        sequence = packet[0]
        if self.sequence is not None and sequence != self.sequence:
            if (sequence - self.sequence) % 256 > 128 and now - self.last_packet_time < .5:
                return None
            if not self.first_frame:
                self.finished_frames += 1
                self.complete_finished_frames += int(self.unique == self.chunks)
            self.first_frame = False
        if sequence != self.sequence:
            self.sequence = sequence
            self.seen.fill(False)
            self.unique = 0
        self.last_packet_time = now
        index = offset // self.payload_bytes
        if self.seen[index]:
            return None
        self.seen[index] = True
        self.unique += 1
        self.buffer[offset:offset + self.payload_bytes] = packet[6:]
        if self.unique == self.chunks:
            self.complete_frames += 1
            return np.frombuffer(self.buffer, dtype=np.uint8).reshape(
                self.height, self.width, 3).copy()
        return None

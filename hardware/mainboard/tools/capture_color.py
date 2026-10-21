"""Capture complete board RGB frames and reproducible statistics for v25 tuning.

Close the viewer first. Optional controls are explicit; without them this is a
read-only receiver. Examples: --out DIR --mode preset --exposure 560
or --out DIR --mode rgb --gains 256 256 256 --exposure 560.
"""
import argparse
import json
import socket
import time
from pathlib import Path

import numpy as np
from PIL import Image
from camera_commands import CameraCommands
from frame_tools import FrameAssembler


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True)
    parser.add_argument("--seconds", type=float, default=4)
    parser.add_argument("--mode", choices=("preset", "kelvin", "rgb"))
    parser.add_argument("--kelvin", type=int, default=6500)
    parser.add_argument("--gains", type=int, nargs=3, default=(256, 256, 256))
    parser.add_argument("--exposure", type=int)
    parser.add_argument("--swap", type=int, choices=(0, 1))
    args = parser.parse_args()
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    if hasattr(socket, "SO_EXCLUSIVEADDRUSE"):
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 64 << 20)
    sock.bind(("0.0.0.0", 6000))
    sock.settimeout(.1)
    controls = CameraCommands()
    if args.exposure is not None:
        controls.exposure(args.exposure)
    if args.mode is not None:
        controls.white_balance(args.mode, args.kelvin, args.gains)
    if args.swap is not None:
        controls.swap(args.swap)
    controls.close()
    receiver = FrameAssembler()
    start = time.monotonic()
    packet_count = heartbeat = 0
    samples, frame_times = [], []
    try:
        while time.monotonic() - start < args.seconds:
            try:
                packet, address = sock.recvfrom(65536)
            except socket.timeout:
                continue
            if address[0] != "192.168.1.66":
                continue
            if len(packet) > 1 and packet[1] == 2:
                heartbeat += 1
                continue
            packet_count += 1
            frame = receiver.accept(packet)
            if frame is not None:
                elapsed = time.monotonic() - start
                frame_times.append(elapsed)
                if elapsed >= .75 and len(samples) < 5:
                    samples.append((elapsed, frame))
    finally:
        sock.close()
    statistics = []
    for index, (elapsed, frame) in enumerate(samples):
        name = f"frame_{index:02d}.png"
        Image.fromarray(frame).save(out / name)
        luma = frame.astype(float) @ np.array([.299, .587, .114])
        statistics.append({"file": name, "time_s": elapsed,
                           "rgb_means": frame.mean(axis=(0, 1)).tolist(),
                           "mean_luma": float(luma.mean()),
                           "clipped_percent": float((frame >= 250).any(axis=2).mean() * 100)})
    result = {"settings_sent": {key: getattr(args, key) for key in ("mode", "kelvin", "gains", "exposure", "swap")},
              "video_packets": packet_count, "heartbeats": heartbeat,
              "complete_frames": receiver.complete_frames,
              "finished_frame_complete_percent": receiver.complete_percent,
              "fps": (len(frame_times)-1)/(frame_times[-1]-frame_times[0]) if len(frame_times)>1 else 0,
              "samples": statistics}
    (out / "capture.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(json.dumps(result, indent=2))
    if not samples:
        raise SystemExit("No complete camera frame captured")


if __name__ == "__main__":
    main()

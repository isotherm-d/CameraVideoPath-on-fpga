"""Sensor calibration followed by a bounded, continuous temperature correction.

The historical temperature anchors are an approximate prior, not a multi-light
SC500CS calibration. Interpolation uses reciprocal temperature (mired). A measured
reference-scene RGB balance supplies the missing sensor sensitivity correction.
"""
import json
from pathlib import Path

PROFILE_PATH = Path(__file__).with_name("wb_profile.json")
ANCHORS = (
    (2500, 134, 511), (3000, 160, 511), (3500, 181, 467),
    (4000, 199, 396), (4500, 214, 349), (5000, 227, 315),
    (5500, 238, 290), (6000, 247, 271), (6500, 256, 256),
    (7000, 263, 243), (7500, 269, 233), (8000, 274, 225),
    (9000, 283, 212), (10000, 291, 203),
)


def load_profile(path=PROFILE_PATH):
    profile = json.loads(Path(path).read_text(encoding="utf-8"))
    base = profile["base_gains_q8"]
    if len(base) != 3 or base[1] != 256 or any(not 64 <= v <= 511 for v in base):
        raise ValueError("Expected bounded Q8 RGB gains, with G=256")
    if not 2500 <= profile["reference_kelvin"] <= 10000 or profile["reference_kelvin"] % 100:
        raise ValueError("Reference temperature is outside the supported curve")
    return profile


def relative_gains(kelvin):
    k = max(2500, min(10000, int(kelvin)))
    for lo, hi in zip(ANCHORS, ANCHORS[1:]):
        if k <= hi[0]:
            weight = (1 / lo[0] - 1 / k) / (1 / lo[0] - 1 / hi[0])
            return tuple(lo[c] + weight * (hi[c] - lo[c]) for c in (1, 2))
    return ANCHORS[-1][1:]


def temperature_gains(kelvin, profile=None):
    profile = load_profile() if profile is None else profile
    r, b = relative_gains(kelvin)
    ref_r, ref_b = relative_gains(profile["reference_kelvin"])
    base = profile["base_gains_q8"]
    clamp = lambda value: max(64, min(511, int(value + .5)))
    return clamp(base[0] * r / ref_r), 256, clamp(base[2] * b / ref_b)

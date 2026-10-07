#!/usr/bin/env python3
"""v25 CLI: exp N | preset | kelvin K | gain R G B | swap 0/1.
Legacy mode/gainr/gaing/gainb send raw register writes.
Use gain R G B to explicitly enter manual RGB mode.
"""
import sys
from camera_commands import CameraCommands


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return
    command, values = sys.argv[1], list(map(int, sys.argv[2:]))
    control = CameraCommands()
    try:
        if command == "exp":
            control.exposure(values[0])
        elif command == "preset":
            control.white_balance("preset")
        elif command == "kelvin":
            control.white_balance("kelvin", values[0])
        elif command == "gain" and len(values) == 3:
            control.white_balance("rgb", gains=values)
        elif command == "swap":
            control.swap(values[0])
        elif command in ("mode", "gainr", "gaing", "gainb"):
            control.send({"mode": 0, "gainr": 2, "gaing": 3, "gainb": 4}[command], values[0])
        else:
            raise ValueError(__doc__)
        print(f"参数已发送，未回读：{command} {values}")
    finally:
        control.close()


if __name__ == "__main__":
    main()

"""Refresh TD workspace metadata and the HDMI ROM path after moving this folder."""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def update(file, pattern, replacement):
    before = file.read_bytes()
    text, count = re.subn(pattern, replacement, before.decode('utf-8'), count=1)
    if count != 1:
        raise ValueError(f'Expected one path setting in {file}')
    if text.encode('utf-8') != before:
        file.write_bytes(text.encode('utf-8'))
        print('Updated', file.relative_to(ROOT))


if __name__ == '__main__':
    for name in ['hardware/mainboard/td_project/camera_to_dsi_display.al', 'hardware/hdmi/HDMI_OUT.al']:
        file = ROOT/name
        update(file, r'(<Project\b[^>]*\bPath=")[^"]*(")', lambda m: m[1]+file.parent.as_posix()+m[2])
    rom = ROOT/'hardware/hdmi/uisrc/01_rtl/logo_mem.hex'
    if not rom.is_file():
        raise FileNotFoundError(rom)
    update(ROOT/'hardware/hdmi/uisrc/01_rtl/osd_anlogic_logo.v',
           r'(\$readmemh\(")[^"]+(",\s*mem\);)', lambda m: m[1]+rom.as_posix()+m[2])
    print('Project paths configured for', ROOT)

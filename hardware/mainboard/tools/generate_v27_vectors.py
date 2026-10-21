import argparse
from pathlib import Path
import numpy as np
from v27_reference import contour
p=argparse.ArgumentParser();p.add_argument('--output',type=Path,required=True);out=p.parse_args().output
inputs=(out/'style_input.mem').read_text().splitlines()
expected=(out/'style_expected.mem').read_text().splitlines()
for mode in (3,5):
    data=inputs[mode*128:(mode+1)*128]
    image=np.array([[int(s[i:i+2],16) for i in (0,2,4)] for s in data],dtype=np.uint8).reshape(8,16,3)
    output=contour(image,65 if mode==3 else 50,130 if mode==3 else 100,1,mode==5)
    expected[mode*128:(mode+1)*128]=[''.join(f'{v:02x}' for v in pixel) for pixel in output.reshape(-1,3)]
(out/'v27_style_expected.mem').write_text('\n'.join(expected)+'\n')

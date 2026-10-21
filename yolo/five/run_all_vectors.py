"""Run the frozen 14 natural/background vectors with four simulator workers."""
import argparse,concurrent.futures,json,subprocess,sys
from pathlib import Path
BASE=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser();parser.add_argument('--name');args=parser.parse_args()
name=args.name or json.loads((BASE/'five/model_selection.json').read_text())['selected']['run']
count=json.loads((BASE/'runs'/name/'vectors/manifest.json').read_text())['vectors']
def one(i):
 p=subprocess.run([sys.executable,str(BASE/'five/run_tests.py'),'--name',name,'--vector',str(i)],cwd=BASE.parent,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 (BASE/f'tmp/five_vector{i}_console.log').write_text(p.stdout,encoding='utf8')
 if p.returncode:raise RuntimeError(f'vector {i}: '+p.stdout[-4000:])
 return i
with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
 for f in concurrent.futures.as_completed([pool.submit(one,i) for i in range(count)]):print('FIVE_INTEGER_VECTOR_PASS',f.result(),flush=True)
print('FIVE_ALL_INTEGER_VECTORS_PASS',count,flush=True)

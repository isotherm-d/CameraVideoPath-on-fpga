"""Run exact probes before natural vectors so temporary simulator folders agree."""
import argparse,subprocess,sys
from pathlib import Path
BASE=Path(__file__).resolve().parents[1]
def main(name):
 commands=[('development_rtl',[str(BASE/'wbc_bccd/run_camera_probes.py'),'--name',name]),
 ('natural_rtl',[str(BASE/'wbc_bccd/run_all_vectors.py'),'--name',name]),
 ('unit_rtl',[str(BASE/'wbc_bccd/run_tests.py'),'--unit','--name',name]),
 ('stream_burst',[str(BASE/'wbc_bccd/run_tests.py'),'--stream','--name',name]),
 ('stream_paced',[str(BASE/'wbc_bccd/run_tests.py'),'--stream','--paced','--name',name])]
 for tag,args in commands:
  print('TWO_SOURCE_VERIFY_BEGIN',tag,flush=True)
  with (BASE/'tmp'/('wbc_bccd_'+tag+'.log')).open('wb') as f:subprocess.run([sys.executable,*args],cwd=BASE.parent,stdout=f,stderr=subprocess.STDOUT,check=True)
  print('TWO_SOURCE_VERIFY_PASS',tag,flush=True)
 print('TWO_SOURCE_CANDIDATE_VERIFICATION_PASS',flush=True)
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--name',default='wbc_bccd160_20261021');main(p.parse_args().name)

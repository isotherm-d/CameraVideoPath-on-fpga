"""Publish measured training and VAL-only confidence tradeoffs."""
import argparse,json
from pathlib import Path
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
BASE=Path(__file__).resolve().parents[1]
def main(name):
 run=BASE/'runs'/name;h=json.loads((run/'history.json').read_text(encoding='utf8'));v=json.loads((run/'integer_validation.json').read_text(encoding='utf8'));p=json.loads((run/'protocol.json').read_text(encoding='utf8'))
 plt.rcParams.update({'font.size':11,'axes.titlesize':11,'axes.labelsize':11,'legend.fontsize':10.5})
 fig,axes=plt.subplots(1,2,figsize=(8.3,3.5),layout='constrained')
 x=[z['epoch']+(p['fp32_epochs'] if z['phase']=='qat' else 0) for z in h]
 axes[0].plot(x,[z['WBCAtt_VAL_macro_F1'] for z in h],label='WBCAtt joint macro-F1',lw=1.6)
 axes[0].plot(x,[z['BCCD_VAL_F1'] for z in h],label='BCCD localization F1',lw=1.6)
 if p['fp32_epochs']:axes[0].axvline(p['fp32_epochs'],color='.4',ls='--',lw=1)
 if 'camera_VAL_macro_F1' in h[0]:axes[0].plot(x,[z['camera_VAL_macro_F1'] for z in h],label='Camera-augmented VAL F1',lw=1.6)
 title='Objectness QAT; monitor 0.85' if 'training_stages' in p else 'Additional QAT; monitor 0.70' if 'previous_stage' in p else 'FP32 then QAT; monitor 0.70'
 axes[0].set(xlabel='Completed epochs',ylabel='VAL metric',ylim=(.6,1),title=title);axes[0].legend();axes[0].grid(alpha=.2)
 c=v['choices'];t=[z['threshold'] for z in c]
 axes[1].plot(t,[z['metrics']['joint_macro_F1'] for z in c],label='WBCAtt joint macro-F1',lw=1.6)
 axes[1].plot(t,[z['metrics']['BCCD']['recall'] for z in c],label='BCCD localization recall',lw=1.6)
 axes[1].plot(t,[1-z['procedural_VAL_FP_rate'] for z in c],label='Procedural negative specificity',lw=1.6)
 axes[1].axvline(v['selected']['threshold'],color='.4',ls='--',lw=1,label='Deployment choice (VAL + dev)')
 axes[1].set(xlabel='Score threshold / 65025',ylabel='VAL metric',ylim=(.5,1.01),title='Frozen-weight confidence sweep');axes[1].legend();axes[1].grid(alpha=.2)
 fig.savefig(run/'training_and_calibration.png',dpi=220);plt.close(fig);print('TWO_SOURCE_TRAINING_FIGURE_READY',flush=True)
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--name',default='wbc_bccd160_20261021');main(p.parse_args().name)

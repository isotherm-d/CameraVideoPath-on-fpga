"""Read-only final identity verification; never touches the live video receiver."""
import datetime,hashlib,json,re,zipfile
from pathlib import Path
BASE=Path(__file__).resolve().parents[1];REPO=BASE.parent;BOARD=REPO/'08_csi_dsi_cs500_7cun';HOME=BASE/'wbc_bccd';REPORT=BOARD/'reports/yolo_wbc_bccd15';CVP=REPO.parent
def read(p):return json.loads(p.read_text(encoding='utf8'))
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
if __name__=='__main__':
 s=read(REPORT/'current/summary.json');p=read(REPORT/'programming/programming.json');state=read(BOARD/'deployment_state.json');phy=s['build']['physical'];manifest=read(CVP/'作品报告_LaTeX/release_manifest.json')
 assert p['program_sram_success'] and not p['flash_written'] and p['device']=='PH1P35MDG324'
 assert p['model']==s['model']==state['model']==manifest['model']
 assert p['bit_sha256']==state['bit_sha256']==phy['bit_sha256']==manifest['bit_sha256']==sha(BOARD/phy['bit_path'])==sha(REPORT/'current/physical/camera_to_dsi_display.bit')
 assert min(phy['SWNS'],phy['HWNS'])>=0 and phy['slice']<=21216 and phy['eram']<=108 and phy['dsp']<=40
 assert sha(BOARD/'td_project/camera_to_dsi_display.al')==read(HOME/'baseline/manifest.json')['project_sha256']
 for n,w in read(REPORT/'current/physical/source_hashes.json').items():assert sha(BOARD/n)==w,n
 for n,w in read(HOME/'regression_source_hashes.json').items():assert sha(REPO/n)==w,n
 for n,w in s['frozen_assets'].items():assert sha(HOME/'frozen'/n)==w,n
 for n,w in manifest['original_template_hashes'].items():assert sha(CVP/n)==w,n
 assert sha(CVP/'作品报告.pdf')==sha(CVP/'作品报告_LaTeX/main.pdf')==manifest['pdf_sha256']
 assert manifest['pages']==25 and manifest['threshold_uses_provided_development_frames'] and not manifest['original_1percent_artificial_background_gate_passed']
 assert 'Chip validation success: PH1P35MDG324' in (REPORT/'programming/program_jtag.log').read_text(encoding='utf8')
 headings=lambda t:re.findall(r'\\(?:subsubsection|subsection|section)\{[^}]+\}',t)
 with zipfile.ZipFile(CVP/'tmp/official_report_wbc_bccd_20261021/before_two_source.zip') as z:
  for file in (CVP/'作品报告_LaTeX/sections').glob('*.tex'):assert headings(file.read_text(encoding='utf8'))==headings(z.read(file.relative_to(CVP).as_posix()).decode('utf8')),file.name
 record={'recorded_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'status':'PASS','model':p['model'],'bit_sha256':p['bit_sha256'],'pdf_sha256':manifest['pdf_sha256'],'project_unchanged':True,'all_physical_sources_unchanged':True,'PC_tools_match_fresh_regression_pins':True,'official_template_and_heading_hierarchy_preserved':True,'release_scope':p['release_scope'],'actual_camera_and_HDMI_acceptance':False}
 (REPORT/'release_integrity.json').write_text(json.dumps(record,indent=2),encoding='utf8');print('FINAL_RELEASE_INTEGRITY_PASS',json.dumps(record),flush=True)

"""Render every page for review; publish metadata only after explicit QA flag."""
import argparse,datetime,hashlib,json,re,shutil,zipfile
from pathlib import Path
import fitz
from PIL import Image,ImageDraw
BASE=Path(__file__).resolve().parents[1];CVP=BASE.parent/'docs/competition';DOC=CVP/'作品报告_LaTeX';TMP=BASE.parent/'build/official_report_wbc_bccd_20261021'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main(reviewed):
 pending=json.loads((TMP/'pending_release.json').read_text(encoding='utf8'));log=(DOC/'main.log').read_text(encoding='utf8',errors='replace')
 assert not re.search(r'Overfull|Missing character|Undefined control sequence|LaTeX Error|There were undefined references|Rerun to get cross-references right',log), 'Check LaTeX log before release'
 pdf=fitz.open(DOC/'main.pdf');folder=TMP/'render';folder.mkdir(exist_ok=True)
 thumbnails=[]
 for i,page in enumerate(pdf):
  pix=page.get_pixmap(matrix=fitz.Matrix(1.4,1.4),alpha=False);p=folder/f'page_{i+1:02}.png';pix.save(p)
  im=Image.open(p).convert('RGB');im.thumbnail((670,930));tile=Image.new('RGB',(690,965),'#cccccc');tile.paste(im,((690-im.width)//2,25));ImageDraw.Draw(tile).text((15,7),str(i+1),fill='black');thumbnails.append(tile)
 for start in range(0,len(thumbnails),4):
  sheet=Image.new('RGB',(1380,1930),'#999999')
  for j,im in enumerate(thumbnails[start:start+4]):sheet.paste(im,((j%2)*690,(j//2)*965))
  sheet.save(folder/f'contact_{start//4+1:02}.png')
 text='\n'.join(p.get_text() for p in pdf);assert all(s in text for s in ['BCCD','WBCAtt','Basophil','Neutrophil']), 'Missing current report content'
 assert pending['programming']['bit_sha256'] in text,'Missing bit identity'
 for n,w in pending['protected'].items():assert sha(CVP/n)==w,n
 print('PDF_RENDERED_FOR_REVIEW',len(pdf),'pages',flush=True)
 if not reviewed:return
 program=pending['programming'];state=json.loads((BASE.parent/'hardware/mainboard/deployment_state.json').read_text(encoding='utf8'));assert state['bit_sha256']==program['bit_sha256']
 shutil.copy2(DOC/'main.pdf',CVP/'作品报告.pdf');manifest={'recorded_local':datetime.datetime.now().astimezone().isoformat(),'pages':len(pdf),'model':pending['model'],'bit_sha256':program['bit_sha256'],'bit_path':state['bit_path'],'programmed_SRAM':True,'current_training_sources':['WBCAtt+','BCCD'],'live_camera_validated':False,'HDMI_validated':False,'pdf_sha256':sha(DOC/'main.pdf'),'template_and_heading_hierarchy_preserved':True,'original_template_hashes':pending['protected'],'programming_record':str(BASE.parent/'hardware/mainboard/reports/yolo_wbc_bccd15/programming/programming.json'),'pdf_checks':{'xelatex_two_pass':True,'overfull_or_missing_glyphs':False,'unresolved_references':False,'all_pages_visually_reviewed':True},'files':{}}
 manifest.update(release_scope=state['release_scope'],original_1percent_artificial_background_gate_passed=False,threshold_uses_provided_development_frames=True,source_summary=str(BASE.parent/'hardware/mainboard/reports/yolo_wbc_bccd15/current/summary.json'),programming_record_sha256=sha(Path(manifest['programming_record'])),programming_log_sha256=sha(Path(manifest['programming_record']).with_name('program_jtag.log')))
 for p in DOC.rglob('*'):
  if p.is_file() and p.name!='release_manifest.json' and (p.suffix in ['.tex','.sty','.png','.md'] or p.name in ['main.pdf','模板.pdf']):manifest['files'][p.relative_to(DOC).as_posix()]=sha(p)
 (DOC/'release_manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2),encoding='utf8')
 with zipfile.ZipFile(CVP/'作品报告_LaTeX.zip','w',zipfile.ZIP_DEFLATED) as z:
  for p in DOC.rglob('*'):
   if p.is_file() and (p.suffix in ['.tex','.sty','.png','.md','.json'] or p.name in ['main.pdf','模板.pdf']):z.write(p,p.relative_to(CVP))
 print('OFFICIAL_TWO_SOURCE_PDF_PUBLISHED',manifest['pdf_sha256'],flush=True)
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--visually-reviewed',action='store_true');main(p.parse_args().visually_reviewed)

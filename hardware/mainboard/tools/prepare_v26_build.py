"""Prepare an isolated TD build; engineering source is never rebuilt in place."""
import argparse,hashlib,json,re,shutil
from pathlib import Path
p=argparse.ArgumentParser()
p.add_argument("--name",required=True)
a=p.parse_args()
project=Path(__file__).resolve().parents[1]
workspace=project.parents[2]
build=workspace/"tmp/v26_task135"/a.name
if not build.resolve().is_relative_to(workspace.resolve()) or build.exists():
    raise SystemExit("Use a new build directory within this workspace")
(build/"td_project").mkdir(parents=True)
shutil.copytree(project/"user_source",build/"user_source")
for source in (project/"td_project").iterdir():
    if source.is_file() and source.suffix in (".al",".sdc",".adc"):
        shutil.copy2(source,build/"td_project"/source.name)
al=build/"td_project/camera_to_dsi_display.al"
s=al.read_text(encoding="utf-8")
s=re.sub(r'(<Project[^>]* Path=")[^"]*',lambda m:m[1]+(build/"td_project").as_posix(),s,count=1)
# Restore required RAW processing sources if GUI source pruning removed one.
for name in ("cvp_proc", "cvp_demosaic", "group_fifo", "pack_4"):
    rel="../user_source/hdl_source/isp2/"+name+".v"
    if rel not in s:
        s=s.replace("</Verilog>",f'<File Path="{rel}"><FileInfo><Attr Name="UsedInSyn" Val="true"/><Attr Name="UsedInP&R" Val="true"/><Attr Name="BelongTo" Val="design_1"/></FileInfo></File>\n        </Verilog>',1)
# New modules are registered before each fresh build, including optional adapters.
for sub in ("common","advanced"):
    for rtl in sorted((build/"user_source/hdl_source"/sub).glob("*.v")):
        rel="../user_source/hdl_source/"+sub+"/"+rtl.name
        if rel not in s:
            s=s.replace("</Verilog>",f'<File Path="{rel}"><FileInfo><Attr Name="UsedInSyn" Val="true"/><Attr Name="UsedInP&R" Val="true"/><Attr Name="BelongTo" Val="design_1"/></FileInfo></File>\n        </Verilog>',1)
count=[200]
def expanded(m):
    count[0]+=1
    return ('<File Path="'+m[1]+'">\n                <FileInfo>\n'
            '                    <Attr Name="UsedInSyn" Val="true"/>\n'
            '                    <Attr Name="UsedInP&R" Val="true"/>\n'
            '                    <Attr Name="BelongTo" Val="design_1"/>\n'
            '                    <Attr Name="CompileOrder" Val="'+str(count[0])+'"/>\n'
            '                </FileInfo>\n            </File>')
s=re.sub(r'<File Path="([^"]*/(?:common|advanced)/[^"]+)">.*?</File>',expanded,s,flags=re.S)
al.write_text(s,encoding="utf-8")
hashes={str(x.relative_to(project)).replace("\\","/"):hashlib.sha256(x.read_bytes()).hexdigest()
        for x in (project/"user_source/hdl_source").rglob("*") if x.is_file()}
(build/"source_hashes.json").write_text(json.dumps(hashes,indent=2))

templates=project/"tools/td_templates"
sources=re.search(r"<Source_Files>.*?</Source_Files>",s,re.S).group(0).replace('Path="../user_source/','Path="../../../user_source/')
for stage,run in (("synthesis","syn_1"),("physical","phy_1")):
    d=build/"td_project/camera_to_dsi_display_Runs"/run
    d.mkdir(parents=True)
    kind="syn" if run=="syn_1" else "phy"
    shutil.copy2(templates/(kind+".tcl"),d/"camera_to_dsi_display.tcl")
    shutil.copy2(templates/(kind+"_settings.cfg"),d/"settings.cfg")
    prj=(templates/"project.prj").read_text(encoding="utf-8")
    prj=re.sub(r"<Source_Files>.*?</Source_Files>",lambda m:sources,prj,flags=re.S)
    (d/"camera_to_dsi_display.prj").write_text(prj,encoding="utf-8")
    shutil.copy2(build/"td_project/camera_to_dsi_display.sdc",d/"camera_to_dsi_display.sdc")
    (build/(stage+".tcl")).write_text(f"cd {{{d.as_posix()}}}\nsource camera_to_dsi_display.tcl\nexit\n")
print(build)

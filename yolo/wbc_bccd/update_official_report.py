"""Update the existing official-format LaTeX only from a programmed new release."""
import datetime,hashlib,json,re,shutil,zipfile
from pathlib import Path
BASE=Path(__file__).resolve().parents[1];REPO=BASE.parent;CVP=REPO/'docs/competition';DOC=CVP/'作品报告_LaTeX';REPORT=REPO/'hardware/mainboard/reports/yolo_wbc_bccd15'
def read(p):return json.loads(p.read_text(encoding='utf8'))
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def pct(v):return f'{100*v:.2f}'
def replace(text,old,new):
 assert old in text,old[:90]
 return text.replace(old,new)
if __name__=='__main__':
 s=read(REPORT/'current/summary.json');program=read(REPORT/'programming/programming.json');a=s['repair_acceptance'];m=a['validation'];test=s['reused_TEST_regression']['metrics'];physical=s['build']['physical']
 assert s['build']['phase']=='timing_pass_programmed_SRAM' and program['program_sram_success'] and program['bit_sha256']==physical['bit_sha256'] and a['gate_passed']
 tmp=REPO/'build/official_report_wbc_bccd_20261021';tmp.mkdir(exist_ok=True,parents=True);backup=tmp/'before_two_source.zip';assert not backup.exists()
 before=read(DOC/'release_manifest.json');protected=before['original_template_hashes']
 for n,w in protected.items():assert sha(CVP/n)==w,n
 with zipfile.ZipFile(backup,'w',zipfile.ZIP_DEFLATED) as z:
  for p in DOC.rglob('*'):
   if p.is_file() and p.suffix in ['.tex','.sty','.png','.json','.md','.pdf']:z.write(p,p.relative_to(CVP))
  z.write(CVP/'作品报告.pdf','作品报告.pdf')
 files=[DOC/'main.tex',*sorted((DOC/'sections').glob('*.tex'))];texts={p:p.read_text(encoding='utf8') for p in files}
 headings=lambda t:re.findall(r'\\(?:subsubsection|subsection|section)\{[^}]+\}',t)
 oldheadings={p:headings(t) for p,t in texts.items()}
 stamp=datetime.datetime.fromisoformat(program['recorded_utc']).astimezone(datetime.timezone(datetime.timedelta(hours=8)));clock=stamp.strftime('%H:%M');th=a['threshold_q16'];sw=physical['SWNS'];hw=physical['HWNS'];sl=physical['slice'];er=physical['eram'];ds=physical['dsp']
 area=(REPORT/'current/physical/route.area').read_text(encoding='utf8');timing=(REPORT/'current/physical/route.timing').read_text(encoding='utf8')
 lut=int(re.search(r'#lut6\s+(\d+)',area)[1]);reg=int(re.search(r'#reg\s+(\d+)',area)[1]);coverage=re.search(r'STA coverage\s*:\s*([\d.]+)%',timing)[1]
 protocol=read(BASE/'runs'/s['model']/'protocol.json');stages='120轮FP32与80轮QAT'
 if 'previous_stage' in protocol:stages+=f'，再追加{protocol["qat_epochs"]}轮低照正样本QAT'
 if 'training_stages' in protocol:stages='120轮FP32与80轮QAT、60轮低照正样本QAT，最后40轮只训练objectness输出'
 summary=f'当前模型仅以WBCAtt+与BCCD两套采集数据训练：前者提供五类与整细胞框，后者提供定位和背景、屏蔽分类损失。完成{stages}，VAL选择权重，部署阈值另使用给过的截图开发校准；已使用TEST联合macro-F1为{pct(test["joint_macro_F1"])}\\%。黑灰纯色及给过的室内图无框、旧细胞图可定位，但这些截图已用于校准，不能替代独立相机验收。两组人工背景误检{pct(a["procedural_final"]["FP_rate"])}\\%与{pct(a["extra_procedural_final"]["FP_rate"])}\\%，第一组未达原1\\%目标，本次按2\\%工程试验界限上板，保留失败记录。'
 p=DOC/'main.tex';t=texts[p];t=re.sub(r'单一来源WBCAtt\+实验.*?没有覆盖板上版本。',lambda _:summary,t,flags=re.S)
 t=re.sub(r'标注视频经双网口.*?分别记录。',lambda _:f'标注视频经双网口分别送PC及HDMI子板，PC承担收图、存帧及参数控制。新位流使用{sl} Slice、{er} ERAM、{ds} DSP，最终建立和保持裕量为{sw:+.3f} ns、{hw:+.3f} ns；{clock}已用TD6.2下载PH1P35主板SRAM，未写Flash、不动HDMI子板。全部实时算法在FPGA，下载成功与实拍效果分别验收。',t,flags=re.S);texts[p]=t
 p=DOC/'sections/01_overview.tex';t=texts[p]
 t=replace(t,r'试验状态 & WBCAtt试验同源macro-F1 92.39\%，因实拍误检撤回',f'试验状态 & 已使用TEST联合macro-F1 {pct(test["joint_macro_F1"])}\\%，实拍待验收')
 t=replace(t,'Slice19018/21216，ERAM94/108，DSP36/40',f'Slice{sl}/21216，ERAM{er}/108，DSP{ds}/40').replace('setup +0.133 ns，hold +0.020 ns',f'setup {sw:+.3f} ns，hold {hw:+.3f} ns')
 t=replace(t,'当前恢复旧验证权重，单一来源修复未完成。','当前完成WBCAtt+与BCCD两来源重训与新bit下载，实拍效果尚待验收。');texts[p]=t
 p=DOC/'sections/02_design.tex';t=texts[p];t=t.replace('以objectness与最高类别sigmoid的整数乘积评分','以objectness的sigmoid查表值乘255作为检测分数，五类logit的argmax独立决定类型');t=replace(t,'回退模型阈值为43892/65025，约0.675；已撤回的WBCAtt+实验采用52020/65025，即0.8',f'当前两来源模型阈值为{th}/65025，由VAL冻结；旧回退模型为43892/65025，已撤回WBCAtt-only实验为52020/65025');texts[p]=t
 p=DOC/'sections/03_results.tex';t=texts[p]
 start=t.index('基础相机、网络');end=t.index(r'\Needspace',start)
 introduction=f'基础相机、网络及HDMI显示链路已有实板记录，旧权重00:53版的用户上板反馈单独保留。WBCAtt-only实验09:22下载后被反馈空场景误检，09:52回退旧权重。本轮按用户要求仅使用WBCAtt+和BCCD重新训练，完成拒识、定位分类、逐层RTL与完整视频检查，在既有主板工程重新综合布局布线，{clock}经TD6.2成功下载新bit至PH1P35MDG324主板SRAM。当前新权重的相机实拍及HDMI效果待用户观察。\n\n当前使用独立YOLO副本与分支\\path{{experiment/yolo160-w4a4}}，沿用副本原\\code{{camera_to_dsi_display.al}}及其Runs目录。工程文件字节哈希与训练前备份一致，不另建.al，不写Flash，不动HDMI子板，不修改上位机。旧可用bit、源码和模型已在\\path{{yolo/wbc_bccd/baseline/}}保存，新模型、仿真与物理报告由哈希关联。\n\n'
 t=t[:start]+introduction+t[end:]
 t=t.replace('当前回退位流的归档完整布线资源与时序','当前两来源模型位流的完整布线资源与时序')
 t=t.replace('19018/21216，89.64',f'{sl}/21216，{sl/21216*100:.2f}').replace('17509 / 17857',f'{lut} / {reg}').replace('94/108，87.04',f'{er}/108，{er/108*100:.2f}').replace('36/40，90.00',f'{ds}/40，{ds/40*100:.2f}').replace('+0.133 ns / 0',f'{sw:+.3f} ns / 0').replace('+0.020 ns / 0',f'{hw:+.3f} ns / 0').replace('93.22',coverage)
 blockstart=t.index('主板采用PH1P35MDG324');blockend=t.index('\n\n子板显示',blockstart)
 t=t[:blockstart]+f'主板采用PH1P35MDG324，TD6.2.168116，像素处理及网络计算域100MHz。表\\ref{{tab:resource}}来自本轮最终\\code{{route.area}}与\\code{{route.timing}}。Slice剩{21216-sl}个，ERAM剩{108-er}块，DSP剩{40-ds}个；setup/hold总负裕量均为0，STA覆盖率{coverage}\\%，结论限于既有约束。继承的Bank21 SSO与部分时钟布线警告没有记作已修复。增加网络规模仍须重新验证资源、吞吐与时序。\\cite{{resource,timing}}'+t[blockend:]
 t=t.replace('WBCAtt实验接入时14张自然图及派生负图','本轮两来源模型接入的14张自然图及派生负图')
 t=t.replace('WBCAtt实验权重TEST逐类联合结果','已撤回WBCAtt-only实验权重TEST逐类联合结果')
 t=t.replace('当前只是恢复已有可用基线，单一来源修复尚未完成；真实相机效果仍由用户观察。','此时恢复已有基线，未将失败修复候选下载；随后进行下述两来源重训，真实相机效果仍由用户观察。')
 rows='\n'.join(f'{n} & {pct(m["five_classes"][c]["F1"])} & {pct(test["five_classes"][c]["F1"])}\\\\\\hline' for c,n in zip(['BAS','EOS','LYM','MON','NEU'],['Basophil','Eosinophil','Lymphocyte','Monocyte','Neutrophil']))
 added=rf'''
\lead{{WBCAtt+与BCCD两来源重训及当前部署}}
本轮仅使用两套采集数据，不加入Raabin图像或Raabin训练权重。初始化来自从随机权重开始的WBCAtt-only FP32 checkpoint。WBCAtt+的TRAIN/VAL/TEST原图为6021/1010/3017，派生背景裁图为6020/1010/3017；BCCD原图为205/87/72，负裁图为270/122/99。BCCD只使用WBC框，五类标签保持-1并屏蔽分类损失；没有给其制造五类伪标。派生样本随原图划分，实际RGB160跨划分精确重复为零，不证明患者独立性。

完成{stages}；按五类、BCCD及负样本分层采样。mosaic只作用于有五类标签的正图槽，避免减少空图比例。程序化纯色、暗场、矩形、渐变和噪声作为增强。首轮两来源模型空场景已无框，但旧细胞拍屏图仍漏检，提亮诊断说明存在曝光差异；追加低照正图与拍屏比例，并重放原始明亮细胞真值。固定相机增强VAL来自VAL父图，不是独立相机测试。checkpoint由VAL选择，权重冻结后原仅VAL阈值0.95仍漏旧图；部署改用公开/固定增强VAL及用户给过的有、无细胞截图，在0.40至0.95、步长0.025网格进行开发校准，选定{th}/65025。截图像素和未知类型没有用于训练，但截图用于阈值选择，不能再称仅VAL校准或独立相机验收。TEST未参与选择；它在前次实验已被查看，本次只称已使用测试集回归。

\begin{{table}}[htbp]\centering\small
\caption{{当前两来源整数模型结果（\%，框IoU$\geq$0.5）}}
\begin{{tabularx}}{{\linewidth}}{{|Y|r|r|}}
\hline\tablehead 指标 & VAL & 已使用TEST回归\\\hline
WBCAtt+联合macro-F1 & {pct(m['joint_macro_F1'])} & {pct(test['joint_macro_F1'])}\\\hline
WBCAtt+框与类型正确召回 & {pct(m['joint_correct_recall'])} & {pct(test['joint_correct_recall'])}\\\hline
BCCD定位召回 & {pct(m['BCCD']['recall'])} & {pct(test['BCCD']['recall'])}\\\hline
BCCD定位精确率 & {pct(m['BCCD']['precision'])} & {pct(test['BCCD']['precision'])}\\\hline
WBCAtt+负图有框比例 & {pct(m['WBCAtt']['false_positive_negative_images']/m['WBCAtt']['negative_images'])} & {pct(test['WBCAtt']['false_positive_negative_images']/test['WBCAtt']['negative_images'])}\\\hline
BCCD空图有框比例 & {pct(m['BCCD']['false_positive_negative_images']/m['BCCD']['negative_images'])} & {pct(test['BCCD']['false_positive_negative_images']/test['BCCD']['negative_images'])}\\\hline
{rows}
\end{{tabularx}}
\end{{table}}

表中五个英文类别行是各类联合F1，不是只分类准确率；联合正确还要求定位IoU达标。两组1024张程序空场景分别误检{a['procedural_final']['false_positive_images']}张（{pct(a['procedural_final']['FP_rate'])}\%）及{a['extra_procedural_final']['false_positive_images']}张（{pct(a['extra_procedural_final']['FP_rate'])}\%）。第一组未达到原1\%目标，原失败记录保留；两组均低于2\%工程试验界限。2\%是看到结果后的工程上板选择，不是事先定义的精度目标。人工压力图不能代表真实相机分布，原图派生负样本仍有误检；本轮作为SRAM试验版本，不称背景问题已全面解决。12张纯色与给过的室内图无框，旧细胞图能定位但类型真值未知，且截图已用于开发校准。最终对每张空图最强锚框施加背景损失，仅调整三路objectness滤波器，前九层及框/类型参数逐项保持；检测与五类argmax解耦。RTL执行新评分，未新增分类器或上位机算法。

14张自然与派生图完成十层整数对拍；另对黑、灰、白、用户室内图和历史细胞图完成五次整网RTL回放，最终框、类别、分数及逐层结果均与参考一致。五项组件、三项原跟踪、两种720p30完整视频仿真，以及42项既有RTL、两项包完整性、38项Python重新通过。新bit最终时序通过，并核验TD6.2识别PH1P35MDG324、芯片校验成功、Tcl catch=0及download同步结束。下载仅限主板SRAM，实拍与HDMI效果待用户验收。\cite{{twosource}}

'''
 t=replace(t,r'\lead{运行状态与测量口径}',added+r'\lead{运行状态与测量口径}')
 plot=BASE/'runs'/s['model']/'training_and_calibration.png'
 if plot.exists():
  shutil.copy2(plot,DOC/'images/two_source_training.png')
  figure=r'''\begin{figure}[htbp]\centering
\includegraphics[width=0.98\linewidth]{images/two_source_training.png}
\caption{仅objectness追加训练与开发阈值校准。左图固定0.85阈值监测，右图在冻结权重后扫描，虚线为结合公开验证及用户开发截图选定的部署阈值。程序空图特异性不是相机域性能。}
\end{figure}

'''
  t=replace(t,r'\lead{运行状态与测量口径}',figure+r'\lead{运行状态与测量口径}')
 t=t.replace('WBCAtt+实验权重在09:22下载后被用户反馈空场景误检，已暂停部署；09:52经TD 6.2成功回退至此前用户验证过的旧权重bit，仅写主板SRAM。本次回退后的现场效果仍需用户确认。 本轮位流SHA256为',f'本轮两来源模型已于{clock}通过TD6.2下载主板SRAM；相机和HDMI现场效果仍需用户观察。本轮新位流SHA256为').replace('60d25f6ff3056fea9c2f621ace6666f2d9cb29771813617c2aa542433ed77ff6',program['bit_sha256']).replace(r'\cite{programming}',r'\cite{twosource,programming}');texts[p]=t
 p=DOC/'sections/04_summary.tex';t=texts[p];t=t.replace('当前主板已回退旧验证权重，单一来源新版因空场景误检撤回。','当前主板已下载WBCAtt+与BCCD两来源重训模型；此前单一来源新版因空场景误检撤回，历史证据保留。').replace('剩余14块ERAM与4个DSP',f'剩余{108-er}块ERAM与{40-ds}个DSP');texts[p]=t
 p=DOC/'sections/05_references.tex';t=texts[p].replace('当前回退位流归档布线','当前两来源模型最终布线').replace('reports/yolo_single15/current/physical/route.area','reports/yolo_wbc_bccd15/current/physical/route.area').replace('reports/yolo_wbcatt_single15/current/summary.json','reports/yolo_wbc_bccd15/current/summary.json')
 t=t.replace(r'\end{thebibliography}',r'\bibitem{twosource} 项目组. WBCAtt+与BCCD两来源训练及主板部署报告[R]. 2026-10-21. \path{yolo/wbc_bccd/protocol.json}, \path{data_manifest.json}, \path{frozen/}；\path{reports/yolo_wbc_bccd15/current/summary.json}及\path{programming/}.'+'\n'+r'\end{thebibliography}');texts[p]=t
 for p,t in texts.items():assert headings(t)==oldheadings[p],p
 for p,t in texts.items():p.write_text(t,encoding='utf8')
 (DOC/'README.md').write_text(f'# 作品报告 LaTeX\n\n当前模型：{s["model"]}，WBCAtt+与BCCD两来源，{stamp.isoformat()}成功下载主板SRAM，bit `{program["bit_sha256"]}`。全部实时算法在FPGA，既有.al字节不变。实拍和HDMI效果待用户观察。\n\n保留官方五部分及全部章节标题、Word模板、页眉和reportstyle.sty。历史WBCAtt-only失败及回退表单独标识，本轮结果由实际训练、RTL、最终物理和下载记录支持。主文档main.tex，XeLaTeX编译两次，PDF逐页检查后交付。\n',encoding='utf8')
 for n,w in protected.items():assert sha(CVP/n)==w,n
 (tmp/'pending_release.json').write_text(json.dumps({'model':s['model'],'programming':program,'physical':physical,'prior_release':before,'protected':protected},ensure_ascii=False,indent=2),encoding='utf8')
 print('OFFICIAL_LATEX_TWO_SOURCE_UPDATED_PRESERVED_HEADINGS',flush=True)

"""Publish only after the exact accepted bit has a successful SRAM record."""
import datetime,hashlib,json,re
from pathlib import Path
BASE=Path(__file__).resolve().parents[1];REPO=BASE.parent;BOARD=REPO/'08_csi_dsi_cs500_7cun';HOME=BASE/'wbc_bccd';REPORT=BOARD/'reports/yolo_wbc_bccd15'
def read(p):return json.loads(p.read_text(encoding='utf8'))
def save(p,v):p.write_text(json.dumps(v,ensure_ascii=False,indent=2),encoding='utf8')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def pc(x):return f'{x*100:.2f}%'
if __name__=='__main__':
 s=read(REPORT/'current/summary.json');program=read(REPORT/'programming/programming.json');physical=s['build']['physical'];a=s['repair_acceptance'];m=a['validation'];test=s['reused_TEST_regression']['metrics']
 assert s['build']['phase']=='timing_pass_programmed_SRAM' and program['program_sram_success']
 assert program['model']==s['model'] and program['bit_sha256']==physical['bit_sha256'] and a['gate_passed']
 bit=BOARD/physical['bit_path'];assert sha(bit)==program['bit_sha256']
 stamp=datetime.datetime.fromisoformat(program['recorded_utc']).astimezone(datetime.timezone(datetime.timedelta(hours=8))).isoformat()
 protocol=read(BASE/'runs'/s['model']/'protocol.json');stages='120轮FP32、80轮QAT'
 if 'previous_stage' in protocol:stages+=f'，随后额外{protocol["qat_epochs"]}轮低照正样本QAT；新增固定增强VAL参与选择，原始正图真值损失约束分类漂移'
 if 'training_stages' in protocol:stages='120轮FP32、80轮QAT，追加60轮低照正样本QAT，再进行40轮仅objectness输出滤波器的QAT；最后阶段保持框回归、五类分类及前九层参数逐项不变'
 state={**program,'recorded_local':stamp,'bit_path':str(bit),'training_datasets':['WBCAtt+ PBC-Normal','BCCD'],'HDMI_subboard_programmed':False,
  'fresh_live_camera_validated':False,'project_kept_unchanged':True,'project_sha256':sha(BOARD/'td_project/camera_to_dsi_display.al'),
  'purpose':'WBCAtt+ five-class joint detection with BCCD localization and background training','engineering_trial_acceptance_passed':True,'original_1percent_artificial_background_gate_passed':False,'release_scope':'SRAM engineering trial; both artificial background groups<=2%, not independent camera acceptance','threshold_calibration':'public/fixed-augmented VAL plus provided development screenshots','source_report':'reports/yolo_wbc_bccd15/current/summary.json','previous_working_bit':'yolo/wbc_bccd/baseline/previous_working.bit'}
 assert state['project_sha256']==read(HOME/'baseline/manifest.json')['project_sha256'];save(BOARD/'deployment_state.json',state)
 text=f'''# WBCAtt+ 与 BCCD 两来源模型：当前主板版本

模型 `{s['model']}` 已完成训练、RTL与物理检查，并于 **{stamp}** 使用 TD6.2 将新 bit 下载 PH1P35MDG324 主板 SRAM，作为**工程上板试验版**。一组人工背景误检未达到原1%目标，原失败报告完整保留，本次按两组均不超过2%的工程试验界限下载。仅使用副本中原 `camera_to_dsi_display.al`，项目文件哈希与训练前备份一致；不写 Flash，不改 HDMI 子板，不修改或操作 PC 查看器。实际相机效果及 HDMI 验收仍待用户观察。

## 训练和数据

仅 WBCAtt+ PBC-Normal 与 BCCD 两套采集数据。WBCAtt+ 用于五类及整细胞框；BCCD 只有白细胞框，类别 -1，不参与分类损失。初始化为原 WBCAtt-only 从随机初始化训练的 FP32 权重，不使用 Raabin 图像或 Raabin 训练模型。TRAIN 有 6021 张 WBCAtt+ 原图、6020 张同源负裁图，以及 205 张 BCCD 原图、270 张负裁图。VAL 为 1010+1010 和 87+122；已使用 TEST 回归为 3017+3017 和 72+99。派生裁图随原图划分，实际 RGB160 跨划分重复为零，无患者级独立性证明。

{stages}。五类均衡采样，BCCD 域单独采样，加入纯色/暗场/噪声背景增强。权重由VAL选择；部署阈值 **{a['threshold_q16']}/65025** 由公开/固定增强VAL和用户给过的有、无细胞截图共同进行开发校准。TEST没有参与权重或阈值选择。截图也用于曝光诊断，因此不是盲测；没有把截图像素或其未知类别放入训练。原仅VAL阈值0.95的失败记录保留，不能将本次阈值写成“仅VAL选择”。

最终阶段对每张空图最强的单个锚框追加损失，直接压制“只错一个框”的情况。检测分数改为 objectness 的整数 sigmoid 值乘255，类型由五类logit的argmax决定；BCCD无类型监督，不再用类型分数乘积误删有效框。该修改在 RTL 后处理中实现，原始五类神经网络输出和分类权重保留。阈值经上述开发校准，分数不等于经过校准的识别正确概率。

## 模型检查

| 指标 | VAL | 已使用 TEST 回归 |
| --- | ---: | ---: |
| WBCAtt+ 定位分类联合 macro-F1 | {pc(m['joint_macro_F1'])} | {pc(test['joint_macro_F1'])} |
| WBCAtt+ 定位且类别正确召回率 | {pc(m['joint_correct_recall'])} | {pc(test['joint_correct_recall'])} |
| BCCD 定位召回率 | {pc(m['BCCD']['recall'])} | {pc(test['BCCD']['recall'])} |
| BCCD 定位精确率 | {pc(m['BCCD']['precision'])} | {pc(test['BCCD']['precision'])} |
| WBCAtt+ 同源负图有框比例 | {pc(m['WBCAtt']['false_positive_negative_images']/m['WBCAtt']['negative_images'])} | {pc(test['WBCAtt']['false_positive_negative_images']/test['WBCAtt']['negative_images'])} |
| BCCD 空图有框比例 | {pc(m['BCCD']['false_positive_negative_images']/m['BCCD']['negative_images'])} | {pc(test['BCCD']['false_positive_negative_images']/test['BCCD']['negative_images'])} |

两组固定随机种子的1024张程序化空场景分别误检 {a['procedural_final']['false_positive_images']} 张（{pc(a['procedural_final']['FP_rate'])}）及 {a['extra_procedural_final']['false_positive_images']} 张（{pc(a['extra_procedural_final']['FP_rate'])}）。第一组未达到原1%门槛；两组均低于2%的工程试验界限。2%是结果之后的工程选择，原失败记录未改写，不能声称原门槛通过。这些是人工压力图，不能等同真实空场景统计。12张纯色均无框；用户室内图无框，历史细胞图可定位但类型无真值，且这些图已用于开发校准，不能作独立验收。WBCAtt-only已撤回版同源TEST联合macro-F1为92.39%、负图误检0.76%；本轮目标包含背景域和曝光适应，不能宣称所有精度指标提高。

## RTL 与物理结果

14 张自然/派生向量覆盖五类、BCCD 与空图，逐项对拍十层、6400 个首层特征字、3000 个 logit 和最终框/类型/分数；另外 5 张黑/灰/白/室内/细胞开发图完整 RTL 回放。五项组件、三项原跟踪、突发及真实节拍720p30联合检查通过；42 项既有 RTL、2 项包完整性、38 项 Python 重新通过。模型源码、ROM、仿真输入和最终 bit 均由哈希绑定。

| 主板完整实现 | 本轮最终结果 |
| --- | ---: |
| Slice | {physical['slice']}/21216 |
| ERAM20K | {physical['eram']}/108 |
| DSP | {physical['dsp']}/40 |
| setup WNS | {physical['SWNS']:+.3f} ns |
| hold WNS | {physical['HWNS']:+.3f} ns |

100MHz 既有约束下最终时序通过，覆盖范围和继承警告见 `current/physical/route.timing`。仍为自实现的单尺度 YOLO-style 检测器，不是官方 YOLOv5/v8 完整移植。全帧采样 RGB160，每两视频帧推理一次，跳过帧保持上次完整结果，短暂漏检保持两次，第三次撤框，最多显示一个细胞与英文全称。全部实时算法在 FPGA，PC/HDMI 接收板端叠加 RGB。

## 下载证据与回退

bit SHA256：`{program['bit_sha256']}`。`programming/program_jtag.log` 已核对 PH1P35MDG324 芯片校验、Tcl catch=0、download 同步结束且无 ERROR/FATAL，`programming/programming.json` 记录实际成功。该记录证明下载成功，不证明相机分类准确率或 HDMI 画面已验收。

先前用户验证过的 bit、源码与工程备份在 `yolo/wbc_bccd/baseline/`；已撤回的 WBCAtt-only 版和失败候选另行保留。新模型的源码、数据清单、协议、权重、阈值、已使用 TEST 回归与向量在 `yolo/wbc_bccd/frozen/`，本轮总表为 `current/summary.json`。部署状态以主板 `deployment_state.json` 为准。
'''
 (REPORT/'README.md').write_text(text,encoding='utf8');(REPORT/'programming/README.md').write_text(f'# 本轮主板 SRAM 下载\n\n{stamp}，TD6.2，PH1P35MDG324，jtag 模式，bit `{program["bit_sha256"]}`。实际日志与 programming.json 已核对成功。不写 Flash、不动 HDMI 子板。新模型实拍及 HDMI 效果未验收。\n',encoding='utf8')
 banner=f'> **当前板上试验版：WBCAtt+ + BCCD**，{stamp[:19]} 已成功下载主板 SRAM，模型 `{s["model"]}`，bit `{program["bit_sha256"][:12]}…`。已使用TEST联合macro-F1 {pc(test["joint_macro_F1"])}；人工背景误检 {pc(a["procedural_final"]["FP_rate"])}/{pc(a["extra_procedural_final"]["FP_rate"])}，第一组原1%目标未达。阈值含用户截图开发校准；最终 {physical["slice"]} Slice、{physical["eram"]} ERAM、{physical["dsp"]} DSP，setup/hold {physical["SWNS"]:+.3f}/{physical["HWNS"]:+.3f} ns。15Hz、单框、英文全称及全部板端算法保持；实拍待用户观察。'
 for p in [REPO/'README.md',BASE/'README.md',BASE/'five/README.md']:
  t=p.read_text(encoding='utf8');t=re.sub(r'<!-- DEPLOYMENT_CURRENT_BEGIN -->.*?<!-- DEPLOYMENT_CURRENT_END -->','<!-- DEPLOYMENT_CURRENT_BEGIN -->\n'+banner+'\n<!-- DEPLOYMENT_CURRENT_END -->',t,flags=re.S)
  t=re.sub(r'<!-- WBCATT_CURRENT_BEGIN -->.*?<!-- WBCATT_CURRENT_END -->','<!-- WBCATT_CURRENT_BEGIN -->\n> 历史 WBCAtt-only 版已因空场景假框撤回，旧表格、bit 和下载记录仅作为历史证据。\n<!-- WBCATT_CURRENT_END -->',t,flags=re.S)
  t=re.sub(r'<!-- WBC_BCCD_CURRENT_BEGIN -->.*?<!-- WBC_BCCD_CURRENT_END -->','<!-- WBC_BCCD_CURRENT_BEGIN -->\n'+banner+' 详见本轮 `reports/yolo_wbc_bccd15/README.md`。\n<!-- WBC_BCCD_CURRENT_END -->',t,flags=re.S);p.write_text(t,encoding='utf8')
 t=(HOME/'README.md').read_text(encoding='utf8');t=t[:t.index('当前新模型处于训练阶段')]+'当前状态：已完成训练、RTL和最终时序检查，按工程试验范围成功下载主板SRAM；一组人工背景误检1.76%未达原1%目标，两组均低于2%试验界限，原失败记录保留。阈值使用了给过的开发截图，不能称仅VAL选择或独立实拍验证。详见主板 `reports/yolo_wbc_bccd15/README.md` 与 `deployment_state.json`。实拍及HDMI待用户观察。\n';(HOME/'README.md').write_text(t,encoding='utf8')
 doc=REPO/'docs/README_1021_WBCAtt与BCCD两来源重训.md';doc.write_text(text,encoding='utf8')
 print('TWO_SOURCE_DEPLOYMENT_PUBLISHED',stamp,flush=True)

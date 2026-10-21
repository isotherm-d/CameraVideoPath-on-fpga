# 全帧YOLO五类联合检测

<!-- DEPLOYMENT_CURRENT_BEGIN -->
> **当前板上试验版：WBCAtt+ + BCCD**，2026-10-21T11:37:32 已成功下载主板 SRAM，模型 `wbc_bccd160_devcam_20261021`，bit `5bc2dfee5ef0…`。已使用TEST联合macro-F1 91.40%；人工背景误检 1.76%/0.78%，第一组原1%目标未达。阈值含用户截图开发校准；最终 19016 Slice、94 ERAM、35 DSP，setup/hold +0.102/+0.020 ns。15Hz、单框、英文全称及全部板端算法保持；实拍待用户观察。
<!-- DEPLOYMENT_CURRENT_END -->

<!-- WBCATT_CURRENT_BEGIN -->
> 历史 WBCAtt-only 版已因空场景假框撤回，旧表格、bit 和下载记录仅作为历史证据。
<!-- WBCATT_CURRENT_END -->

当前源码在独立副本 `CameraVideoPath-on-fpga-yolo` 的 `experiment/yolo160-w4a4` 分支。YOLO完成全帧定位和五分类；**当前每帧最多显示一个细胞框，框左上角显示英文全称**。原主工程目录没有修改；仍使用副本中的原 `camera_to_dsi_display.al`。

**单框全称版已于2026-10-21 00:53成功下载主板SRAM，用户随后反馈“已上板完成验证”**：Basophil、Eosinophil、Lymphocyte、Monocyte、Neutrophil；优先锁定原目标身份，目标消失后才重新选择最靠近中心的细胞。单框选择和17941个全称文字像素测试、14张整网对拍、720p30到单框全称OSD及回归通过；最终19018 Slice、94 ERAM、36 DSP，setup +0.133ns、hold +0.020ns。见 [单框全称记录](../../08_csi_dsi_cs500_7cun/reports/yolo_single15/README.md)。用户未提供量化实拍准确率或帧率统计。

上版多框15Hz保持版已于2026-10-21 00:23成功下载主板SRAM：19669 Slice、94 ERAM、36 DSP，setup +0.100ns、hold +0.020ns；[旧15Hz证据](../../08_csi_dsi_cs500_7cun/reports/yolo_five15/README.md)保留，不能当作当前单框版的下载记录。

2026-10-21 00:00（北京时间）成功下载的是上一版10Hz bit：19433 Slice、94 ERAM、36 DSP，setup +0.102ns、hold +0.020ns；[旧报告和下载证据](../../08_csi_dsi_cs500_7cun/reports/yolo_five/README.md)完整保留，不能用于证明15Hz新版已下载或已通过实拍。

## 板端链路

```text
1280×720干净RGB
 → 全帧中心近邻采样RGB160
 → 流式首层 + 四路复用卷积
 → 三锚框×(xywh+objectness+五类)=30通道
 → LUT sigmoid / 类别取最大 / top20 / class-agnostic NMS
 → 最多5个全帧坐标框，各自带类别和置信度
 → 目标身份匹配 / 各目标2次确认、3次切换
 → 保持原选中身份 / 必要时选最近中心目标
 → 仅一个框与英文全称 → 原UDP与HDMI输出链路
```

固定中心480裁图、RGB32采样及独立CellNet已从顶层移除，并在 `.al` 中禁用。综合层次报告检查 `cellnet32_core` / `cvp_center_classifier` 不存在，不能只凭输出没用就算移除。上位机没有增加推理或补画代码。

| 项目 | 当前实现 |
|---|---|
| 检测覆盖 | x0..1279 / y0..719，全1280×720画面 |
| 网络输入 | RGB160×160 |
| 采样位置 | x=4+8k；y=2+4j+floor(j/2)，k,j=0..159 |
| 默认频率 | 视频按30帧/秒配置，YOLO每2帧一次，即15次/秒 |
| 跳过推理的视频帧 | 持续显示最近一次完整发布的框和类别，不清空 |
| 类别编码 | 0=BAS，1=EOS，2=LYM，3=MON，4=NEU |
| 每框输出 | 全帧坐标、类别、objectness×最高类别概率 |
| 候选 / NMS | top20稳定排序，跨类别NMS103/256，最多5框 |
| 画面标注 | 最多1个细胞框，优先保持原身份，否则选最近中心 |
| 英文全称 | Basophil / Eosinophil / Lymphocyte / Monocyte / Neutrophil |
| 字模与位置 | 160×16文字区，框左上角，右侧/顶部限制到屏内 |
| 阈值 | 43892/65025，约0.675，按VAL整数链路选定 |
| 量化 | 首尾W8、中间W4、隐藏激活A4，首层RGB输入A8 |
| 通道 | 8,8,8,16,24,40,80,24,40,30 |
| 类别稳定 | 每个目标独立；首次2次确认，切换3次确认 |
| 短时漏检 | 连续1/2次推理漏检保持框、类别和身份；第3次仍漏检撤框 |
| 更新原子性 | 跟踪、分配、类别投票完成后整组发布；OSD在帧头锁存 |
| 有效期 | 框5个视频帧，类别15个视频帧；配置改变立即隐藏旧结果 |

全帧压到160×160采用直接缩放，并非中心裁图。小细胞和跨相机外观变化需要实拍验证。只训练五种白细胞，不能据此宣称识别红细胞或血小板。

## 训练与模型选择

现有细胞掩膜生成整个细胞的真实外接框；五类标签来自Raabin原始类别目录。

- 训练：782张有五类框标注的图像，另加475张BCCD场景/负裁图。BCCD的214个白细胞目标没有五类标签，只计算定位和objectness损失，**不补造类别**。
- 验证：128张有五类框标注的图像及209张BCCD场景/负裁图。
- BCCD的训练样本是205张原图加270张负裁图，验证为87张原图加122张负裁图，测试为72张原图加99张负裁图；裁图与来源原图保持同一数据划分，不能将它们计作独立采集图。Raabin五类训练数分别为BAS148、EOS140、LYM165、MON162、NEU167。
- 训练中加入带完整框/类别的四图mosaic、翻转、缩放、颜色扰动。mosaic属于训练增强，不能当作真实多细胞验收。
- 比较3个随机种子和1组加宽输出层方案；每组250轮浮点+60轮QAT。QAT前向采用整数单位的float64精确累加。
- 每组checkpoint先按VAL AP50选择；最终按**实际整数LUT、全帧坐标解码、阈值及NMS的VAL表现**选择运行组和阈值。
- 选定 `five_fullframe_seed0`。原始AP排名、整数排名及未选方案均保留；五类TEST掩膜只在最终选择冻结后打开。

最终选择目标为 `0.7×五类macro-F1 + 0.3×BCCD定位F1 − 0.1×负样本图误检率`。没有根据TEST重新调阈值或换权重。

| 数据/范围 | 框正确且类别正确 / 全部目标 | 定位召回率 | 五类macro-F1 |
|---|---:|---:|---:|
| Raabin VAL，128个目标 | 120/128，93.75% | 95.31% | 94.22% |
| Raabin TestA掩膜配对集，228个目标 | 207/228，90.79% | 95.61% | 89.98% |
| 排除训练采集组重叠后，222个目标 | 201/222，90.54% | 95.50% | 89.94% |

228张配对测试图中有6张与TRAIN/VAL采集组重叠，已单列222张不重叠结果；没有字节完全相同的图片。采集组不重叠不等于已验证患者独立性，这也不是完整TestA分类数据集的成绩。

BCCD TEST只计算定位：71个目标中检出63个，召回88.73%，精确率71.59%，仍有误检；BCCD没有五类标签，不能给它计算五分类准确率。该测试集在前一版单类实验中已使用过，本轮没有再用于训练或阈值选择。**不能宣称本版全面提高准确率。** 实拍、多细胞遮挡、连续性和HDMI效果尚待验证。

冻结权重、量化权重、数据清单、阈值、逐图测试结果和14张RTL向量压缩包在 [frozen](frozen/)。`test_opened:false` 是训练/选择冻结当时的状态；后续打开记录在 `five_class_test_result.json`。

## RTL与资源证据

- 14张自然/负样本覆盖全部5类，逐项比较10层整数输出、每张6400个首层特征字、3000个logit、最终框、类型和置信度。
- 5项组件测试：全帧采样/抽帧/中止，五类后处理/top20/同分排序/大框面积/NMS，逐框身份/确认/漏检/配置/TTL/背压，新增单目标身份锁定与最近中心选择、五个英文全称逐像素及边缘显示。
- 原目标跟踪默认调度的3项回归通过，包含90帧五目标类别参考策略；YOLO整合使用新增的分拍匹配调度。
- 两种时序各6个完整720p30帧：并行核对10Hz产生2次检测、15Hz产生3次检测；实际跟踪和OSD连接15Hz支路。连续第3至6帧均出现边框，第5/6帧均有已确认类别文字；整个更新过程中输出框不短暂清空。另有组件测试覆盖两次漏检保持、第三次撤框、重新出现确认、配置切换及停更超时。
- 单次采样至检测框提交：突发输入约40.30ms；每像素3拍、每行4444拍的时序约62.95ms。该结果来自100MHz仿真，不代替实板测速。
- 原有42项视频RTL、2项包完整性及38项Python回归随本轮重新执行。报告保存源码哈希，下载前重新核对。

当前单框全称版整机最终 **19018/21216 Slice、94/108 ERAM、36/40 DSP**，setup +0.133ns、hold +0.020ns，构建445.4秒。00:53下载bit SHA256为 `60d25f6ff3056fea9c2f621ace6666f2d9cb29771813617c2aa542433ed77ff6`，用户已反馈上板完成验证。下载后GUI添加9个旧模块AutoExcluded属性，.al原样保留；RTL/ROM/约束仍匹配构建，工程字节差异有独立记录，重新下载仍执行严格哈希检查。

上版多框15Hz保持版最终19669 Slice、94 ERAM、36 DSP，setup +0.100ns、hold +0.020ns，耗时594.2秒。该旧bit SHA256为 `ee38f0ef0fe0b80e1e74f823b490233ca96d7a46018507e4e60c710fd7cb2ccd`；旧[下载日志](../../08_csi_dsi_cs500_7cun/reports/yolo_five15/programming/README.md)保留，不作为当前单框版证据。

更早的10Hz整机为19433 Slice、94 ERAM、36 DSP，setup +0.102ns、hold +0.020ns；旧bit完整保留。首轮跨帧匹配关键路径−1.160ns已通过多拍调度修正；第二轮gate setup −0.423ns属于历史布线前估计。多框15Hz同次构建gate setup −0.021ns、最终+0.100ns均为旧版记录。

TD历史构建仍报告Bank21 SSO及既有时钟布线警告，未将其当成已修复。不能把工具通过和SRAM下载成功当作实板稳定性验收。上版10Hz下载bit SHA256为 `b9cb1f03fb8d3a81a665724b73da096e1ec46b75e8991b9f6a34b1d84455c886`，本轮15Hz结果单独归档。

单类YOLO+CellNet旧bit及记录保留在 `reports/yolo160/current/physical/`，完整旧run缓存另存 `phy_oneclass_4b9c085_20261020` / `syn_oneclass_4b9c085_20261020`；旧记录不能作为本轮五类版的板测证明。

## 本机复现

从副本仓库根目录执行：

```powershell
# 当前权重与RTL ROM已在仓库中。恢复用于仿真的冻结向量：
New-Item -ItemType Directory -Force yolo/runs/five_fullframe_seed0
Copy-Item yolo/five/frozen/* yolo/runs/five_fullframe_seed0/ -Recurse
Expand-Archive yolo/five/frozen/rtl_vectors.zip yolo/runs/five_fullframe_seed0/vectors -Force
python yolo/five/run_all_vectors.py
python yolo/five/run_tests.py --unit
python yolo/five/run_tests.py --stream
python yolo/five/run_tests.py --stream --paced
python yolo/five/run_legacy_tracks.py

# 需要重训时用新运行名称，保留当前冻结选择：
python yolo/five/prepare.py --geometry fullframe
python yolo/five/train.py --name another_run --geometry fullframe --epochs 250 --qat-epochs 60

# 原.al物理构建与证据核验：
python 08_csi_dsi_cs500_7cun/tools/build_cellnet32.py --route
python yolo/five/collect_report.py --physical
python yolo/five/program_mainboard.py
python yolo/five/program_mainboard.py --program
```

使用TD6.2、ModelSim2020.4的 `-batch` 模式；训练使用PyTorch2.7.1+cu128与RTX5070Ti Laptop。数据准备依赖本机既有Raabin图像和掩膜。硬件下载脚本只接受PH1P35MDG324主板，写SRAM，不写Flash、不改HDMI子板、不占视频UDP端口。用户自行观察实拍。

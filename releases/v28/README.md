# V28 发布 —— 新增子板 HDMI_OUT 实时回显工程

本版本在仓库中新增第二块板卡的完整工程：**HDMI_OUT**（EG4D20 / MLKPAI-F01），接收主板镜像 RGMII 视频流，本地重组缓存后输出 1280×720@60Hz HDMI，并叠加安路 logo OSD。主板相机工程维持 v27 验收状态不变。

## 内容

- `HDMI_OUT/` 完整工程：RTL、TD 5.6 工程(`HDMI_OUT.al`)、引脚/时序约束、ModelSim 全链路仿真环境
- `HDMI_OUT.bit`：子板比特流（PROGRAM_SRAM 加载，断电丢失）
- 仿真向量与脚本：`HDMI_OUT/tools/sim/`（全分辨率真机工况 11 帧、DDR 仲裁压力扫描、OSD 落点账本回归）

## HDMI_OUT 使用

1. TD 5.6.59063 打开 `HDMI_OUT/HDMI_OUT.al`（器件 EG4D20EG176），综合→布局布线→生成比特流；或直接加载本目录 `HDMI_OUT.bit`。
2. 主板 ETHB 与子板网口经网线点对点连接（RGMII 镜像 TX）。
3. 子板 HDMI 输出接显示器：上电即显示主板画面，右上角为安路 logo OSD。

## 验证状态

- 全分辨率逐字节回归：真机工况(1920 包/帧 × 11 帧) PASS；含丢包注入场景 PASS；小分辨率协议场景 8/8 PASS。
- DDR 压力扫描：写优先/读优先/三档刷新冻结窗口（含 20% 总线开销）与 2ms 一次性总线黑窗，均零撕裂、零写读缓冲碰撞。
- OSD：16384×9 EBR 位图，落点账本仿真逐像素 diff=0，上板显示正常。
- 门级资源：LUT 7556/19600（38.9%）、BRAM 44/64、DSP 1/29、PLL 4/4。

## 已知问题

- 偶发丢包（RGMII 采样相位随电源状态漂移 → CRC 偶发全错）会在画面上留下瞬时冻结带（已由洞填冻结延展缓解，此前为黑带）。诊断 LED：LED2=crc_bad、LED3=crc_ok；根治需用 `HDMI_OUT/tools/sim/sweep_cphase.sh` 配合盲扫 CPHASE 求稳定采样点。
- 布线存在 a_tx_clk 方向死逻辑路径的时序违例，经验证不影响收流显示，保留未处理。

## 文件校验

manifest.json 记录 .bit 的 SHA256 与文本文件(LF 归一)校验。

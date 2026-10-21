# v30 候选：主板网络输出与 DSI 裁剪

2026-10-12，基于 v29 主板源码。当前顶层只保留相机、ISP 和网络输出，主板 7 寸 DSI 屏及其 DDR 帧缓存已裁掉。ETHB 镜像输出仍可供 HDMI_OUT 子板显示。用户于 2026-10-12 反馈上板功能无误；不替换 v29 历史发布。

## 依赖核查结果

DSI 是 ISP 像素流的末端显示消费者。它与保留通路共享输入和基础时钟，但保留通路不依赖它的任何输出。

| 接口 | 原用途 | 裁剪处理 |
|---|---|---|
| pack_4 的 RGB/SOF/frame_id | 同时提供网口数据及本地显示输入 | 保留 pack_4 和完整网口连接 |
| 主 PLL 的 C0/C1 | 100MHz ISP/控制、24MHz 相机配置与 MCLK | 保留，PLL 配置和复位不变 |
| 主 PLL 的 C2/C3 | DSI 参考时钟、10MHz 屏配置时钟 | 顶层输出断开，删除对应专用时钟约束 |
| DDR 初始化、读写 ready/busy、读指针 | 本地屏幕帧缓存调度 | 仅在显示支路内使用，全部移除 |
| DSI lock/config_done/hs_ready | 屏幕启动、时序与发送 | 无相机/ISP/网口消费者，全部移除 |
| 网口诊断、状态包、AE/AWB | 从相机/ISP/配置域取得数据 | 不依赖 DDR/DSI，保持原连接 |
| O_screen_pwm | 屏幕背光 | 保留 R11 端口和约束，输出改为 0 |

移除十二个顶层实例：96→128bit 转换、裁剪、video_in、video_out、mc_to_user_interface、DDR wrapper、video_source、mixer、RGB24→32、DSI packet、display_config、MIPI D-PHY TX。DDR 和 DSI TX 顶层端口也移除；MIPI RX 端口保留。

十四个保留的相机、解包、行重整、组FIFO、ISP、启动门控、advanced、pack_4、网口PLL、命令接收和网口发送实例，其端口连接与 v29 源码逐项一致。没有引入相机反压、修改帧号/状态协议，或改变七模式处理实现。

## 实测资源与时序

同一器件 PH1P35MDG324、同一 TD 6.2.168116、1280×720@30fps，均采用布线后的报告。

| 指标 | v29 | v30 无 DSI 候选 | 变化 |
|---|---:|---:|---:|
| Slice | 15006 / 21216，70.73% | 10523 / 21216，49.60% | -4483，-29.9% |
| LUT6 | 12744 | 8484 | -4260 |
| FF | 15462 | 10304 | -5158 |
| ERAM20K | 65 / 108 | 51 / 108 | -14 |
| DSP | 10 / 40 | 10 / 40 | 不变 |
| PLL | 4 / 6 | 2 / 6 | -2 |
| DDR byte | 6 | 0 | 显示 DDR 已移除 |
| MIPI TX | 1 | 0 | DSI 发送硬件已移除 |
| MIPI RX | 1 | 1 | 相机接收保留 |
| Setup WNS / TNS | +0.102ns / 0 | +0.116ns / 0 | 无违例 |
| Hold WNS / TNS | +0.020ns / 0 | +0.020ns / 0 | 无违例 |

剩余 Slice 10693、ERAM 57、DSP 30。它们是器件剩余数量，分类器挂接后仍需重新综合和布线。

## 工程与复现

- `td_project/camera_to_dsi_display.al`：已移除显示专用源码/IP 注册，工程名沿用以兼容现有构建脚本。
- `td_project/camera_to_dsi_display.sdc`：删除 DDR/DSI 专用时钟和跨域分组。
- `tools/td_templates/`：移除显示 IP 注册和 DDR 专用 ADC/SDC 加载，隔离构建与 GUI 工程一致。
- 旧显示模块源码保留在磁盘，但不再实例化或注册进当前显示支路；恢复完整硬件使用历史版本源码和比特流。
- `tools/run_v29_regression.ps1`：复现 v29 的 22 项 RTL 测试及两组线上包校验；兼容本机 ModelSim 2020.4 的 -novopt 提示。

```powershell
./tools/run_v29_regression.ps1 -OutputDir <新的仿真输出目录>
python tools/prepare_v26_build.py --name <新的隔离构建目录名>
```

进入 prepare 输出的目录，依次执行 TD 的 `td_commands_prompt.exe synthesis.tcl` 与 `td_commands_prompt.exe physical.tcl`。初次隔离构建目录是 `C:/Users/cqm87/Desktop/2026/tmp/v26_task135/v30_no_dsi_20261012`；修复 GUI 运行缓存后的最新完整构建位于主工程 `td_project/camera_to_dsi_display_Runs/`。

候选比特流、布线资源与时序报告、回归结果和 manifest 位于 `../old/releases/v30-candidate/`。验证状态以该目录 README 和 manifest 为准。

2026-10-12 工程载入修复：旧 `isp/awb/ram/blk_mem_gen_awb_delay_signal.vhd` 虽标记 AutoExcluded，GUI 刷新仍会分析它并报 `ph1_macro.PH1_COMPONENTS` 缺库。现已从 `.al` 和构建模板移除旧 `hdl_source/isp/` 及旧 AWB RAM IP 注册，实际使用的 `uiisp_beta` 解包器、`uial2axis`、`isp2`、PLL 和 MIPI RX 均保留。没有修改 RTL 或删除磁盘源码。TD 6.2 隔离重综合通过；应关闭并重新打开 `.al` 以丢弃 GUI 已加载的旧文件列表。TD 5.6 的本机打开记录报过 Unknown device PH1P35MDG324，请使用 TD 6.2。

## 板级验收范围

本次没有烧写开发板或修改 Flash。下一次上板应通过 PROGRAM_SRAM 加载候选比特，确认 ETHA 收图、ETHB 子板回显、七模式、UDP 6001 配置与 UDP 6002 状态、AE/AWB 和按键；主板本地 DSI 屏预期关闭。恢复完整旧版使用 v29 比特流。

## GUI 运行缓存修复

最新 GUI 错误为 `USR-8321: cannot find ip model ... ddr2`。主工程 `syn_1/settings.cfg` 仍保存旧 DDR 的 IpADCList/IpSDCList，GUI 还从旧 phy 数据库导入了运行参数。此前修改模板和隔离构建不足以清掉这份缓存。现已备份旧 Runs 目录，并按当前源码/IP 注册重新生成主工程 syn/phy 的 .prj、settings.cfg 和流程脚本，直接使用 TD DefaultFlow 完成主工程综合、布局布线和比特流生成。

旧运行目录备份：`C:/Users/cqm87/Desktop/2026/tmp/v30_run_cache_backup_20261012_1639`。没有修改 RTL，既有 22 项回归结果仍适用；最新资源和时序已更新到上表。重新打开 TD 工程以清掉内存中的旧设计/IP 表，避免复用仍在运行的旧会话。

# HDMI_OUT 工程集成步骤（TD5.6）

工程文件已就位于本目录（`uisrc/01_rtl` 新代码、`uisrc/03_ip` 复用例程 IP、`uisrc/04_pin` 约束、`doc` 架构文档）。用户已建的空 TD 工程 `hdmi_out` 请按以下步骤装载：

## 1. 添加源文件（TD: Project → Add Sources）

把 `uisrc/01_rtl/*.v` 和 `uisrc/03_ip` 下所有 `.v` / `.vhd` 加入工程：

```
uisrc/01_rtl/            cvp_hdmi_top.v(顶层, 设为 Top)  cvp_rx_assemble.v  rgmii_cdc.v
uisrc/03_ip/uiudp_stack/ 27 个文件（含已改的 uimac_rx.v，勿用例程原文件覆盖）
uisrc/03_ip/shiftram/    shift_ram_8bit.v          (uiudp_tx/uiip_tx/uimac_tx 依赖)
uisrc/03_ip/al_pll/      pll.v  PLL2.v
uisrc/03_ip/al_softfifo/ udp_pkg_buf.v
uisrc/03_ip/uiphyrst/    uiphyrst.v
uisrc/03_ip/uifdmadbuf/  uidbuf.v  fs_cap.v
uisrc/03_ip/uisetvbuf/   uisetvbuf.v
uisrc/03_ip/uiappfdma/   uiappfdma.v
uisrc/03_ip/uieg4d_dram/ ddr1_as_ram.v  ddr1_init_ref.v  ddr1_wrrd.v  global_def.v
uisrc/03_ip/al_ip/       ddr_pll.v  hdmi_pll.v  clk_hdmi_pll.v
uisrc/03_ip/vtc/         uivtc.v
uisrc/03_ip/al_ui_hdmi_tx/ hdmi_tx.vhd + TMDSEncoder.vhd + DVITransmitter.vhd
                             + SerializerN_1_lvds.vhd + SerializerN_1_lvds_dat.vhd
                             (VHDL 实体 uihdmitx, 与例程23 完全同源; 注意目录里
                              不再有 uihdmitx.v —— 那是错误版本, 已删除)
```

## 2. 器件与约束

- 器件: EG4D20EG176（若建工程时未选对，Project Setting 里改）
- 引脚: `uisrc/04_pin/pin.adc`（ADC 约束文件加入或导入）
- 时序: `uisrc/04_pin/timing.sdc`（SDC 约束文件加入）

## 3. 编译烧录

Flow → Synthesis → Place & Route → Generate Bitstream，下载到 EG4D 板。

## 4. 联调

1. PH1P35 主板烧含 ETHB 镜像的版本（前一任务已改）。
2. 网线直连主板 ETHB ↔ 副板 RJ45（两端 YT8531 自协商 1000M，副板链路灯应亮绿）。
3. 主板上电出流后，显示器应显示相机画面（约 2 帧黑屏后出图）。
4. 不出图排查顺序见 `doc/架构文档_网口收流HDMI输出.md` 第 7 节。

## 注意

- `uimac_rx.v` 是本工程唯一修改过的例程文件（广播 IP 帧放行），从例程目录重新拷贝时必须重打此补丁。
- 副板无命令功能、无发送：协议栈 TX 恒空闲，ping 不通副板属正常（纯二层收）。
- 两端 IP 约定：主板发往 192.168.1.100；PC 控制侧不要占用该地址。

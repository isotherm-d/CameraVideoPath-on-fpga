# 网口出画面 · 操作单(摄像头 → ETHA → 电脑实时显示)

> 本轮已完成:把 `CameraVideoPath_网络模块` 合并进 08_csi_dsi 摄像头工程。
> 数据流:摄像头 1080p20 → ISP → cvp_rgb_stream_pack(新增) → cvp_eth_dbg(每 2 帧发 1 帧 = 10fps)
> → cvp_gmii_mac_tx → RGMII → 板上 ETHA 座(YT8531) → 网线 → 电脑 Python 实时显示。
> 引脚依据:《04_以太网管脚定义表-J1.xlsx》并与 05_rgmii_loop 例程交叉验证一致。

## 一、板端(你操作)

1. **网线**:板子 **ETHA 座**(靠上的那个网口,丝印 ETHA)→ 电脑网口,直连;
2. TD 打开工程(还是 `camera_to_dsi_display.al`),**右键 syn_1 → Run**,一路跑到 Generate Bitstream;
   - 本次新增了 7 个文件和网口引脚,首次编译会比之前慢几分钟,属正常;
3. 用 BitWriter 下载新 bit(路径同前,`camera_to_dsi_display_Runs\phy_1\camera_to_dsi_display.bit`);
4. 串口体检打印(CAM t=...)仍然在,不影响网口。

## 二、电脑端

1. **设静态 IP**:设置 → 网络 → 以太网 → IP 分配 → 手动:
   - IP 地址:`192.168.1.100`,子网掩码:`255.255.255.0`,网关可空;
2. **关防火墙**(或放行 UDP 6000 端口):控制面板 → Windows Defender 防火墙 → 临时关闭;
3. **装 Python 依赖**(一次性):
   ```
   pip install numpy opencv-python
   ```
4. **收图**(脚本已拷到 `04_cam_check\tools\`):
   ```
   cd E:\02_F02_FC02_PH1P35\04_cam_check\tools
   python eth_video_rx.py --width 1920 --height 1080
   ```

## 三、预期与判读

| 现象 | 结论 / 处理 |
|---|---|
| 弹出窗口显示实时摄像头画面(10fps) | ✅ 成功!按 `s` 存帧,`q` 退出 |
| 画面正常但**红蓝反色** | 颜色通道序与预期相反,`--swap` 类参数或告诉我,一行改脚本/改 RTL |
| 窗口出图但有规律性黑块/缺块 | 丢包,告诉我,把 `FRAME_SKIP` 改 3(6.7fps)再试 |
| 窗口完全不开(收不到任何包) | 依次查:网线是否插 ETHA 座、电脑 IP 是否 192.168.1.100、防火墙是否关;再不行截图给我 |
| 编译报错 | 把报错日志发我 |

## 四、本轮改动的文件清单(与体检阶段合并计)

工程内(`08_csi_dsi_cs500_7cun`):
- `user_source/hdl_source/net/` 新增 7 个文件:网络模块 4 件套(cvp_eth_dbg / cvp_gmii_mac_tx / cvp_mdio_ro / cvp_async_fifo)、转换模块 cvp_rgb_stream_pack、125M 时钟 pll_gmii125 + 其 wrapper;
- `user_source/hdl_source/design_top_wrapper.v`:新增网口端口、3 个实例、MDIO 三态;
- `user_source/hdl_source/isp/isp_top.v`:新增 AWB 96bit 观测口(纯增量);
- `user_source/constraints_source/pin.adc`:新增 ETHA 引脚 9 条(含 TXCK OUTDEL=3);
- `td_project/camera_to_dsi_display.al`:登记新文件(CompileOrder 62~68)。

注意:本地 `E:\TD_6.2.1\PROJECT\CameraVideoPath` 的 constraints/pin.adc 是**旧板(HX1P35B)**的,**没有**采用;网口引脚全部以本资料包官方引脚表为准。

## 已做的网络模块修改(相对原包,备份时一并记录)

1. `cvp_gmii_mac_tx.v`:帧内包序计数器 `r_pkt_seq` 由固定 11 位改为 `$clog2(PKTS_PER_FRAME)` 位宽自适应。原包按 720p(每帧 1920 包)设计,11 位够用;改成 1080p 后每帧 4320 包,11 位(最大 2047)导致帧尾判断 `r_pkt_seq == PKTS_PER_FRAME-1` 永不成立、帧号永不递增、包偏移只覆盖前 2.9MB 循环,PC 永远拼不齐一帧(现象:心跳正常但 "no video stream")。
2. `isp_top.v`:新增 AWB 96bit 观测输出口(纯增量,原通路零改动)。
3. 新增 `cvp_rgb_stream_pack.v`:96bit 像素拍 → 单像素流转换(内含 96bit×1024 突发缓冲)。
4. 新增 `pll_gmii125.v` + wrapper:25M→125M GMII 时钟(拷贝自 rgmii 例程)。
5. `timing.sdc`:网口 125M 时钟加入异步时钟组(跨域全部走 Gray FIFO/双拍同步,不做时序分析)。
6. `i_dbg_flags` 接真实诊断:心跳状态页实时显示 相机I2C配置完成/AWB观测口有数据/转换器在发像素/像素非全零 四个粘滞标志。

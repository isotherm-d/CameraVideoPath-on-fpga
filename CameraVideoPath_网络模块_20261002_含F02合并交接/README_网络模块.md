# CameraVideoPath 网络模块(以太网视频调试通路)打包说明

打包日期:2026-10-02
来源工程:`C:\Users\cqm87\Desktop\2026\CameraVideoPath`

背景:开发板更换为 MLKPAI-F02 后无 HDMI 座,显示读出(OSD 后)的
1280×720 RGB888 像素流经底板 ETHA 网口(YT8531 PHY,RGMII 千兆)
以 UDP 发给 PC,替代 HDMI 做调试输出。2026-10-02 网口已打通,
当前 `GEN_TESTPAT=0` 走真实相机像素流。

## 文件清单

路径为工程内相对路径,解压后按原位放回即可。

| 文件 | 说明 |
|---|---|
| `rtl/out/cvp_eth_dbg.v` | 网络通路顶层:跳帧(FRAME_SKIP)→ 8bit 异步 FIFO → Gray 信用流控;内部例化 u_mac / u_mdio;含内置彩条发生器(GEN_TESTPAT) |
| `rtl/out/cvp_gmii_mac_tx.v` | 自研极简千兆 GMAC 发送 + RGMII DDR 串化:前导/SFD、ETH/IP/UDP 头、6B 应用头、FCS;信用机制保证整包起发 |
| `rtl/out/cvp_mdio_ro.v` | YT8531 MDIO 管理引擎:上电引导读-改-写 EXT_0xA001.bit8(使能 PHY 对 MAC 方向 RX_CLK 2ns 延时,消除 RGMII 采样不确定性),之后循环读 BMSR.bit2 → o_link |
| `rtl/mem/cvp_async_fifo.v` | 共用依赖(非本次新写):8bit 异步 FIFO,像素 75M → GMII 125M 跨时钟 |
| `tools/eth_video_rx.py` | 上位机接收端:UDP 收包按 offset 拼帧,OpenCV 显示;s=保存当前帧,q/ESC=退出 |
| `tools/eth_dbg_sim/oddr_stubs.v` | 仿真用 ODDR(PH1P_LOGIC_HD_ODDR)行为 stub,真实原语由 TD 提供 |
| `tools/eth_dbg_sim/tb_eth_dbg_smoke.v` | cvp_eth_dbg 整链冒烟仿真:FRAME_SKIP=1 连发 2 帧,抓线上帧写 eth_out.bin |
| `tools/eth_dbg_sim/tb_mac_tx_smoke.v` | cvp_gmii_mac_tx 冒烟仿真:生产者写 2 包已知图案 + 2 块信用,抓线上帧写 mac_out.bin |
| `tools/eth_dbg_sim/verify_eth_out.py` | 校验 eth_out.bin:前导/SFD、以太网/IP/UDP 头、IP 校验和、应用头、payload 图案、CRC32/FCS |
| `tools/eth_dbg_sim/verify_mac_out.py` | 校验 mac_out.bin:同上(payload 图案 (i*7+13)&0xFF) |

未收入本包的相关文件:
- `rtl/top/cvp_top.v` — 主工程顶层(非网络模块本身),本模块例化于其中 L537 `u_eth_dbg`
- `tools/eth_dbg_sim/tb_cam_cfg_smoke.v` — I2C 相机配置(cvp_cam_cfg/uii2c)仿真,不属网络模块
- `constraints/pin.adc` / `timing.sdc` — 含网口引脚/约束,属整工程约束文件

## UDP 协议(大端)

每包:
```
前导 7×0x55 + SFD 0xD5 | ETH 14B | IP 20B | UDP 8B | 应用头 6B | 数据 1440B | FCS 4B
```
UDP 载荷 = 1446B,以太网帧 1488B,线上 1500B。

应用头(6B,MAC 域自插):
- byte0 `frame_seq` 帧计数(mod 256,每发满一帧包数 +1)
- byte1 `fmt` = 0x01(RGB888 连续帧流)
- byte2..5 `offset` 本包数据在整帧字节流中的偏移 = 包序 × 1440

一帧 = 1280×720×3 / 1440 = **1920 包**;PC 按偏移写入帧缓冲,缺包留黑洞。

## 关键参数(cvp_eth_dbg 顶部)

| 参数 | 当前值 | 说明 |
|---|---|---|
| FRAME_SKIP | 3 | 每 3 帧发 1 帧 ≈ 20fps,~450Mbps 线速率;链路稳后可改 2(30fps,~750Mbps) |
| DATA_BYTES | 1440 | 须被 3 整除;IMG_W×IMG_H×3 须被其整除 |
| GEN_TESTPAT | 0(cvp_top 中) | 1=内置彩条(不依赖上游 valid),0=真实相机像素流 |
| IP_SRC / IP_DST | 192.168.1.66 / 192.168.1.100 | PC 网卡须设静态 IP 192.168.1.100/24 |
| UDP 端口 | 6000 / 6000 | |
| MAC_DST | 广播 | 板不实现 ARP |
| PHY_ADDR | 1 | YT8531 MDIO 地址 |

## 在 cvp_top 中的接线(rtl/top/cvp_top.v L537)

- 输入:`i_clk_pix`=w_clk_pixel(75M),`i_valid/i_rgb`=w_osd_valid/w_osd_rgb(OSD 后像素流);
  `i_clk_gmii`=w_clk_gmii125(375M÷3);`i_clk_100m`=w_clk_100m
- 输出:`o_rgmii_txd/tx_ctl/txc` → 底板 ETHA;`o_eth_mdc`/MDIO(板上 io_eth_mdio 三态)
- LED(低有效):o_led_link 链路、o_led_act 发包闪烁、o_led_dly = PHY RX 延时已使能
- `o_eth_rst_n` 恒 1(PHY 上电自复位)

## 上位机用法

```bash
pip install numpy opencv-python
python tools/eth_video_rx.py                # 默认 0.0.0.0:6000, 1280x720
python tools/eth_video_rx.py --scale 0.5 --save-dir out_frames
```

## 仿真(ModelSim 2020.4)

`tb_eth_dbg_smoke` / `tb_mac_tx_smoke` 各自从 dut 的线上两级寄存
(r_out_d/r_out_e)抓完整以太网帧写 bin 文件,再用对应 `verify_*.py`
逐字段校验;RGMII 的 ODDR 原语用 `oddr_stubs.v` 行为替换。

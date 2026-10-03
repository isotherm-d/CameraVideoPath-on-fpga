# 摄像头快速体检:CSI → 串口统计打印(不用屏幕)

目的:**不接 DSI 屏**,先确认 MIPI 摄像头(SC2336)有没有正常出图。原理是把摄像头数据流上的统计值(每秒帧数、有效数据拍数、非零拍数、平均亮度)通过板上 UART&JTAG 那个 Type-C 口送到电脑串口助手看。

> 说明:那个 Type-C 口本身传不了视频(上面 VIN 5V 只供电,下面 UART&JTAG 只是 USB 转串口/下载器),但**借它打印统计数据**来检测摄像头,是完全够用的最简方案。确认摄像头好用后,再按资料包里的 UDP 以太网方案上真画面。

打印格式(115200-8-N-1,每秒一行):

```
CAM t=1234567890 f=30 p=15552000 nz=15500000 sum=1380000000
```

- `t`   :固定自检值 1234567890。**t 打对了说明打印路径正常,其余数字才可信**
- `f`   :最近 1 秒的帧数(SC2336 1080p30 正常应为 30 左右)
- `p`   :最近 1 秒有效数据拍数(每拍 4 个 RAW10 像素,1080p30 约 1550 万)
- `nz`  :最近 1 秒数据不全为 0 的拍数
- `sum` :亮度总和(取样像素值 >>2 后累加)。**用手挡住镜头该值会骤降——这就是"有画面"的直接证据**

## 文件清单(`04_cam_check/rtl/`)

| 文件 | 作用 | 来源 |
|---|---|---|
| `cam_stats.v` | 摄像头时钟域统计 + 跨时钟快照,像素时钟不跑时自动报全零 | 本目录新增 |
| `cam_report_uart.v` | 每秒把统计值格式化成 ASCII 从串口发出 | 本目录新增 |
| `uiuart_tx.v` | 米联客串口发送驱动 | 复制自 `01_start/02_peripheral_demo/02_uart_loop`(同例程,已验证可用) |

## 接入步骤(改 `08_csi_dsi_cs500_7cun` 摄像头例程)

**1. 把 3 个 .v 文件加入工程**(TD 工程里 Add Source,或复制到 `user_source/hdl_source/` 下)。

**2. 修改顶层 `user_source/hdl_source/design_top_wrapper.v`:**

```verilog
// (a) 端口列表中增加一个输出(比如加在 O_screen_pwm 后面):
    output wire       O_uart_tx,

// (b) 内部 signal 声明区增加:
    wire        S_snap_valid;
    wire [31:0] S_snap_frames, S_snap_pix, S_snap_nonzero;
    wire [39:0] S_snap_sum;

// (c) 在 u_raw10_unpacket 之后例化(信号都是现成的):
    cam_stats #(
        .PIX_W(40), .LUMA_SHIFT(2), .CLK_SYS_HZ(100_000_000)
    ) u_cam_stats (
        .I_clk_pix (S_csi_rx_clk),        .I_rst_pix (~S_rst_n),
        .I_vsync   (S_raw10_frame_start), .I_de      (S_raw10_valid),
        .I_pix     (S_raw10_data),
        .I_clk_sys (S_100m_clk),          .I_rst_sys (~S_rst_n),
        .O_snap_valid (S_snap_valid),     .O_snap_frames (S_snap_frames),
        .O_snap_pix   (S_snap_pix),       .O_snap_nonzero(S_snap_nonzero),
        .O_snap_sum   (S_snap_sum)
    );

    cam_report_uart #(
        .CLK_HZ(100_000_000), .BAUD(115200)
    ) u_cam_report (
        .I_clk         (S_100m_clk),
        .I_rst_n       (S_rst_n),
        .I_snap_valid  (S_snap_valid),
        .I_snap_frames (S_snap_frames),
        .I_snap_pix    (S_snap_pix),
        .I_snap_nonzero(S_snap_nonzero),
        .I_snap_sum    (S_snap_sum),
        .O_uart_tx     (O_uart_tx)
    );
```

**3. 修改约束 `user_source/constraints_source/pin.adc`,增加一行**(J3 就是板上 USB 转串口芯片对应的 FPGA TX 引脚,来自同板卡的 uart_loop 例程):

```
set_pin_assignment	{ O_uart_tx }	{ LOCATION = J3; IOSTANDARD = LVCMOS33; DRIVESTRENGTH = 8; PULLTYPE = NONE; }
```

**4. 编译下载**:TD 里重新 Compile,用 UART&JTAG 那个 Type-C 口下载 .bit。

**5. 看结果**:电脑打开串口助手(或 TD 自带的串口工具),选对应 COM 口,**115200-8-N-1**,对准镜头,观察每秒一行输出。

## 结果判读

| 串口输出 | 结论 | 排查方向 |
|---|---|---|
| `f≈30`, `pix≈1550万`, `avg>0` 且**手挡镜头明显变小** | 摄像头正常,有画面 | 可以进入下一步(网口看真画面) |
| 每秒 `f=0 pix=0` | 像素时钟/数据链路完全无输出 | 查摄像头排线是否插紧、I2C 配置完成信号 `S_cam_cfg_done`(可用 ChipWatcher 探)是否拉高、24M 像素时钟 |
| `f≈30` 但 `nz=0` | 有帧同步、无有效像素 | MIPI lane 极性/顺序;可看 `S_lane_error`,或用下面 ChipWatcher 抓 `S_hs_rx_valid/S_hs_rx_data` |
| `f` 数值乱跳(如 3~17) | 链路不稳定 | 重插排线;调 D-PHY 的 `HS_EQUALIZER`/`HS_VGA_GAIN` 参数 |
| `avg` 恒 0 或恒 255 | 亮度取样位段不对 | 调 `LUMA_SHIFT`(RAW10 建议 2,取值 0~2 试) |

补充:想看更底层的波形,例程顶层 `design_top_wrapper.v` 里就有两段**注释掉的 ChipWatcher(安路 TD 的片内逻辑分析仪)实例**(`cwc`、`cwc1`),探针已经接好 `S_hs_rx_valid / S_hs_rx_data / S_lane_error` 和 ISP 前后数据流,取消注释并按 TD 流程插入即可抓波形。

## 常见问题

- **串口一个字都没有**:先排除串口本身——若连 `f=0` 都不打印,说明 UART 部分没通:检查 J3 约束是否加了、下载的 bit 是不是最新、串口助手 COM 口/波特率是否 115200。
- **为什么统计接在 `S_raw10_*` 这一级**:它在 CSI 解包之后、ISP 之前,最能直接回答"MIPI 链路有没有出图像数据"。要检查 ISP 之后的效果,可以把例化改挂 `S_ISP_O_tuser/tvalid/tdata[127:0]`(此时 `PIX_W=128`、`LUMA_SHIFT` 取 16,即取第一个 RGB 像素的 R 分量)。
- **跨时钟处理**:两个时钟域之间用"请求-应答"握手 + 双拍同步,统计值在请求保持期间保持稳定,无需担心亚稳态;`cam_stats` 在像素时钟完全不动时会走超时路径报全零,所以摄像头不接也能每秒打印 `f=0`。

## 下一步:网口看真画面(确认摄像头好用后)

资料包里已经带了现成材料:`03_demo/3_1_02_米联客2024版UDP以太网通信方案.pdf`、`3_1_02_fpga_udp.rar` 例程、以及 `02_peripheral_demo/05_rgmii_loop` 网口例程。思路是把摄像头例程里 ISP 输出的图像流(或经 DDR 缓存后的帧)交给 UDP 发送模块,通过板上 RGMII 网口发到电脑,电脑用 Python(OpenCV)或网络调试助手接收显示——不用 DSI 屏就能看到实时画面。到那一步时可以把两个工程拼接的工作交给我们继续做。

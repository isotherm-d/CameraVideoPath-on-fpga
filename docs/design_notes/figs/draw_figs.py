# -*- coding: utf-8 -*-
"""技术文档框图绘制:xelatex 文档用 PDF(矢量),另存 PNG 供快速预览。"""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch

plt.rcParams["font.sans-serif"] = ["SimHei", "Microsoft YaHei"]
plt.rcParams["axes.unicode_minus"] = False
plt.rcParams["pdf.fonttype"] = 42

C_STAGE = "#EDF2FA"; C_STAGE_E = "#3B6EA5"
C_MOD_E = "#5B7DA8"; C_NEW = "#FDEBD0"; C_NEW_E = "#D68910"
C_IP = "#F5F5F5"; C_IP_E = "#999999"
C_TXT = "#1A1A1A"


def box(ax, x, y, w, h, text, fc="white", ec=C_MOD_E, fs=9, lw=1.0, bold_first=False, ls="-"):
    ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0.3,rounding_size=1.2",
                                fc=fc, ec=ec, lw=lw, linestyle=ls, mutation_aspect=1))
    ax.text(x + w / 2, y + h / 2, text, ha="center", va="center", fontsize=fs,
            color=C_TXT, linespacing=1.35)


def arrow(ax, x1, y1, x2, y2, label=None, fs=7.5, rad=0.0, ls="-", off=(0, 1.6), color="#333333"):
    ax.add_patch(FancyArrowPatch((x1, y1), (x2, y2), arrowstyle="-|>", mutation_scale=11,
                                 lw=1.1, color=color, linestyle=ls,
                                 connectionstyle=f"arc3,rad={rad}"))
    if label:
        ax.text((x1 + x2) / 2 + off[0], (y1 + y2) / 2 + off[1], label, ha="center",
                va="bottom", fontsize=fs, color="#444444")


def stage(ax, x, y, w, h, title):
    ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0.4,rounding_size=1.6",
                                fc=C_STAGE, ec=C_STAGE_E, lw=1.3))
    ax.text(x + w / 2, y + h - 2.4, title, ha="center", va="center", fontsize=10,
            color=C_STAGE_E, fontweight="bold")


# ---------------------------------------------------------------- 图1 五层流水
def fig_pipeline():
    fig, ax = plt.subplots(figsize=(13.4, 6.0))
    ax.set_xlim(0, 138); ax.set_ylim(0, 60); ax.axis("off")

    box(ax, 1, 22, 12, 15, "SC500CS\n摄像头\nMIPI RAW10\n2-lane\n480 Mbps/lane", fs=8.5)
    box(ax, 1, 49, 15, 9, "cvp_cam_cfg:\nI2C 配置\n(原厂 720p60 表)", fs=8)
    arrow(ax, 8.5, 49, 8.5, 37.4)

    xs = [17, 41, 65, 89, 112]; ws = [20, 20, 18, 19, 17]
    titles = ["接入层 (byte 60M)", "ISP 层 (100M)", "算法层 (100M)",
              "帧缓存层 (100M/52M)", "显示层 (75M/375M)"]
    for x, w, t in zip(xs, ws, titles):
        stage(ax, x, 9, w, 37, t)

    def mods(x0, w, items, gap=1.2, h=6.4):
        total = len(items) * h + (len(items) - 1) * gap
        y = 9 + (37 + total) / 2.0
        centers = []
        for t in items:
            box(ax, x0 + 1.5, y - h, w - 3, h, t, fs=8)
            centers.append(y - h / 2)
            y -= h + gap
        for a, b in zip(centers[:-1], centers[1:]):
            arrow(ax, x0 + w / 2, a - h / 2 - 0.1, x0 + w / 2, b + h / 2 + 0.1, off=(0, -0.4))

    mods(xs[0], ws[0], ["cvp_mipi_rx\nD-PHY 封装·字节对齐", "cvp_rx_pipeline\nCSI-2 解包+RAW10 重排"])
    mods(xs[1], ws[1], ["cvp_proc\n4:1 位宽变换", "cvp_dpc\n坏点检测与修复", "cvp_demosaic\n3×3 双线性去马赛克", "cvp_awb\n三模式白平衡 v1.3"])
    mods(xs[2], ws[2], ["imgproc_win3x3\n3×3 窗口(行缓存)", "imgproc_top\n七模式·固定 3 拍"])
    mods(xs[3], ws[3], ["cvp_async_fifo\n异步 FIFO(Gray 指针)", "cvp_frame_buffer\nDDR2 乒乓帧缓存", "cvp_ddr_ctrl + DDR2 颗粒\nDDR2-1066 16bit(厂商 IP)"])
    mods(xs[4], ws[4], ["cvp_osd\n字符/logo/检测框", "cvp_display\n720p60 VTC\n+TMDS 编码", "cvp_hdmi_phy\nODDR 5:1 串化"])

    ymid = 28
    arrow(ax, 13, ymid, xs[0] - 0.2, ymid)
    for i in range(4):
        arrow(ax, xs[i] + ws[i] + 0.2, ymid, xs[i + 1] - 0.2, ymid)
    arrow(ax, xs[4] + ws[4] + 0.2, ymid, 132.5, ymid)
    ax.text(134, 30.6, "HDMI\n720p60\n4 对差分", ha="center", fontsize=8, color="#333333", linespacing=1.4)

    box(ax, 40, 49, 46, 9, "拨码 SW1~4 直选模式 1~4\n边缘档下 KEY2/3/4 切风格化/素描/回默认", fs=8)
    arrow(ax, 74, 49, 74, 46.3, "i_sel", fs=7.5, off=(2.2, 0.2))

    ax.text(0.5, 5.2, "数据宽度演变:16 bit/拍(D-PHY 字节) → 40 bit/拍(4 像素 RAW10) → 1 像素/拍 RGB888(100M 域) "
                      "→ 128 bit/字(4 像素打包) → 750 Mbps × 4 对(串行)",
            fontsize=8, color="#555555")
    ax.text(0.5, 1.8, "时钟域:byte_clk 60M(解包)· clk_100m 100M(ISP/算法/写侧/DDR 用户口 133M)· "
                      "clk_pixel 75M(VTC)· clk_serial 375M(串化)· clk_cam24m 24.19M(相机参考/I2C)",
            fontsize=8, color="#555555")
    fig.savefig("fig_pipeline.pdf", bbox_inches="tight")
    fig.savefig("fig_pipeline.png", dpi=160, bbox_inches="tight")
    plt.close(fig)


# ---------------------------------------------------------------- 图2 AWB 状态机
def fig_awb():
    fig, ax = plt.subplots(figsize=(11.2, 6.2))
    ax.set_xlim(0, 112); ax.set_ylim(0, 62); ax.axis("off")

    st = dict(fc="#EDF2FA", ec=C_STAGE_E, fs=9, lw=1.4)
    box(ax, 3, 26, 26, 18, "FREEZE\n增益保持\n—————\nΣMAD 低(色度均匀)\n光源估计欠定,不校正", **st)
    box(ax, 43, 26, 28, 18, "WP 白点法(主模式)\n—————\nY 直方图 87.5% 分位白点\n增益 = 中性灰 / 白点均值", **st)
    box(ax, 85, 26, 25, 18, "GW 灰世界(回退)\n—————\n高光剔除灰世界统计\n白点不足时兜底", **st)

    arrow(ax, 29, 40.5, 43, 40.5, "ΣMAD > 37.5M\n且 N_wp ≥ 10000", fs=8, off=(0, 1.2))
    arrow(ax, 71, 40.5, 85, 40.5, "白点消失\nN_wp < 4000\n(过曝/场景切换)", fs=8, off=(0, 1.2))
    arrow(ax, 85, 29.5, 71, 29.5, "白点恢复\nN_wp ≥ 10000", fs=8, off=(0, -4.6))

    # GW -> FREEZE(色度均匀场景回增益保持):直角肘线绕行 WP 下方
    ax.plot([97.5, 97.5, 16, 16], [26, 22.5, 22.5, 25.6], color="#333333", lw=1.1)
    ax.annotate("", xy=(16, 26), xytext=(16, 24.6),
                arrowprops=dict(arrowstyle="-|>", mutation_scale=11, lw=1.1, color="#333333"))
    ax.text(57, 23.4, "ΣMAD < 25M(色度均匀,回增益保持)", ha="center", fontsize=8, color="#444444")

    ax.text(57, 49.5, "判决优先级:增益保持 FREEZE > 白点 WP > 灰世界 GW(每帧帧尾判决,双阈值迟滞防振荡)",
            ha="center", fontsize=9, color=C_STAGE_E, fontweight="bold")
    ax.text(57, 19.2, "冷色仲裁(WP 态内):白点增益 ≈ 1(±7%)且帧均值 max/min ≥ 1.25 → 判白点失效,"
                      "改用 GW 增益拉中性(进入 1.25 / 退出 1.15 迟滞)", ha="center", fontsize=8.5,
            color="#8A5A00")

    box(ax, 3, 3, 107, 13,
        "增益时域平滑(v1.3,每通道):|Δ| < 2% 死区保持 · 2%~12.5% 每帧 Δ/4 一阶惯性 · ≥ 12.5% 大跳直通\n"
        "帧尾流水(720p 消隐期约 74 万拍):eof +1 锁存统计 → +2 三模判决 → +3 启动增益除法 → ≈ +55 拍生效,"
        "N+2 帧节奏与 sensor 增益同步链无缝衔接\n统计全部取自增益前级,结构开环,无自激振荡",
        fc="#FAFAF5", ec="#BBBBBB", fs=8.5)
    fig.savefig("fig_awb_fsm.pdf", bbox_inches="tight")
    fig.savefig("fig_awb_fsm.png", dpi=160, bbox_inches="tight")
    plt.close(fig)


# ---------------------------------------------------------------- 图3 应用架构
def fig_app():
    fig, ax = plt.subplots(figsize=(13.6, 6.2))
    ax.set_xlim(0, 150); ax.set_ylim(0, 62); ax.axis("off")

    box(ax, 1, 24, 16, 18, "显微镜接口\n—————\nGiemsa 染色\n血涂片\nSC500CS\n720p30 RAW10", fs=8.5)

    ax.add_patch(FancyBboxPatch((21, 8), 76, 48, boxstyle="round,pad=0.4,rounding_size=1.6",
                                fc="#F7FAFF", ec=C_STAGE_E, lw=1.4))
    ax.text(59, 52.6, "FPGA 前端(安路 PH1P 定版:UDP 推流 + 网络命令控制)", ha="center",
            fontsize=10, color=C_STAGE_E, fontweight="bold")

    # 行 1:现有主通路
    box(ax, 23, 40, 22, 10, "采集与解包\ncsi_unpacket/uial2axis\nline_retimer/group_fifo", fs=8)
    box(ax, 48, 40, 22, 10, "cvp_proc\n位宽变换/DPC/去马赛克", fs=8)
    box(ax, 73, 40, 22, 10, "color_correct\n白平衡+1.506×补光\n(运行时可覆盖)", fs=8)
    arrow(ax, 45, 45, 47.8, 45); arrow(ax, 70, 45, 72.8, 45)

    # 行 2:应用新增
    box(ax, 23, 24, 22, 10, "细胞提案\n核深染二值化+\n1/4 降采样连通域", fc=C_NEW, ec=C_NEW_E, fs=8)
    box(ax, 48, 24, 22, 10, "裁剪读出\n96×96 细胞截图\n(按框开窗缓存)", fc=C_NEW, ec=C_NEW_E, fs=8)
    box(ax, 73, 24, 22, 10, "检测帧格式\n随 UDP 6000 上行", fc=C_NEW, ec=C_NEW_E, fs=8)
    arrow(ax, 45, 29, 47.8, 29); arrow(ax, 70, 29, 72.8, 29)

    # 行 3:命令支路(现有)
    box(ax, 40, 11, 38, 8, "命令支路 cvp_cmd_rx:UDP 6001 曝光/白平衡运行时控制(现有)", fs=8)

    # 行间纵向馈给
    arrow(ax, 34, 40, 34, 34.4, "像素流", fs=7, off=(-3.6, -0.2))
    arrow(ax, 77, 40, 70, 34.4, "帧数据", fs=7, rad=0.12, off=(2.5, -0.2))
    arrow(ax, 16.2, 29, 20.8, 29)
    arrow(ax, 59, 24, 59, 19.4, "检测帧", fs=7, off=(2.2, -0.2))

    # PC 上位机
    ax.add_patch(FancyBboxPatch((101, 8), 46, 48, boxstyle="round,pad=0.4,rounding_size=1.6",
                                fc="#FFFDF7", ec="#B7950B", lw=1.4))
    ax.text(124, 52.6, "PC 上位机", ha="center", fontsize=10.5, color="#8A6D0B", fontweight="bold")
    box(ax, 104, 40, 20, 8, "收图 GUI(cam_gui)\n已交付", fs=8)
    box(ax, 127, 40, 18, 8, "图库陈列\n五分类图库", fs=8)
    box(ax, 104, 29, 20, 8, "累计计数\n五分类 ≥95%(目标)", fs=8)
    box(ax, 127, 29, 18, 8, "结果展示\nOSD/网口多路", fs=8)
    arrow(ax, 124, 40, 124, 37.4)

    # FPGA -> PC 与命令
    arrow(ax, 95, 29, 100.6, 33, rad=-0.1, off=(-2.5, 3.4))
    ax.text(96.5, 22.6, "细胞截图流", fontsize=7.5, color="#444444", ha="center")
    arrow(ax, 100.6, 17, 78, 14.6, rad=0.12, ls="--", off=(6, -2.2),
          label="(网络)曝光/白平衡命令", color="#8A6D0B")
    ax.text(19.5, 4.4, "曝光命令经 cvp_proc 运行时锁存 → uicfgcs500 → I2C 重写传感器;"
                       "增益经 color_correct 运行时覆盖(第 4 章)。检出在 FPGA 流水线内零帧延迟,"
                       "检出不依赖 PC。", fontsize=7.5, color="#555555")

    box(ax, 21, 0.4, 10, 3.6, "现有资产", fc="#EDF2FA", ec=C_STAGE_E, fs=8)
    ax.text(32.5, 2.2, "已定版基础设施", fontsize=8.5, va="center", color="#555555")
    box(ax, 48, 0.4, 10, 3.6, "新增模块", fc=C_NEW, ec=C_NEW_E, fs=8)
    ax.text(59.5, 2.2, "应用新增(设计,尚未实施)", fontsize=8.5, va="center", color="#555555")

    fig.savefig("fig_app_arch.pdf", bbox_inches="tight")
    fig.savefig("fig_app_arch.png", dpi=160, bbox_inches="tight")
    plt.close(fig)


# ---------------------------------------------------------------- 图A v23 系统五层总览
def fig_pipeline_v23():
    fig, ax = plt.subplots(figsize=(13.4, 6.4))
    ax.set_xlim(0, 140); ax.set_ylim(0, 66); ax.axis("off")

    def layer(x, y, w, h, title):
        ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0.4,rounding_size=1.6",
                                    fc=C_STAGE, ec=C_STAGE_E, lw=1.3))
        ax.text(x + w / 2, y + h - 2.2, title, ha="center", va="center",
                fontsize=9.5, color=C_STAGE_E, fontweight="bold")

    # ---- 第 2 章 采集与解包层 ----
    layer(1, 34, 30, 26, "采集与解包层")
    box(ax, 2.5, 45, 27, 10.5, "SC500CS 传感器\nVTS=1003(30fps) · 采窗 1287×727\n实发 1280×720 · MIPI 2lane RAW10", fs=8)
    box(ax, 2.5, 36, 27, 7.5, "csi_unpacket → uial2axis\n→ line_retimer → group_fifo", fs=7.5)

    # ---- 第 3 章 ISP 层 ----
    layer(34, 34, 40, 26, "ISP 层(100M 域)")
    box(ax, 35.5, 44, 18, 11, "cvp_proc\n4:1 位宽变换(gearbox)\nDPC 坏点修复(4 拍)\n去马赛克(BGGR,3 拍)", fs=8)
    box(ax, 55.5, 44, 17, 11, "color_correct\n白平衡增益(Q8)\n+1.506× 数字补光", fs=8)
    ax.text(35.5, 37.6, "曝光/白平衡支持网络运行时覆盖", fontsize=7.5, color="#8A5A00")

    # ---- 第 5 章 推流层 ----
    layer(77, 34, 30, 26, "推流层(GMII 125M)")
    box(ax, 78.5, 45, 27, 10.5, "pack_4(96bit 组)\ncvp_eth_dbg 字节展开\n1920 包/帧 · UDP 6000", fs=8)
    box(ax, 78.5, 36, 27, 7.5, "RGMII → YT8531 千兆 PHY\n→ 网线 → PC(cam_gui)", fs=7.5)

    # ---- 显示支路 ----
    layer(110, 34, 28, 26, "显示支路")
    box(ax, 111.5, 40, 25, 14, "rgb_frame_crop\n居中裁 1024×600\n→ DSI 7 寸屏\n(板端自动,免配置)", fs=8)
    arrow(ax, 107, 47, 109.8, 47, "并行视图", fs=7, off=(0, 1.4))

    # ---- 主链箭头 ----
    arrow(ax, 29.5, 47, 34, 47)
    arrow(ax, 74, 47, 77, 47)

    # ---- 第 4 章 命令支路(底部) ----
    layer(1, 6, 106, 24, "命令支路:网络命令 → 运行时控制")
    box(ax, 3, 9, 24, 12, "PC/GUI·cam_ctrl\nUDP 6001 广播\n魔数 C5A55001+命令码", fs=8)
    box(ax, 31, 9, 22, 12, "cvp_cmd_rx\nRGMII RX 过滤状态机\n→100M 命令寄存器组", fs=8)
    box(ax, 57, 9, 24, 12, "曝光:运行时锁存\n钳位 62..1800(半行)\n→ o_ae_req 重发", fc=C_NEW, ec=C_NEW_E, fs=8)
    box(ax, 85, 9, 20, 12, "白平衡:增益覆盖\nQ8 64..511\n+R/B 互换 · 色温 K", fc=C_NEW, ec=C_NEW_E, fs=8)
    arrow(ax, 27, 15, 30.8, 15)
    arrow(ax, 53, 15, 56.8, 15)
    arrow(ax, 81, 15, 84.8, 15, "增益", fs=7, off=(0, -3.2))
    # 曝光参数 → uicfgcs500 → I2C → 传感器
    ax.plot([69, 69], [9, 4.5], color="#333333", lw=1.1)
    ax.plot([69, 133], [4.5, 4.5], color="#333333", lw=1.1)
    ax.annotate("", xy=(133, 33.6), xytext=(133, 4.5),
                arrowprops=dict(arrowstyle="-|>", mutation_scale=11, lw=1.1, color="#333333"))
    ax.text(70, 3.0, "uicfgcs500:I2C 重写传感器 0x3e00/01/02(曝光)+增益表(SC500GainTbl,1.0×..15.75×)——上电写一次,"
                     "命令拍重发;曝光 1~2 帧生效,上限 1800(读出窗偏移防错位带)", fontsize=7.5, color="#555555")

    # ---- 统计支路 ----
    box(ax, 110, 6, 28, 8, "统计支路:cam_stats ×2\ncam_report_uart(CAM/ISP 行)", fs=7.5)
    fig.savefig("fig_pipeline_v23.pdf", bbox_inches="tight")
    fig.savefig("fig_pipeline_v23.png", dpi=160, bbox_inches="tight")
    plt.close(fig)


def fig_isp_v23():
    fig, ax = plt.subplots(figsize=(13.0, 5.2))
    ax.set_xlim(0, 140); ax.set_ylim(0, 56); ax.axis("off")

    # ---- 主通路(实线) ----
    box(ax, 1, 34, 16, 12, "group_fifo 输出\n40bit(4 像素)/拍\n(跨时钟域后)", fs=8)
    box(ax, 21, 34, 20, 12, "4:1 位宽变换(gearbox)\ncvp_proc:锁存+弹出计数\n40bit/拍→1 像素/拍", fs=8)
    box(ax, 45, 34, 20, 12, "坏点检测与修复(DPC)\ncvp_dpc:同色对角判据\n两级流水 · 固定 4 拍", fs=8)
    box(ax, 69, 34, 20, 12, "去马赛克 cvp_demosaic\nBGGR 双线性插值\n固定 3 拍", fs=8)
    box(ax, 93, 34, 22, 12, "color_correct\n白平衡增益(Q8)+补光\n支持运行时覆盖", fs=8)
    box(ax, 119, 34, 19, 12, "pack_4\n攒 96bit 组\n→ 推流层(UDP)", fs=8)
    arrow(ax, 17, 40, 20.8, 40); arrow(ax, 41, 40, 44.8, 40)
    arrow(ax, 65, 40, 68.8, 40); arrow(ax, 89, 40, 92.8, 40); arrow(ax, 115, 40, 118.8, 40)

    # ---- AE/白平衡参数与命令通路(已实现,实线橙) ----
    box(ax, 24, 10, 26, 12, "cvp_cmd_rx(UDP 6001)\n曝光码命令(16bit)\ncvp_proc 消费+钳位", fc=C_NEW, ec=C_NEW_E, fs=8)
    box(ax, 58, 10, 26, 12, "cvp_proc AE 参数通路\ncam_cfg_done 后写一次\n命令拍锁存+重发 o_ae_req", fc=C_NEW, ec=C_NEW_E, fs=8)
    box(ax, 92, 10, 26, 12, "uicfgcs500 → I2C\n重写 0x3e00/01/02(曝光)\n+SC500GainTbl(增益档)", fc=C_NEW, ec=C_NEW_E, fs=8)
    arrow(ax, 50, 16, 57.8, 16, "o_exp_wr", fs=7, off=(0, -3.2))
    arrow(ax, 84, 16, 91.8, 16, "o_ae/o_ae_req", fs=7, off=(0, -3.2))
    # I2C -> 传感器(左上 SC500CS 由第 2 章框表示,这里指向图外说明)
    ax.plot([105, 105], [10, 5.5], color="#333333", lw=1.1)
    ax.plot([105, 3], [5.5, 5.5], color="#333333", lw=1.1)
    ax.annotate("", xy=(3, 33.6), xytext=(3, 5.5),
                arrowprops=dict(arrowstyle="-|>", mutation_scale=11, lw=1.1, color="#333333"))
    ax.text(4.5, 20, "I2C 写传感器寄存器:\n曝光码 0x3e00/01/02\n增益表 SC500GainTbl\n(1~2 帧生效)", fontsize=7,
            color="#444444", ha="left")

    # ---- 与主通路的统计/覆盖关系 ----
    arrow(ax, 37, 22, 37, 33.6, "曝光命令 o_exp_wr(运行时)", fs=7, off=(-7.5, 2.5))
    ax.text(70.5, 27.5, "白平衡增益运行时覆盖\n(命令 2/3/4 非零即覆盖标定值)", fontsize=7, color="#8A5A00", ha="center")

    ax.text(0.5, 1.5, "全部模块为已实现 RTL · 白平衡采用标定增益+运行时覆盖,自动曝光走网络命令参数通路", fontsize=8, color="#555555")
    fig.savefig("fig_isp_v23.pdf", bbox_inches="tight")
    fig.savefig("fig_isp_v23.png", dpi=160, bbox_inches="tight")
    plt.close(fig)


if __name__ == "__main__":
    fig_pipeline(); fig_awb(); fig_app(); fig_pipeline_v23(); fig_isp_v23()
    print("done")

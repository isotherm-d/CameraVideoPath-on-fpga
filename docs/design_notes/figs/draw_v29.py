# -*- coding: utf-8 -*-
"""双板系统(主板相机 + 子板 HDMI 回显)技术文档框图。"""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch

plt.rcParams["font.sans-serif"] = ["SimHei", "Microsoft YaHei"]
plt.rcParams["axes.unicode_minus"] = False
plt.rcParams["pdf.fonttype"] = 42

C_STAGE = "#EDF2FA"; C_STAGE_E = "#3B6EA5"
C_MOD_E = "#5B7DA8"; C_NEW = "#FDEBD0"; C_NEW_E = "#D68910"
C_TXT = "#1A1A11"


def box(ax, x, y, w, h, text, fc="white", ec=C_MOD_E, fs=8.5, lw=1.0, ls="-"):
    ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0.3,rounding_size=1.1",
                                fc=fc, ec=ec, lw=lw, linestyle=ls, mutation_aspect=1))
    ax.text(x + w / 2, y + h / 2, text, ha="center", va="center", fontsize=fs,
            color=C_TXT, linespacing=1.35)


def arrow(ax, x1, y1, x2, y2, label=None, fs=7.5, rad=0.0, ls="-", off=(0, 1.5), color="#333333"):
    ax.add_patch(FancyArrowPatch((x1, y1), (x2, y2), arrowstyle="-|>", mutation_scale=11,
                                 lw=1.15, color=color, linestyle=ls,
                                 connectionstyle=f"arc3,rad={rad}"))
    if label:
        ax.text((x1 + x2) / 2 + off[0], (y1 + y2) / 2 + off[1], label, ha="center",
                va="bottom", fontsize=fs, color="#444444")


def board(ax, x, y, w, h, title, sub):
    ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0.5,rounding_size=2.0",
                                fc=C_STAGE, ec=C_STAGE_E, lw=1.5))
    ax.text(x + w / 2, y + h - 3.2, title, ha="center", va="center", fontsize=11,
            color=C_STAGE_E, fontweight="bold")
    ax.text(x + w / 2, y + h - 7.4, sub, ha="center", va="center", fontsize=7.5,
            color=C_STAGE_E)


# ============================================================ 图1 双板系统总览
def fig_system():
    fig, ax = plt.subplots(figsize=(13.6, 6.8))
    ax.set_xlim(0, 152); ax.set_ylim(0, 70); ax.axis("off")

    def board(x, y, w, h, title, sub):
        ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0.5,rounding_size=2.0",
                                    fc=C_STAGE, ec=C_STAGE_E, lw=1.5))
        ax.text(x + w / 2, y + h - 3.6, title, ha="center", va="center", fontsize=11,
                color=C_STAGE_E, fontweight="bold")
        ax.text(x + w / 2, y + h - 8.0, sub, ha="center", va="center", fontsize=7.5,
                color=C_STAGE_E)

    # ---- 主板容器 ----
    board(2, 15, 63, 49, "相机主板(MLKPAI-F02,安路 PH1P35)", "摄像头 → 自研 ISP → 千兆 UDP 推流")
    box(ax, 4, 44, 13, 10, "SC500CS\nMIPI 2lane\nRAW10", fs=8)
    box(ax, 20, 44, 21, 10, "自研 ISP\ncvp_proc(DPC/去马赛克)\ncolor_correct(WB)", fs=7.5)
    box(ax, 44, 44, 19, 10, "千兆 UDP 发送\nUDP6000 视频 1920包/帧\nUDP6001 命令·6002 状态", fs=7.5)
    arrow(ax, 17, 49, 19.8, 49); arrow(ax, 41, 49, 43.8, 49)
    box(ax, 4, 30, 26, 11, "以太网口 ETHA(YT8531)\n→ PC 上位机\ncam_gui 收图 + 控制", fs=8)
    box(ax, 33, 30, 30, 11, "以太网口 ETHB(YT8531)\n镜像输出口\n(与 ETHA 相同的 RGMII TX)", fs=8)
    arrow(ax, 11, 44, 11, 41.4)
    arrow(ax, 53, 44, 53, 41.4)
    box(ax, 32, 17, 31, 9, "命令通路 cvp_cmd_rx\n曝光/白平衡/模式 → I2C 桥", fs=7.5)

    # ---- 子板容器 ----
    board(85, 15, 63, 49, "显示子板(MLKPAI-F01,EG4D20)", "网口收流 → 帧重组 → DDR 三缓冲 → HDMI")
    box(ax, 87, 44, 15, 10, "RGMII RX\nPLL2 采样+IDDR\nrgmii_cdc 跨域", fs=7.5)
    box(ax, 105, 44, 17, 10, "协议栈\nMAC/IP/UDP\n(广播 IP 放行)", fs=8)
    box(ax, 125, 44, 21, 10, "帧重组器 cvp_rx_assemble\n丢包补黑\n顺序光栅流", fs=7.5)
    arrow(ax, 102, 49, 104.8, 49); arrow(ax, 122, 49, 124.8, 49)
    box(ax, 87, 30, 27, 11, "DDR1 三缓冲(合封 16MB)\nuidbuf + FDMA,帧步进 4MB\n写 30fps / 读 60fps 解耦", fs=7.5)
    box(ax, 118, 30, 28, 11, "显示输出\nuivtc 720p60 → OSD(安路logo)\nTMDS → HDMI", fs=7.5)
    arrow(ax, 134, 44, 134, 41.4)
    arrow(ax, 114, 35.5, 117.8, 35.5)
    box(ax, 87, 17, 59, 9, "纯接收显示:无命令通路、零参数调节\nping 不通属正常(纯二层接收)", fs=7.5)

    # ---- 板间链路(两容器间隙 65..85,标注完全置于间隙内) ----
    arrow(ax, 65, 35.5, 84.8, 35.5, rad=0.0)
    ax.text(75, 39.0, "千兆网线直连", ha="center", fontsize=8, color="#444444")
    ax.text(75, 31.2, "YT8531 自协商 1000M", ha="center", va="top", fontsize=8, color="#444444")

    # ---- 输入/输出端 ----
    box(ax, 2, 3, 14, 8, "Giemsa 染色\n血涂片/场景", fs=7.5)
    arrow(ax, 8, 11, 8, 14.8)
    box(ax, 18, 3, 30, 8, "PC 上位机(Python GUI)\n收图 6000 · 控制 6001 · 状态 6002", fs=8)
    arrow(ax, 26, 30, 26, 11.4)                    # ETHA → PC(左走廊垂直)
    ax.text(24.5, 22, "视频流+状态", fontsize=7.5, color="#444444", ha="right")
    arrow(ax, 47, 11, 47, 16.8, "命令(UDP6001)", fs=7.5, off=(6.5, 1.0), ls="--")   # PC → 命令支路框
    box(ax, 137, 3, 11, 9, "HDMI\n显示器\n720p60", fs=8)
    arrow(ax, 142, 15, 142, 12.2)

    fig.savefig("fig_system.pdf", bbox_inches="tight")
    fig.savefig("fig_system.png", dpi=160, bbox_inches="tight")
    plt.close(fig)


def fig_mainboard():
    fig, ax = plt.subplots(figsize=(13.4, 6.6))
    ax.set_xlim(0, 152); ax.set_ylim(0, 68); ax.axis("off")

    def layer(x, y, w, h, title):
        ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0.4,rounding_size=1.6",
                                    fc=C_STAGE, ec=C_STAGE_E, lw=1.3))
        ax.text(x + w / 2, y + h - 2.2, title, ha="center", va="center",
                fontsize=9.5, color=C_STAGE_E, fontweight="bold")

    # ---- 采集与解包层 ----
    layer(1, 36, 40, 26, "采集与解包层")
    box(ax, 2.5, 40.5, 37, 17, "SC500CS 传感器\n采窗 1287×727 · 实发 1280×720 · VTS=1003(30fps)\n"
                              "→ csi_unpacket → uial2axis → line_retimer\n→ group_fifo(40.2M→100M 跨域,组格式 40bit/拍)", fs=7.5)

    # ---- ISP 层(含 3A 闭环) ----
    layer(44, 22, 66, 40, "ISP 层(100M 域,含 3A 闭环)")
    box(ax, 45.5, 46, 13, 9, "4:1 位宽变换\n(gearbox)", fs=7.5)
    box(ax, 60.5, 46, 13, 9, "DPC 坏点修复\n两级流水·4 拍", fs=7.5)
    box(ax, 75.5, 46, 13, 9, "去马赛克\nBGGR 双线性", fs=7.5)
    box(ax, 90.5, 46, 17, 9, "color_correct\n白平衡增益(Q8)", fs=8)
    arrow(ax, 58.5, 50.5, 60.3, 50.5); arrow(ax, 73.5, 50.5, 75.3, 50.5); arrow(ax, 88.5, 50.5, 90.3, 50.5)
    # 3A 闭环行
    box(ax, 45.5, 25, 30, 12, "自动曝光 AE(第 3 章)\n固定点 PID · Q10 6/3/1\n两/四帧自适应统计\n先曝光后数字增益", fc=C_NEW, ec=C_NEW_E, fs=7.5)
    box(ax, 79.5, 25, 28, 12, "自动白平衡 AWB(第 3 章)\n中性候选统计\n绝对增益·平滑限幅\n冻结守卫", fc=C_NEW, ec=C_NEW_E, fs=7.5)
    arrow(ax, 60, 46, 60, 37.4)
    ax.text(61.5, 40.5, "亮度统计", fontsize=7, color="#444444", ha="left")
    arrow(ax, 93, 46, 93, 37.4)
    ax.text(94.5, 40.5, "中性候选统计", fontsize=7, color="#444444", ha="left")
    arrow(ax, 86, 37.2, 86, 45.8)
    ax.text(87.5, 40.5, "增益回注", fontsize=7, color="#444444", ha="left")

    # ---- 推流层 ----
    layer(113, 36, 37, 26, "推流层(GMII 125M 域)")
    box(ax, 114.5, 44, 15, 11, "七模式风格化\n(公共像素流)", fs=7.5)
    box(ax, 131.5, 44, 17, 11, "pack_4 → cvp_eth_dbg\n1920 包/帧·1440B\n(UDP6000)", fs=7.5)
    arrow(ax, 107.5, 50.5, 114.3, 50.5); arrow(ax, 129.5, 50.5, 131.3, 50.5)
    box(ax, 114.5, 37.5, 34, 5, "RGMII → YT8531 → ETHA(PC)/ETHB(镜像,子板)", fs=7)

    # ---- 命令与执行通路 ----
    layer(1, 4, 100, 18, "命令与执行通路")
    box(ax, 3, 8, 24, 12, "cvp_cmd_rx(UDP 6001)\n曝光/白平衡/模式命令\n→ 100M 命令寄存器", fs=8)
    box(ax, 31, 8, 24, 12, "I2C 请求/确认桥\nuicfgcs500 写传感器\nNACK/超时上报", fs=8)
    box(ax, 59, 8, 38, 12, "状态上报:UDP 6002 状态包(v29 起串口诊断链移除)\n主板本地 DDR/DSI 显示支路于 v30 裁剪", fs=7.5)
    arrow(ax, 27, 14, 30.8, 14)
    arrow(ax, 43, 20.2, 48, 24.8, rad=0.0)
    ax.text(44.5, 23.2, "曝光 / 数字增益执行", fontsize=7, color="#444444", ha="left")
    arrow(ax, 15, 20, 15, 35.8)
    ax.text(16.5, 26.5, "AE 参数→传感器", fontsize=7, color="#444444", ha="left")
    arrow(ax, 70, 20.2, 88, 24.8, rad=0.0)
    ax.text(71.5, 23.2, "命令覆盖(手动/预设)", fontsize=7, color="#444444", ha="left")

    fig.savefig("fig_mainboard.pdf", bbox_inches="tight")
    fig.savefig("fig_mainboard.png", dpi=160, bbox_inches="tight")
    plt.close(fig)


def fig_subboard():
    fig, ax = plt.subplots(figsize=(13.4, 5.6))
    ax.set_xlim(0, 152); ax.set_ylim(0, 58); ax.axis("off")

    # 三个时钟域泳道
    lanes = [("clk_125(协议栈+重组器)", 30, 74), ("fdma_clk 150M(DDR+三缓冲)", 108, 24), ("pclkx1 75M(显示)", 138, 12)]
    for name, x, w in lanes:
        ax.add_patch(FancyBboxPatch((x - 2, 6), w, 44, boxstyle="round,pad=0.4,rounding_size=1.6",
                                    fc="#F7FAFF", ec="#9BB8D8", lw=1.0))
        ax.text(x + w / 2 - 2, 47.2, name, ha="center", fontsize=8, color=C_STAGE_E, fontweight="bold")

    box(ax, 1, 30, 14, 12, "YT8531\nRGMII RX\n(千兆)", fs=8)
    box(ax, 18, 30, 16, 12, "PLL2 采样相位\n+ IDDR×5\n+ rgmii_cdc", fs=7.5)
    box(ax, 38, 30, 18, 12, "uiudp_stack\nMAC(CRC/广播放行)\nIP(目的过滤)·UDP", fs=7.5)
    box(ax, 60, 26, 26, 16, "cvp_rx_assemble 帧重组器\n6B 应用头解析(fmt/offset)\n缺口≤4 包白名单·跟踪-丢弃\n描述符队列·丢包补黑→顺序光栅流", fc=C_NEW, ec=C_NEW_E, fs=7.5)
    arrow(ax, 15, 36, 17.8, 36); arrow(ax, 34, 36, 37.8, 36); arrow(ax, 56, 36, 59.8, 36)

    box(ax, 92, 26, 26, 16, "uidbuf 三缓冲 + FDMA\n写侧:满帧驱动 FDMA 写 DDR1\n读侧:行预取;场头锁存轮换\n(读落后写 1 帧,30fps/60Hz 解耦)", fs=7.5)
    box(ax, 92, 10, 26, 10, "DDR1(合封 16MB)\n帧步进 4MB×3 缓冲", fs=8)
    arrow(ax, 86, 34, 91.8, 34, "W_FS/W_rgb", fs=7, off=(1.5, 4.0))
    arrow(ax, 105, 26, 105, 20.2)

    box(ax, 124, 26, 26, 16, "uivtc 720p60\n(1651×757@75M)\nRGB 对齐寄存\nOSD 安路 logo 叠加", fs=7.5)
    box(ax, 124, 10, 26, 10, "uihdmitx\nTMDS 编码+LVDS 串化\n(PCLKX5=375M)", fs=7.5)
    arrow(ax, 118, 34, 123.8, 34, "R_data", fs=7, off=(0.5, 4.0))
    arrow(ax, 137, 26, 137, 20.2)
    box(ax, 124, 1, 26, 6, "HDMI 显示器", fs=8.5)
    arrow(ax, 137, 10, 137, 7.2)

    ax.text(1, 2.4, "带宽:写 110.6 + 读 221.2 = 331.8 MB/s(DDR1 峰值 600MB/s 的 55%)· 每帧 1920 包×1440B,线速约 697Mbps(千兆必须)",
            fontsize=7.5, color="#555555")
    ax.text(1, 0.6, "重组器不变量:任意两个帧同步脉冲之间恰好输出 921600 像素(实像素+补黑),保证写侧 FDMA 每帧固定突发数、永不卡死",
            fontsize=7.5, color="#555555")
    fig.savefig("fig_subboard.pdf", bbox_inches="tight")
    fig.savefig("fig_subboard.png", dpi=160, bbox_inches="tight")
    plt.close(fig)




# ============================================================ 图 ISP 与 3A 闭环
def fig_isp_3a():
    fig, ax = plt.subplots(figsize=(13.2, 6.0))
    ax.set_xlim(0, 152); ax.set_ylim(0, 62); ax.axis("off")

    # 像素处理链(上行)
    box(ax, 1, 40, 12, 10, "SC500CS\nRAW10\n(传感器)", fs=8)
    box(ax, 16, 40, 15, 10, "4:1 位宽变换\ngearbox", fs=8)
    box(ax, 34, 40, 15, 10, "DPC 坏点修复\nRAW 域·4 拍", fs=8)
    box(ax, 52, 40, 16, 10, "去马赛克\nBGGR 双线性", fs=8)
    box(ax, 71, 40, 20, 10, "color_correct\n白平衡增益(Q8)\n四模式+R/B 互换", fs=8)
    box(ax, 94, 40, 24, 10, "七模式风格化 → 推流\n(公共像素流 CVP_PIXEL_V1)", fs=8)
    arrow(ax, 13, 45, 15.8, 45); arrow(ax, 31, 45, 33.8, 45)
    arrow(ax, 49, 45, 51.8, 45); arrow(ax, 68, 45, 70.8, 45); arrow(ax, 91, 45, 93.8, 45)

    # AE 闭环(左下)
    box(ax, 20, 18, 30, 12, "AE 闭环\n亮度统计(WB 后)·目标 112·死区 ±8\n每四帧评估·帧间稳定等待\n先曝光后增益/先增益后曝光", fc=C_NEW, ec=C_NEW_E, fs=7.5)
    # AWB 闭环(右下)
    box(ax, 72, 18, 30, 12, "AWB 闭环\n中性候选统计→绝对增益\n平滑·限幅·冻结守卫\n暗场/过曝/样本不足冻结", fc=C_NEW, ec=C_NEW_E, fs=7.5)

    # 统计抽头(下行)与回注(上行)
    arrow(ax, 62, 40, 40, 30.4, "亮度统计", fs=7, rad=0.12, off=(-8, -1.0))
    arrow(ax, 80, 40, 92, 30.4, "中性候选统计", fs=7, rad=-0.12, off=(9, -1.0))
    arrow(ax, 88, 30.2, 79, 39.8, rad=-0.15)
    ax.text(77.5, 33.5, "增益回注 color_correct", fontsize=7, color="#444444", ha="right")

    # AE 执行链(左)
    box(ax, 1, 18, 14, 12, "I2C 请求/\n确认桥\nuicfgcs500", fs=7.5)
    arrow(ax, 20, 24, 15.4, 24)
    ax.text(17.7, 24, "曝光码/增益档", fontsize=6.5, color="#444444", ha="center", va="center", rotation=90)
    arrow(ax, 6, 30, 6, 39.8)
    ax.text(1.5, 34.5, "写传感器寄存器", fontsize=7, color="#444444", ha="left")

    # 网络命令覆盖(右缘虚线)
    box(ax, 120, 18, 30, 12, "网络命令(cvp_cmd_rx)\nUDP 6001\n手动/预设/K 覆盖·模式切换", fc="#FEF9E7", ec="#B7950B", fs=7.5)
    arrow(ax, 120, 22, 102.4, 22, "参数覆盖", fs=7, ls="--", off=(0, -3.4), color="#8A6D0B")
    arrow(ax, 128, 18, 38, 14.5, rad=-0.18, ls="--", color="#8A6D0B")
    ax.text(83, 10.5, "曝光/增益手动设定(关闭自动,经 I2C 桥执行)", fontsize=7, color="#8A6D0B", ha="center")

    ax.text(1, 4, "ISP 层 = 像素处理链(实线,流式) + 两个统计-控制闭环:AWB 闭环回注数字增益(帧内作用),"
                  "AE 闭环经 I2C 作用于传感器(1~2 帧生效);两闭环统计均取自白平衡后图像,手动命令可随时接管。",
            fontsize=7.5, color="#555555")
    fig.savefig("fig_isp_3a.pdf", bbox_inches="tight")
    fig.savefig("fig_isp_3a.png", dpi=160, bbox_inches="tight")
    plt.close(fig)


if __name__ == "__main__":
    import sys
    if "--legacy" not in sys.argv[1:]:
        raise SystemExit("Archived Matplotlib diagrams are superseded by the reviewed ImageGen figures. Pass --legacy only to intentionally regenerate the old diagrams.")
    fig_system(); fig_mainboard(); fig_subboard(); fig_isp_3a()
    print("done")

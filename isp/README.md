# rtl/isp —— ISP 处理段

对应框图中间的绿框：**DPC → Demosaic → AWB → 96转128**。

| 文件 | 对应框图 | 状态 |
|---|---|---|
| `cvp_proc.v` | 齿轮箱（RAW10 4→1 解包），串 DPC → Demosaic | ✅ 已实现 |
| `cvp_dpc.v` | RAW 域坏点检测/矫正（新增，框图外） | ✅ 已实现 |
| `cvp_awb.v` | AWB 自动白平衡（灰世界 + 高光剔除，Q16 增益，逐位试商除法） | ✅ 已实现 |
| （待建）`cvp_pack_96to128.v` | 96bit(4×RGB888) → 128bit | ⚠️ 现在合并在 `mem/cvp_frame_buffer.v` |

`cvp_awb.v` 已经接进 `cvp_top.v`（Demosaic → **AWB** → 帧缓存），固定延迟 2 拍，
统计整帧 R/G/B 均值算增益、用上一帧的统计调当前帧；自检见 `sim/tb_cvp_awb.v`。

补充：`cvp_proc.v` 里还带着 6 种**像素级**算法（灰度/二值化/简化边缘/反色/红蓝交换/
亮度增强），按框图这些属于「读出通路」，最终应和 `imgproc/` 一起挪到读 FIFO 之后。

## cvp_dpc（坏点检测/矫正）要点

- **位置**：`cvp_proc` 内齿轮箱之后、`cvp_demosaic` 之前（RAW10 域）——坏点经过
  彩色重建会扩散成 5 像素十字彩色斑，必须提前修。
- **算法**：3x3 窗口 4 个对角点天然同色（任何 Bayer 相位成立，无需相位信息）；
  两级判据 `c > max+TH 且 c > avg+TH2`（亮点）/ `c+TH < min 且 c+TH2 < avg`（暗点），
  命中才用同色邻居中位数替换，其余直通。行首第 1 个槽位邻居跨行回绕，直接旁路。
- **参数**：`TH=64 / TH2=32`（RAW10）。高增益噪声大时可调大，或仿照 AWB 按帧统计调阈值。
- **时序**：复用 `imgproc_win3x3(DW=10)`，固定 3 拍；`cvp_proc` 总延迟变 3(齿轮箱)+3(DPC)+3(demosaic) 拍，
  valid/frame_start 跟数据同步平移，下游无感。
- **自检**：`sim/dpc_sim.do`（独立库 work_dpc，不碰主 work 库），注入 8 个坏点
  全部按邻居中位数修复、平滑背景零误检、随机纹理下与 golden 参考模型逐位一致。
- **已知局限**：1 像素宽的水平/垂直细线会被误矫（沿线的同色像素不在 3x3 对角
  集合里）；显微目标远大于 1px 可忽略，必要时升级 5x5 窗口 8 同色邻居。

接口：40bit/拍 RAW10 进 → 1 像素/拍 RGB888 出；输出 `o_pix_valid/o_pix_rgb/
o_pix_frame_start/o_pix_line_last`。
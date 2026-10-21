`timescale 1ns / 100 fs
/*=============================================================================
 * PLL2 —— 仿真专用行为替代(仅用于 tools/sim 的 RTL 仿真, 不参与综合!)
 *
 * 厂商行为模型(eg_phy_pll 的 EG_PHY_PLL)不自动产生时钟, 需要 load_reg 配置流;
 * 本模块按 PLL2.v 的实际配置给出功能等效时钟:
 *   clk0_out = refclk 直通        (CLKC0_DIV=8, CPHASE=7 → 0 相位)
 *   clk1_out = refclk 滞后 2ns    (CLKC1_DIV=8, CPHASE=5 → 滞后 2ns, RGMII 采样移相)
 * 真实 PLL 的起振/精度仍由板上验证, 本模块只保证 IDDR 采样与字节拼装的逻辑正确性。
 *===========================================================================*/
module PLL2 (
  input  wire refclk,
  input  wire reset,
  output wire extlock,
  output wire clk0_out,
  output wire clk1_out
);
  assign clk0_out = refclk;
  assign #2 clk1_out = refclk;    // 2ns 移相: 与 CLKC1_CPHASE=5 板上配置一致
  assign extlock = ~reset;
endmodule

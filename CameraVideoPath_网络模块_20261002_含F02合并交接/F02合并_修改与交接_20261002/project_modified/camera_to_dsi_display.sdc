create_clock -name {sys_clk_25m} -period 40.000 -waveform {0.000 20.000} [get_ports {I_sys_clk}]
create_clock -name {mipi_rx_ck_pad} -period 2.222 -waveform {0.000 1.111} [get_nets {IO_rx_clk_pad_p}]

derive_clocks

rename_clock -name {pll_clk_100m} [get_clocks {u_PLL/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[0]}]
rename_clock -name {pll_clk_24m} [get_clocks {u_PLL/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[1]}]
rename_clock -name {dpll_ref_clk} [get_clocks {u_PLL/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[2]}]
rename_clock -name {pll_clk_10m} [get_clocks {u_PLL/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[3]}]

rename_clock -name {MIPI_RX_BYTE_CLK} [get_clocks {u_mipi_dphy_rx_ph1p_mipiio_wrapper/u_ph1p_mipiio_rx_wrapper/u_PH1P_LOGIC_DPHY_MIPI_RX.o_fabric_div4_8_clk}]
rename_clock -name {MIPI_TX_BYTE_CLK} [get_clocks {u_mipi_dphy_tx_over_ph1p_mipiio_wrapper/u_ph1p_mipiio_tx_wrapper/u_PH1P_LOGIC_DPHY_MIPI_TX.o_fabric_div4_8_clk}]

set_clock_groups -name group -exclusive -group [get_clocks {MIPI_RX_BYTE_CLK}] -group [get_clocks {MIPI_TX_BYTE_CLK}] -group [get_clocks {mipi_rx_ck_pad}] -group [get_clocks {dpll_ref_clk}] -group [get_clocks {pll_clk_100m}] -group [get_clocks {pll_clk_10m}] -group [get_clocks {pll_clk_24m}]  -group [get_clocks {sys_clk_25m}] -group [get_clocks {u_ph1p35_324_ddr_wrapper/u_ddr2/ddr_clk}] -group [get_clocks {u_ph1p35_324_ddr_wrapper/u_ddr2/usr_clk}] -group [get_clocks {u_pll_gmii125/PH1P_PHY_PLL_WRAPPER_d2616deaaa79_Inst/u_PH1P_PHY_PLL.clkc[0]}]

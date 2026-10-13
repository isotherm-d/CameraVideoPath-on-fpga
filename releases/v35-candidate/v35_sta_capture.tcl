import_device ph1_35p.db -package PH1P35MDG324 -speed 3
import_db {C:/Users/cqm87/Desktop/2026/cvp/CameraVideoPath-on-fpga/08_csi_dsi_cs500_7cun/td_project/camera_to_dsi_display_Runs/phy_1/camera_to_dsi_display_pr.db}
update_timing -mode final
set ae_regs [get_regs {advanced/ae/*}]
puts "AE_REG_COUNT [llength $ae_regs]"
report_timing_path -file ae_internal.timing -ep_num 10 -path_num 1 -from $ae_regs -to $ae_regs
exit

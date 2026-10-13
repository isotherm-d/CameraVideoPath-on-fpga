import_device ph1_35p.db -package PH1P35MDG324 -speed 3
import_db {C:/Users/cqm87/Desktop/2026/tmp/v35_before_timing_main_runs_20261013/phy_1/camera_to_dsi_display_pr.db}
update_timing -mode final
set dsp_pins [get_pins {advanced/ae/mult*.y* advanced/ae/mult*.ce*}]
puts "AE_DSP_PIN_COUNT [llength $dsp_pins]"
report_timing_path -file ae_dsp_endpoints.timing -ep_num 10 -path_num 1 -to $dsp_pins
exit

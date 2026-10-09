open_project C:/Users/cqm87/Desktop/2026/cvp/CameraVideoPath-on-fpga/HDMI_OUT/HDMI_OUT.al
reset_runs syn_1
launch_runs {syn_1 phy_1} -jobs 1
wait_run syn_1
wait_run phy_1
puts "FULL_CHECK_DONE"
close_project
exit

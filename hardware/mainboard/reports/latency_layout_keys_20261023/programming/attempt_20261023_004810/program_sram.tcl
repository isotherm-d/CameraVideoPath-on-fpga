connect_cable -host_name 127.0.0.1:6555
set target [read_device_id -cable 0]
puts "IDENTIFIED_TARGET=$target"
if {[string trim $target] ne "PH1P35MDG324"} {puts "TARGET_MISMATCH_NO_DOWNLOAD"; exit 2}
set code [catch {download -bit {C:/Users/cqm87/Desktop/2026/cvp/camera processing unit/hardware/mainboard/reports/latency_layout_keys_20261023/physical/camera_to_dsi_display.bit} -mode jtag -spd 7 -cable 0} result]
puts "TD_DOWNLOAD_CATCH=$code"
puts "TD_DOWNLOAD_RESULT=$result"
if {$code != 0} {exit 3}
exit

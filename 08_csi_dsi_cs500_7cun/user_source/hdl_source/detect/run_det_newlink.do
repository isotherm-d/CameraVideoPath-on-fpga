# tb_det_newlink 一键回归（本 do 与被测文件同在 detect/ 目录）
vlib work
vlog -work work det_color_feat.v det_wbc20.v det_roi_bridge.v
vlog -work work tb_det_newlink.v
vsim -c -t 1ns -voptargs="+acc" work.tb_det_newlink
run -all
quit -f

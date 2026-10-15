# tb_roi_pixfill 一键回归（本 do 与被测文件同在 detect/ 目录）
vlib work
vlog -work work u_roi_pixfill.v
vlog -work work tb_roi_pixfill.v
vsim -c -t 1ns -voptargs="+acc" work.tb_roi_pixfill
run -all
quit -f

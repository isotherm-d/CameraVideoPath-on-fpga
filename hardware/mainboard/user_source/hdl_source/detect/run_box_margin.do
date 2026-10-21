# tb_box_margin 一键回归（外扩/钳位/退化框，本 do 与被测文件同在 detect/ 目录）
vlib work
vlog -work work cvp_box_overlay.v tb_box_margin.v
vsim -c -t 1ns -voptargs="+acc" work.tb_box_margin
run -all
quit -f

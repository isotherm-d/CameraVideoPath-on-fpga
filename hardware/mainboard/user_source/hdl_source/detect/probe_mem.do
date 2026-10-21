run 19500 us
exa -radix unsigned /tb_det_newlink/u_wbc/s_amax
foreach i {0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15} {
    echo "=== label $i ==="
    exa -radix unsigned "/tb_det_newlink/u_wbc/scnt\[$i\]"
    exa -radix unsigned "/tb_det_newlink/u_wbc/s_mnx\[$i\]"
    exa -radix unsigned "/tb_det_newlink/u_wbc/s_mxx\[$i\]"
    exa -radix unsigned "/tb_det_newlink/u_wbc/s_mny\[$i\]"
    exa -radix unsigned "/tb_det_newlink/u_wbc/s_mxy\[$i\]"
}
quit -f

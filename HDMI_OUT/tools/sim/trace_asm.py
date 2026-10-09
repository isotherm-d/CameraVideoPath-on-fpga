#!/usr/bin/env python3
"""流式解析 net2vid.vcd: 只打印 u_asm 域关键信号事件 (VCD 天然时间有序)."""
import sys

SHOW = {"udp_rx_valid", "w_hdr_last", "w_accept", "r_take", "r_desc_cnt",
        "S_out", "o_frame_cnt", "r_pushed", "r_committed", "r_desc_wr",
        "w_st_used", "r_bcnt", "r_hdr", "i_udp_valid", "w_stage_ok"}

S_OUT = {"0": "IDLE", "1": "FILL", "2": "DATA", "3": "FS", "4": "FSW", "5": "BLANK"}


def main(path, t_end_ns, limit=200):
    ids = {}          # ident -> full name
    path_stack = []
    t = 0
    shown = 0
    with open(path, errors="ignore") as f:
        in_defs = True
        for line in f:
            line = line.strip()
            if in_defs:
                if line.startswith("$scope"):
                    path_stack.append(line.split()[2])
                elif line.startswith("$upscope"):
                    path_stack.pop()
                elif line.startswith("$var"):
                    p = line.split()
                    ids[p[3]] = ".".join(path_stack + [p[4]])
                elif line.startswith("$enddefinitions"):
                    in_defs = False
                continue
            if not line:
                continue
            ident = None
            if line[0] == "#":
                t = int(line[1:])
                if t > t_end_ns:
                    break
            elif line[0] == "b":
                val, ident = line[1:].split(" ", 1)
            elif line[0] in "01xz":
                val, ident = line[0], line[1:]
            else:
                continue
            full = ids.get(ident)
            if not full:
                continue
            leaf = full.rsplit(".", 1)[-1]
            if leaf not in SHOW or not full.startswith("tb_cvp_net2vid.u_asm"):
                continue
            s = val
            if leaf == "r_hdr" and len(val) == 48 and set(val) <= set("01"):
                s = "[" + " ".join("%02x" % int(val[i:i + 8], 2) for i in range(0, 48, 8)) + "]"
            elif leaf == "S_out":
                s = S_OUT.get(val, val)
            elif val not in ("x", "z"):
                s = "%d" % int(val, 2)
            print("%9d %-14s = %s" % (t, leaf, s))
            shown += 1
            if shown >= limit:
                print("...(达到打印上限)")
                break


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "net2vid.vcd",
         int(sys.argv[2]) if len(sys.argv) > 2 else 300000,
         int(sys.argv[3]) if len(sys.argv) > 3 else 200)

"""v10 端到端内容级模拟(GMII 时基): 97bit 保守FIFO + 12拍展开器 + tuser 对齐.
真实时钟比: 像素域 40.2MHz 突发 / GMII 125MHz => 每输入拍间隔 ~3.1 GMII 拍."""
W, H = 1024, 600
PX_LAST = W * H * 3 - 1
NFRAMES = 3
BEATS = W // 4                       # 256 拍/行

# ---------- GMII 时基事件表 ----------
events = []
pix = 0
toggle = 0
for fn in range(NFRAMES):
    for row in range(H):
        for b in range(BEATS):
            sof = (b == 0 and row == 0)
            events.append((True, (pix, sof)))
            pix += 1
            n = 3 if toggle == 0 else 4     # 3.1 均值: 写入后隔 2-3 拍
            toggle ^= 1
            events.extend([(False, None)] * (n - 1))
        events.extend([(False, None)] * 4200)   # 行剩余静默(44.4us 行周期近似)
    events.extend([(False, None)] * 9000)       # 帧间 vblank 近似

# ---------- 保守 FIFO ----------
fifo_mem = []
class ConsFifo:
    def __init__(s):
        s.w = s.r = 0
        s.hist = []
        s.rd_valid = False
        s.rd_data = None
    def tick(s, wr, data, rd_en):
        ov, od = s.rd_valid, s.rd_data
        s.hist.append(s.w)
        wrs2 = s.hist[-3] if len(s.hist) >= 3 else 0
        if wr:
            fifo_mem.append(data); s.w += 1
        radv = rd_en and (s.r + 1 <= wrs2)
        if radv:
            s.rd_data = fifo_mem[s.r]; s.r += 1; s.rd_valid = True
        else:
            s.rd_valid = False
        return ov, od

f = ConsFifo()
r_px = 0; r_bsel = 0; r_sel = 0
r_beat = 0; r_run = False; r_sof_pending = False
r_capture = False; r_burst = 0
written = []
frame_marks = []
SOF_CNT = 0

def pix_bytes(p):
    return [(p >> 16) & 0xFF, (p >> 8) & 0xFF, p & 0xFF]

for wr, data in events:
    wrs2 = f.hist[-2] if len(f.hist) >= 2 else 0
    w_pxf_empty = not (f.r + 1 <= wrs2)
    w_pxf_valid = f.rd_valid
    w_pxf_data = f.rd_data
    w_pxf_rd = (not w_pxf_empty) and ((not r_run) or (r_sel == 3 and r_bsel == 1))
    w_load = (not r_run) and w_pxf_valid
    w_adv = r_run or w_load
    w_beat_first = w_load or (r_run and r_sel == 0 and r_bsel == 0)
    if w_beat_first:
        w_sof = (w_pxf_data[1] if w_load else r_sof_pending) if (w_load or r_sof_pending) else False
    else:
        w_sof = False
    p_beat = w_pxf_data[0] if w_load else r_beat
    w_cur = ((p_beat*4)   << 72) | ((p_beat*4+1) << 48) |             ((p_beat*4+2) << 24) |  (p_beat*4+3)
    w_byte = (w_cur >> ((3 - r_sel) * 24 + (2 - r_bsel) * 8)) & 0xFF
    w_frame_last = (r_px == PX_LAST)
    w_cap_now = True if w_sof else r_capture
    w_write = w_adv and w_cap_now
    w_chunk_done = w_write and (r_burst == 1439)

    n_px, n_bsel, n_sel = r_px, r_bsel, r_sel
    n_beat, n_run, n_sof = r_beat, r_run, r_sof_pending
    n_capture = r_capture
    n_burst = r_burst
    if w_adv:
        if r_sel == 3 and r_bsel == 2: n_sel, n_bsel = 0, 0
        elif r_bsel == 2:             n_sel, n_bsel = r_sel + 1, 0
        else:                         n_bsel = r_bsel + 1
        if w_load:
            n_beat = w_pxf_data[0]; n_sof = False; n_run = True
        elif r_sel == 3 and r_bsel == 2:
            if w_pxf_valid:
                n_beat = w_pxf_data[0]; n_sof = w_pxf_data[1]
            else:
                n_run = False; n_sof = False
        if w_sof or w_frame_last:
            n_px = 0; n_capture = True
            if w_sof:
                SOF_CNT += 1
                frame_marks.append(len(written) + (1 if w_write else 0))
        else:
            n_px = r_px + 1
        if w_chunk_done: n_burst = 0
        elif w_write:   n_burst = r_burst + 1
    if w_write: written.append(w_byte)
    if len(written) < 12 and w_adv:
        print(f'w{len(written)}: sel={r_sel} bsel={r_bsel} beat={p_beat} w_cur={w_cur:024x} sh={(3-r_sel)*24+(2-r_bsel)*8} byte={w_byte:02x}')
    f.tick(wr, data, w_pxf_rd)
    r_px, r_bsel, r_sel = n_px, n_bsel, n_sel
    r_beat, r_run, r_sof_pending = n_beat, n_run, n_sof
    r_capture, r_burst = n_capture, n_burst

# ---------- 校验 ----------
print(f'SOF 触发: {SOF_CNT} 次(应 >= {NFRAMES}), FIFO 读/写: {f.r}/{len(fifo_mem)} 拍')
print(f'written {len(written)} B (3帧预算 {NFRAMES*W*H*3} B)')
if len(frame_marks) >= 2:
    i0 = frame_marks[0] - 1          # 帧首字节位置(记录的是首字节下一位置)
    nframes_cap = len(frame_marks) - 1
    n_expect = nframes_cap * W * H * 3
    got = written[i0:]
    exp = []
    for fn in range(nframes_cap):
        base = fn * BEATS * H
        for p in range(base, base + BEATS * H):
            for k in range(4):            # 每拍 4 像素
                exp += pix_bytes(p * 4 + k)
    n = min(len(got), len(exp))
    mism = sum(1 for a, b in zip(got[:n], exp[:n]) if a != b)
    # 帧边界应恰好在 n*W*H*3 处
    bounds_ok = all(frame_marks[i] - frame_marks[0] == i * W * H * 3 for i in range(len(frame_marks)))
    print(f'内容校验 {n} B, 失配 {mism} 处')
    print(f'帧边界等间距(W*H*3={W*H*3}): {bounds_ok}, 边界 {frame_marks}')
    print('=== 吞吐+内容+帧对齐:', 'PASS' if mism == 0 and bounds_ok else 'FAIL', '===')
    if mism:
        print('got[:24]:', [f'{b:02x}' for b in got[:24]])
        print('exp[:24]:', [f'{b:02x}' for b in exp[:24]])
        print('拍0数据(像素0..3):')
        for k in range(4): print('  px', k, pix_bytes(k))
else:
    print('SOF 不足, FAIL')

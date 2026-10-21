"""无头抓帧: 监听 6000 收 4 秒, 按帧序号拼帧, 存最新一帧 PNG 并输出统计。"""
import socket, sys, time
import numpy as np

W, H, DB, HDR = 1280, 720, 1440, 6
CPF = (W * H * 3) // DB          # 1920
DUR = 4.0

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 64 << 20)
sock.bind(("0.0.0.0", 6000))
sock.settimeout(0.2)

frames = {}          # seq -> [buf, mask_count]
pkt = hb = bad = 0
t0 = time.perf_counter()
seq_times = []       # 每个新帧首个包的到达时间
last_seq = None
while time.perf_counter() - t0 < DUR:
    try:
        data, addr = sock.recvfrom(65536)
    except socket.timeout:
        continue
    if len(data) < HDR:
        continue
    fseq = data[0]; fmt = data[1]
    off = int.from_bytes(data[2:6], "big")
    if fmt == 2:
        hb += 1
        continue
    if fmt != 1 or len(data) - HDR != DB or off % DB:
        bad += 1
        continue
    pkt += 1
    ch = off // DB
    if fseq != last_seq:
        last_seq = fseq
        seq_times.append(time.perf_counter() - t0)
    fr = frames.setdefault(fseq, [bytearray(W * H * 3), 0])
    if ch < CPF and not fr[1] & (1 << 0):     # 只记一次即可, 用简单判重: 值非零不代表未写过, 简化处理
        pass
    fr[0][off:off + DB] = data[HDR:]
    fr[1] += 1

el = time.perf_counter() - t0
print(f"收到: 视频 {pkt} 包, 心跳 {hb}, 异常 {bad}, 帧数(按seq变化) {len(frames)}, {el:.1f}s")
if len(seq_times) > 1:
    iv = seq_times[-1] - seq_times[1] if len(seq_times) > 2 else seq_times[-1] - seq_times[0]
    print(f"帧间隔估计: {iv / max(1, len(seq_times) - 2) * 1000:.1f} ms -> {1 / (iv / max(1, len(seq_times) - 2)):.1f} fps")
# 取收到包数最多的帧(最完整)
best_seq = max(frames, key=lambda s: frames[s][1])
best, cnt = frames[best_seq]
print(f"最完整帧 seq={best_seq}: {cnt}/{CPF} 包 ({cnt / CPF * 100:.1f}%)")
if cnt >= CPF * 0.9:
    img = np.frombuffer(bytes(best), dtype=np.uint8).reshape(H, W, 3)
    # 板端 RGB 通道序未标定: 原样存一份 + R/B 交换各存一份
    import cv2
    cv2.imwrite("cap_frame_rgb.png", cv2.cvtColor(img, cv2.COLOR_RGB2BGR))
    cv2.imwrite("cap_frame_swap.png", cv2.cvtColor(img[:, :, ::-1].copy(), cv2.COLOR_RGB2BGR))
    print("已存 cap_frame_rgb.png / cap_frame_swap.png (R/B 两种通道序)")
    for name, ch in (("R", img[:, :, 0]), ("G", img[:, :, 1]), ("B", img[:, :, 2])):
        print(f"  {name}: mean={ch.mean():6.1f} max={ch.max():3d} std={ch.std():5.1f}")
else:
    print("帧不完整, 不存图")

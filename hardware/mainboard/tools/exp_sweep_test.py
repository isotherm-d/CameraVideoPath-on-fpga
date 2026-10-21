"""exp_sweep_test —— 曝光-错位带 阈值扫描脚本(v23c)

原理: 贴近满帧曝光会让传感器读出窗相对帧同步偏移数行, 720 行窗口的顶或底
出现错位带(内容来自上一帧尾/下一帧头/帧内别处)。本脚本从 1940 逐档下扫到 1400,
每档抓帧并分析, 结束时恢复到"最亮的干净档"。

两个检测指标(对场景内容不敏感):
  A 来源行: 顶/底 10 行的每一行, 在全帧范围(排除近邻)找最佳匹配行 ——
     相关>0.85 即"该行内容来自别处"(报来源行号)。重复纹理(白墙)会弱判定为"?"。
  B 水平错位: 帧边界处相邻行做 ±1..66 像素滚动相关, 在非零位移处匹配>0.85
     即"边界行水平错位"(报位移像素)。

用法(重要):
  1. 先关闭 cam_gui 等一切收图程序(必须独占 UDP 6000, 否则分流测不准)
  2. 相机保持静止, 画面内尽量不要有人走动
  3. python exp_sweep_test.py
  4. 把整张输出表发回; sweep_<exp>.png 为各档截图, 需要时一并看
"""
import socket, time
import numpy as np

W, H, DB, HDR = 1280, 720, 1440, 6
CPF = (W * H * 3) // DB
TARGET = ("192.168.1.255", 6001)
MAGIC = bytes([0xC5, 0xA5, 0x50, 0x01])
EXPS = [1940, 1900, 1850, 1800, 1750, 1700, 1650, 1600, 1550, 1500, 1400]


def send_exp(tx, v):
    tx.sendto(MAGIC + bytes([1]) + v.to_bytes(3, "big"), TARGET)


def capture(rx, dur=1.5):
    frames = {}
    t0 = time.perf_counter()
    while time.perf_counter() - t0 < dur:
        try:
            data, _ = rx.recvfrom(65536)
        except socket.timeout:
            continue
        if len(data) < HDR:
            continue
        fseq, fmt = data[0], data[1]
        off = int.from_bytes(data[2:6], "big")
        if fmt != 1 or len(data) - HDR != DB or off % DB:
            continue
        fr = frames.setdefault(fseq, [bytearray(W * H * 3), 0])
        fr[0][off:off + DB] = data[HDR:]
        fr[1] += 1
    if not frames:
        return None, 0
    seq = max(frames, key=lambda s: frames[s][1])
    buf, cnt = frames[seq]
    return np.frombuffer(bytes(buf), dtype=np.uint8).reshape(H, W, 3), cnt


def _norm(m):
    m = m.astype(np.float32)
    m = m - m.mean(axis=1, keepdims=True)
    return m / np.maximum(np.linalg.norm(m, axis=1, keepdims=True), 1e-6)


def analyze(img):
    """返回 (问题行报告 list[str], 顶底包裹相关 float)"""
    R = _norm(img.reshape(H, -1))
    sim = R @ R.T
    np.fill_diagonal(sim, -2)
    rep = []
    # A: 顶/底 10 行的来源(参考信息: 重复纹理场景会误报, 判定以 B/包裹为准)
    for r in list(range(0, 10)) + list(range(H - 10, H)):
        far = np.abs(np.arange(H) - r) > 3
        row = np.where(far, sim[r], -2)
        t = int(np.argmax(row))
        best = float(row[t])
        top5 = np.sort(row)[-5:]
        if best > 0.90 and float(np.median(top5)) < 0.80:
            rep.append(f"行{r}:内容来自行{t}(r={best:.2f})[参考]")
    # B: 边界水平错位
    for a in list(range(0, 3)) + list(range(H - 4, H - 1)):
        ra = img[a].astype(np.float32).ravel()
        rb = img[a + 1].astype(np.float32).ravel()
        ra_n = _norm(ra.reshape(1, -1))[0]
        best_k, best_c = 0, -1.0
        for k in range(-198, 199, 3):       # ±66 像素, 步长 1 像素(k 必须是 3 的倍数才像素对齐)
            rbk = np.roll(rb, k)
            rbk = (rbk - rbk.mean()) / max(np.linalg.norm(rbk - rbk.mean()), 1e-6)
            c = float(ra_n @ rbk)
            if c > best_c:
                best_k, best_c = k // 3, c
        if abs(best_k) >= 2 and best_c > 0.85:
            rep.append(f"行{a}->{a+1}:水平错位{best_k}px(r={best_c:.2f})")
    wrap = float(sim[H - 8:H, 0:8].max())
    return rep, wrap


def main():
    tx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    rx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    rx.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 64 << 20)
    try:
        rx.bind(("0.0.0.0", 6000))
    except OSError:
        print("绑定 6000 失败: 请先关闭 cam_gui / 其它收图程序!"); return
    rx.settimeout(0.2)

    results = []
    for e in EXPS:
        send_exp(tx, e)
        time.sleep(0.4)                      # 曝光写入第 N 帧, 第 N+2 帧生效
        img, cnt = capture(rx)
        if img is None or cnt < CPF * 0.95:
            print(f"exp={e:4d}: 收帧不足({cnt}/{CPF}), 跳过")
            results.append((e, None)); continue
        rep, wrap = analyze(img)
        try:
            import cv2
            cv2.imwrite(f"sweep_{e}.png", cv2.cvtColor(img, cv2.COLOR_RGB2BGR))
        except ImportError:
            pass
        bad = (wrap >= 0.8) or any("水平错位" in x for x in rep)
        info = "; ".join(rep[:4])
        verdict = ("!! " + (("包裹=" + f"{wrap:.2f}") if wrap >= 0.8 else "") +
                   ("; " if wrap >= 0.8 and info else "") + info).strip(" !;") if bad else \
                  ("干净" + (f" (参考: {info})" if info else ""))
        print(f"exp={e:4d}: 完整{cnt / CPF * 100:3.0f}%  包裹={wrap:.2f}  -> {verdict}")
        results.append((e, bad, wrap))

    clean = [e for e, bad, w in results if not bad and w is not None]
    final = max(clean) if clean else 1400
    send_exp(tx, final)
    print(f"\n结论: 最亮干净档 = {final} (已恢复该值)。"
          f"\n建议: 固件默认取 {max(final - 50, 62)}, 钳位上限取 {max(final - 20, 62)}。")
    if not clean:
        print("!! 全区间都报异常 —— 可能不是曝光问题(或场景重复纹理干扰), 把输出发回来")


if __name__ == "__main__":
    main()

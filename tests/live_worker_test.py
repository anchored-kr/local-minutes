#!/usr/bin/env python3
"""앱과 같은 순서로 작업자를 시험한다: 녹음을 앱의 녹음 엔진과 같은 규칙(4초 이상 쌓인 뒤 말이 0.3초 끊긴 곳,
최대 15초)으로 잘라 보내고(실시간), 끝나면 전체 녹음으로 화자 정리.

사용: python3 tests/live_worker_test.py <가짜 회의 폴더>
"""
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
d = Path(sys.argv[1]).resolve()
tmp = Path(tempfile.mkdtemp())
full = tmp / "full.wav"
subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-i", str(d / "mic.caf"), "-i", str(d / "system.caf"),
                "-filter_complex", "[0:a]aresample=16000,pan=mono|c0=c0[a];[1:a]aresample=16000,pan=mono|c0=0.5*c0+0.5*c1[b];"
                "[a][b]amerge=inputs=2", "-c:a", "pcm_s16le", str(full)], check=True)
raw = tmp / "audio.raw"
subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-i", str(full), "-f", "s16le", "-c:a", "pcm_s16le", str(raw)], check=True)
dur = raw.stat().st_size / 4 / 16000
w = subprocess.Popen([str(ROOT / "minutes"), "worker"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     stderr=subprocess.DEVNULL, text=True)
assert json.loads(w.stdout.readline()).get("ready")
# 앱의 CaptureEngine.emitChunk 와 같은 자르기 규칙
import array
pcm = array.array("h", raw.read_bytes())
n = len(pcm) // 2
mix = [(pcm[2 * k] + pcm[2 * k + 1]) / 2 / 32768 for k in range(n)]
cuts, start, k = [], 0, 0
step = 1600  # 0.1초마다 본다
while k < n:
    k = min(n, k + step)
    length = k - start
    if length >= 15 * 16000:
        cuts.append((start, k)); start = k
    elif length >= 4 * 16000:
        tail = mix[k - 4800:k]
        if (sum(v * v for v in tail) / len(tail)) ** 0.5 <= 0.01:
            cuts.append((start, k)); start = k
if n - start > 8000:
    cuts.append((start, n))
segs = []
for i, (a, b) in enumerate(cuts, 1):
    c = tmp / f"c{i}.wav"
    subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-ss", str(a / 16000), "-t", str((b - a) / 16000),
                    "-i", str(full), "-c:a", "pcm_s16le", str(c)], check=True)
    w.stdin.write(json.dumps({"wav": str(c), "offset": a / 16000, "lang": "auto", "meeting": "m"}) + "\n")
    w.stdin.flush()
    segs += json.loads(w.stdout.readline())["segments"]
print(f"조각 {len(cuts)}개: " + ", ".join(f"{(b - a) / 16000:.1f}초" for a, b in cuts))
live = {s["start"]: s["speaker"] for s in segs}
w.stdin.write(json.dumps({"cmd": "speakers", "meeting": "m", "raw": str(raw), "segments": segs}) + "\n")
w.stdin.flush()
final = {l["start"]: l["speaker"] for l in json.loads(w.stdout.readline())["labels"]}
w.stdin.close()
w.wait()
for s in segs:
    s["speaker"] = final.get(s["start"], s["speaker"])
out = tmp / "result"
out.mkdir()
(out / "transcript.json").write_text(json.dumps(segs, ensure_ascii=False), encoding="utf-8")
(out / "expected.json").write_text((d / "expected.json").read_text(encoding="utf-8"), encoding="utf-8")
print(f"실시간 화자 {len({v for v in live.values() if v.startswith('상대')})}명 → 정리 후 {len(set(final.values()))}명")
for s in segs:
    print(f"  {s['start']:6.1f} {live[s['start']]:>4} → {s['speaker']:>4}  {s['text'][:30]}")
subprocess.run([sys.executable, str(ROOT / "tests" / "score.py"), str(out)])

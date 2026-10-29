#!/usr/bin/env python3
"""화자 분리 기준값 고르기: 실제 회의와 합성 음성 회의에서 실시간 · 끝난 뒤 결과를 기준값별로 본다.

사용: .venv/bin/python tests/speaker_calibrate.py <실제 회의 폴더> [합성 회의 폴더(expected.json 있음)]
실제 회의는 정답이 없으므로 사람 수와, 일본어 문장(한 사람이 말했다고 아는 경우)이 한 번호에 모였는지를 본다.
"""
import difflib
import json
import re
import subprocess
import sys
import tempfile
import wave
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
import speakers as sp  # noqa: E402

JA = re.compile(r"[ぁ-んァ-ヶ]")


def load(d):
    wav = Path(tempfile.mkdtemp()) / "a.wav"
    subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-i", str(d / "audio.m4a"), "-ac", "2", "-ar", "16000",
                    "-c:a", "pcm_s16le", str(wav)], check=True)
    with wave.open(str(wav)) as w:
        a = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).reshape(-1, 2)
    segs = [s for s in json.loads((d / "transcript.json").read_text(encoding="utf-8"))
            if str(s.get("speaker", "")).startswith("상대")]
    return sorted(segs, key=lambda s: s["start"]), a[:, 1].astype(np.float32) / 32768


def live(segs, x, emb, th):
    c = sp.Clusterer(th)
    out = []
    for s in segs:
        if s["end"] - s["start"] >= sp.MIN_SECONDS:
            out.append(c.assign(emb.embed(x[int(s["start"] * 16000):int(s["end"] * 16000)]), s["end"] - s["start"]))
    return len(set(out))


def main():
    emb = sp.Embedder()
    real = Path(sys.argv[1])
    rs, rx = load(real)
    synth = Path(sys.argv[2]) if len(sys.argv) > 2 else None
    if synth:
        ss, sx = load(synth)
        exp = json.loads((synth / "expected.json").read_text(encoding="utf-8"))
        norm = lambda t: "".join(ch for ch in t if ch.isalnum())
        truth = []
        for s in ss:
            e = max(exp, key=lambda e: difflib.SequenceMatcher(None, norm(e["text"]), norm(s["text"])).ratio())
            truth.append(e["speaker"])
    grid = [(sp.TURN_GAP, sp.THRESHOLD)]
    for g, th in grid:
        sp.TURN_GAP = g
        lab = sp.diarize(rs, rx, emb, th)
        ja = [l for s, l in zip(rs, lab) if JA.search(s["text"])]
        ja_share = max(ja.count(k) for k in set(ja)) / len(ja) if ja else 0
        r2 = sp.diarize(rs, rx, emb, th, n_speakers=2)
        ja2 = [l for s, l in zip(rs, r2) if JA.search(s["text"])]
        line = (f"간격 {g} · 기준 {th}: 실제 회의(인원 2 지정) 일본어 한 번호 {max(ja2.count(k) for k in set(ja2)) / len(ja2):.0%}"
                f" | 실제 회의(자동) 끝난 뒤 {len(set(lab))}명 (일본어 문장 한 번호 {ja_share:.0%})"
                f" · 실시간 {live(rs, rx, emb, th)}명")
        if synth:
            sl = sp.diarize(ss, sx, emb, th)
            pairs = {}
            for t, l in zip(truth, sl):
                pairs.setdefault(t, []).append(l)
            ok = sum(max(v.count(k) for k in set(v)) for v in pairs.values())
            distinct = len({max(set(v), key=v.count) for v in pairs.values()}) == len(pairs)
            k = sp.diarize(ss, sx, emb, th, n_speakers=3)
            kp = {}
            for t, l in zip(truth, k):
                kp.setdefault(t, []).append(l)
            kok = sum(max(v.count(x) for x in set(v)) for v in kp.values())
            kd = len({max(set(v), key=v.count) for v in kp.values()}) == len(kp)
            line += f" | 합성 3명(인원 3 지정): {len(set(k))}명 · {kok}/{len(k)}{'' if kd else ' (사람이 합쳐짐)'}"
            line += (f" | 합성 3명(자동): 끝난 뒤 {len(set(sl))}명 · {ok}/{len(sl)}{'' if distinct else ' (사람이 합쳐짐)'}"
                     f" · 실시간 {live(ss, sx, emb, th)}명")
        print(line, flush=True)


if __name__ == "__main__":
    main()

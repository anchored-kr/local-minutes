#!/usr/bin/env python3
"""가짜 회의 결과를 기대값과 비교한다: 문장 수 · 말한 사람 정확도. 사용: score.py <회의 폴더>"""
import difflib, json, sys
from pathlib import Path
d = Path(sys.argv[1])
exp = json.loads((d / "expected.json").read_text(encoding="utf-8"))
got = json.loads((d / "transcript.json").read_text(encoding="utf-8"))
norm = lambda s: "".join(ch for ch in s.lower() if ch.isalnum())
# 상대가 여럿이면 번호가 무엇이든 같은 사람이 같은 번호로 묶였는지 본다(가장 많이 겹치는 번호로 짝짓기).
pairs = []
for e in exp:
    best = max(got, key=lambda g: difflib.SequenceMatcher(None, norm(e["text"]), norm(g["text"])).ratio(), default=None)
    pairs.append((e["speaker"], best.get("speaker") if best else None))
mapping = {}
for who in {w for w, _ in pairs if w.startswith("상대") and w != "상대"}:
    cands = [g for w, g in pairs if w == who]
    mapping[who] = max(set(cands), key=cands.count)
if len(set(mapping.values())) < len(mapping):
    print("  ✗ 서로 다른 상대가 같은 번호로 묶임:", mapping)
    mapping = {k: f"?{k}" for k in mapping}
hit = spk = 0
for e in exp:
    e = dict(e, speaker=mapping.get(e["speaker"], e["speaker"]))
    best = max(got, key=lambda g: difflib.SequenceMatcher(None, norm(e["text"]), norm(g["text"])).ratio(), default=None)
    r = difflib.SequenceMatcher(None, norm(e["text"]), norm(best["text"])).ratio() if best else 0
    ok = r > 0.5
    hit += ok
    spk += ok and (best.get("speaker") == e["speaker"] or (e["speaker"] == "상대" and str(best.get("speaker", "")).startswith("상대")))
    if not ok or best.get("speaker") != e["speaker"]:
        print(f"  ✗ {e['speaker']} | {e['text']}\n    → {best and best.get('speaker')} | {best and best['text']} ({r:.2f})")
print(f"{d.name}: 문장 {hit}/{len(exp)} · 말한 사람 {spk}/{len(exp)} · 결과 문장 {len(got)}개")

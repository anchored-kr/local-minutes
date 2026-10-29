"""화자 분리: 목소리 지문(speaker embedding)을 뽑아 비슷한 목소리끼리 묶는다.

- 회의 중: Clusterer 가 문장이 들어오는 대로 지금까지의 사람(평균 지문)과 비교해 붙인다(임시 번호).
- 회의 끝 · 지난 회의: diarize 가 전체 녹음으로 다시 나눈다.
  ① 1.5초 이상 문장마다 지문 → 묶기(사람 수 · 평균 목소리)
  ② 상대 전체 말의 5%(최소 5초)도 안 되는 작은 묶음은 가까운 큰 묶음에 합침
  ③ 1.2초 이상 문장은 하나씩 가장 가까운 사람에 붙임(두 사람이 쉬지 않고 주고받은 차례를 가름)
  ④ 짧은 문장은 시간상 가까운 쪽 사람을 따름
sherpa-onnx(Apache 2.0) · 모델은 models/ 의 .onnx. 네트워크를 쓰지 않는다.
"""
from pathlib import Path

import numpy as np

import os

DATA = Path(os.environ.get("LOCAL_MINUTES_HOME") or Path.home() / "Library/Application Support/LocalMinutes")
MODEL = DATA / "models" / "3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx"  # CAM++, Apache 2.0
# 같은 사람으로 볼 코사인 유사도. 처음(2026-10-29 오전)에는 macOS 합성 음성으로 0.7 을 정했는데,
# 실제 회의(Zoom 압축 음질 · 1~3초 조각)에서 상대 2명이 167명으로 쪼개졌다. 발화 차례 지문으로 바꾸고
# 실제 회의(상대 2명, 33분)에서 간격 0.3 · 기준 0.45 → 2명 · 일본어 문장(한 사람) 100% 한 번호(tests/speaker_calibrate.py).
# macOS 합성 음성끼리는 실제 사람보다 서로 비슷해 이 기준에서 합쳐진다 — 상대 인원을 알면 n_speakers 로 정한다.
THRESHOLD_LIVE = 0.45
THRESHOLD = 0.45
MIN_SECONDS = 1.0     # 실시간: 이보다 짧은 문장은 지문을 뽑지 않는다
NEW_SPEAKER_SECONDS = 2.5   # 실시간: 이보다 짧은 문장으로는 새 사람을 만들지 않는다
TURN_GAP = -1        # 차례로 묶지 않는다: whisper 는 문장 사이 쉼을 앞 문장에 붙여 사람이 바뀌어도 간격이 0초다
TURN_MAX = 20.0
TURN_MIN = 1.5
SEG_MIN = 1.2
MIN_CLUSTER = 5.0
MIN_CLUSTER_SHARE = 0.05   # 상대 전체 말 길이의 5% 도 안 되는 묶음은 가짜로 보고 합친다



class Embedder:
    def __init__(self, model=MODEL):
        import sherpa_onnx
        self.ext = sherpa_onnx.SpeakerEmbeddingExtractor(
            sherpa_onnx.SpeakerEmbeddingExtractorConfig(model=str(model), num_threads=2))

    def embed(self, samples, rate=16000):
        s = self.ext.create_stream()
        s.accept_waveform(rate, np.asarray(samples, dtype=np.float32))
        s.input_finished()
        e = np.array(self.ext.compute(s), dtype=np.float32)
        n = np.linalg.norm(e)
        return e / n if n > 0 else e


class Clusterer:
    """실시간 묶기. 사람 번호는 0부터, 처음 들린 차례대로."""

    def __init__(self, threshold=THRESHOLD_LIVE):
        self.threshold = threshold
        self.sums = []

    def assign(self, e, seconds=99.0):
        if self.sums:
            cents = np.stack([s / np.linalg.norm(s) for s in self.sums])
            sims = cents @ e
            k = int(np.argmax(sims))
            if sims[k] >= self.threshold or seconds < NEW_SPEAKER_SECONDS:
                self.sums[k] = self.sums[k] + e
                return k
        self.sums.append(e.copy())
        return len(self.sums) - 1


def cluster_all(E, threshold=THRESHOLD, n_clusters=None):
    """평균 연결 응집 묶기. n_clusters 를 주면 기준값 대신 그 수가 될 때까지 묶는다.
    번호는 처음 나온 차례대로 다시 매긴다."""
    E = np.asarray(E, dtype=np.float32)
    if len(E) == 0:
        return []
    clusters = [[i] for i in range(len(E))]
    sim = E @ E.T
    while len(clusters) > 1:
        best, pair = -1.0, None
        for a in range(len(clusters)):
            for b in range(a + 1, len(clusters)):
                s = float(sim[np.ix_(clusters[a], clusters[b])].mean())
                if s > best:
                    best, pair = s, (a, b)
        if (n_clusters is None and best < threshold) or (n_clusters is not None and len(clusters) <= n_clusters):
            break
        a, b = pair
        clusters[a] += clusters.pop(b)
    label = {}
    for k, members in enumerate(clusters):
        for i in members:
            label[i] = k
    order = {}
    out = []
    for i in range(len(E)):
        out.append(order.setdefault(label[i], len(order)))
    return out


def fill_nearest(labels, spans, default=0):
    """None 인 자리는 시간상 더 가까운 앞 · 뒤 사람을 따른다."""
    n = len(labels)
    out = list(labels)
    for i in range(n):
        if labels[i] is not None:
            continue
        p = next((j for j in range(i - 1, -1, -1) if labels[j] is not None), None)
        q = next((j for j in range(i + 1, n) if labels[j] is not None), None)
        if p is None and q is None:
            out[i] = default
        elif q is None or (p is not None and spans[i][0] - spans[p][1] < spans[q][0] - spans[i][1]):
            out[i] = labels[p]
        else:
            out[i] = labels[q]
    return out


def diarize(segs, x, embedder, threshold=THRESHOLD, rate=16000, n_speakers=None):
    """상대 문장(시간순 dict: start · end)을 사람별로 나눈다. x = 시스템 오디오(상대) 한 채널.
    n_speakers: 상대 인원을 알면 그 수로 나눈다(작은 묶음 합치기도 그 수 아래로는 하지 않는다).

    돌려주는 값: 문장마다 사람 번호(처음 나온 차례대로 0, 1, …).
    """
    n = len(segs)
    if n == 0:
        return []
    cut = lambda a, b: x[int(a * rate):int(b * rate)]
    # ① 발화 차례
    turns = []
    for i, s in enumerate(segs):
        if turns and s["start"] - segs[turns[-1][-1]]["end"] < TURN_GAP and s["end"] - segs[turns[-1][0]]["start"] < TURN_MAX:
            turns[-1].append(i)
        else:
            turns.append([i])
    tid, temb, tdur = [], [], []
    for t, members in enumerate(turns):
        a, b = segs[members[0]]["start"], segs[members[-1]]["end"]
        if b - a >= TURN_MIN:
            tid.append(t)
            temb.append(embedder.embed(cut(a, b)))
            tdur.append(b - a)
    if not temb:
        return [0] * n
    lab = np.array(cluster_all(temb, threshold, n_speakers))
    E = np.stack(temb)
    # ② 작은 묶음 합치기
    def cents():
        ks = sorted(set(lab.tolist()))
        c = {k: E[lab == k].mean(0) for k in ks}
        return {k: v / np.linalg.norm(v) for k, v in c.items()}
    tdur = np.array(tdur)
    floor = max(MIN_CLUSTER, MIN_CLUSTER_SHARE * float(tdur.sum()))
    while True:
        sizes = {k: tdur[lab == k].sum() for k in set(lab.tolist())}
        small = [k for k, d in sizes.items() if d < floor]
        if not small or len(sizes) == 1 or (n_speakers and len(sizes) <= n_speakers):
            break
        k = min(small, key=lambda k: sizes[k])
        c = cents()
        others = [j for j in c if j != k]
        lab[lab == k] = max(others, key=lambda j: float(c[j] @ c[k]))
    c = cents()
    keys = list(c)
    C = np.stack([c[k] for k in keys])
    # ③ 문장마다 붙이기(긴 문장), 차례 번호(짧은 문장)
    turn_label = {t: int(l) for t, l in zip(tid, lab)}
    labels = [None] * n
    for t, members in enumerate(turns):
        for i in members:
            s = segs[i]
            if len(C) > 1 and s["end"] - s["start"] >= SEG_MIN:
                labels[i] = keys[int(np.argmax(C @ embedder.embed(cut(s["start"], s["end"]))))]
            elif t in turn_label:
                labels[i] = turn_label[t]
    # ④ 짧은 문장
    labels = fill_nearest(labels, [(s["start"], s["end"]) for s in segs], keys[0])
    order = {}
    return [order.setdefault(l, len(order)) for l in labels]

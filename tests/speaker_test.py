#!/usr/bin/env python3
"""목소리 지문 모델 비교: macOS 음성 여러 개로 문장을 만들어 같은 사람 · 다른 사람 유사도와 묶기 정확도를 잰다.

사용: .venv/bin/python tests/speaker_test.py
"""
import subprocess
import sys
import tempfile
import wave
from pathlib import Path

import numpy as np
import sherpa_onnx

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
from speakers import Clusterer, cluster_all  # noqa: E402

VOICES = ["Yuna", "Sora (Enhanced)", "Minsu (Enhanced)", "Reed (한국어(대한민국))", "Kyoko", "Daniel"]
LINES = {
    "ko": ["다음 주 일정을 다시 확인해 보겠습니다.", "그 부분은 제가 담당하겠습니다.", "예산은 지난번과 같게 잡죠.",
           "고객 반응이 생각보다 좋았어요.", "회의는 여기까지 하겠습니다."],
    "Kyoko": ["来週の予定をもう一度確認します。", "その部分は私が担当します。", "予算は前回と同じにしましょう。",
              "お客様の反応は思ったより良かったです。", "会議はここまでにします。"],
    "Daniel": ["Let me check next week's schedule again.", "I will take care of that part.",
               "Let's keep the budget the same as last time.", "Customer feedback was better than expected.",
               "Let's wrap up the meeting here."],
}


def load(path):
    with wave.open(str(path)) as w:
        return np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768


def main():
    tmp = Path(tempfile.mkdtemp())
    clips = []
    for v in VOICES:
        lines = LINES.get(v.split(" ")[0], LINES["ko"])
        for i, text in enumerate(lines):
            aiff, wav = tmp / f"{len(clips)}.aiff", tmp / f"{len(clips)}.wav"
            subprocess.run(["say", "-v", v, "-o", str(aiff), text], check=True)
            subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-i", str(aiff), "-ac", "1", "-ar", "16000",
                            str(wav)], check=True)
            clips.append((v, load(wav)))
    for model in sorted((ROOT / "models").glob("*.onnx")):
        ext = sherpa_onnx.SpeakerEmbeddingExtractor(sherpa_onnx.SpeakerEmbeddingExtractorConfig(model=str(model), num_threads=4))
        embs = []
        for _, x in clips:
            s = ext.create_stream()
            s.accept_waveform(16000, x)
            s.input_finished()
            e = np.array(ext.compute(s))
            embs.append(e / np.linalg.norm(e))
        E = np.stack(embs)
        sim = E @ E.T
        labels = [v for v, _ in clips]
        same = [sim[i, j] for i in range(len(E)) for j in range(i + 1, len(E)) if labels[i] == labels[j]]
        diff = [sim[i, j] for i in range(len(E)) for j in range(i + 1, len(E)) if labels[i] != labels[j]]
        # 실시간(차례로) 묶기와 끝난 뒤 전체 묶기의 정확도
        online = Clusterer()
        live = [online.assign(e) for e in E]
        final = cluster_all(E)

        def purity(pred):
            ok = 0
            for c in set(pred):
                members = [labels[i] for i, p in enumerate(pred) if p == c]
                ok += max(members.count(m) for m in set(members))
            return ok / len(pred)

        print(f"{model.name}\n  같은 사람 유사도 평균 {np.mean(same):.2f} (최소 {np.min(same):.2f})"
              f" · 다른 사람 평균 {np.mean(diff):.2f} (최대 {np.max(diff):.2f})"
              f"\n  실시간 묶기: {len(set(live))}명 · 정확도 {purity(live):.0%}"
              f" · 끝난 뒤 묶기: {len(set(final))}명 · 정확도 {purity(final):.0%} (정답 {len(VOICES)}명)")


if __name__ == "__main__":
    main()

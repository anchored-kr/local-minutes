#!/usr/bin/env python3
"""macOS 음성으로 가짜 회의 녹음(mic.caf · system.caf · recording.json)을 만든다.

나(마이크)와 상대(시스템 오디오)가 번갈아 말하고, 상대 목소리는 스피커 에코처럼
작게(-24 dB) 마이크에도 섞는다. 사용: make_fake_meeting.py <출력 폴더> [ko|en|ja]
"""
import json
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

SCRIPTS = {
    "ko": ("Yuna", "Minsu (Enhanced)", [
        ("나", "안녕하세요, 오늘은 다음 달 출시하는 고깃집 게임의 광고 예산을 정하려고 합니다."),
        ("상대", "네, 지난번에 말씀드린 대로 첫 주에 오십 달러씩 세 개 소재로 시험해 보면 좋겠습니다."),
        ("나", "좋습니다. 소재는 아이콘 두 개와 썸네일 한 개로 하죠. 소재 제작은 제가 금요일까지 하겠습니다."),
        ("상대", "그럼 저는 다음 주 월요일까지 광고 계정 설정을 끝내 두겠습니다. 클릭률 목표는 몇 퍼센트로 잡을까요?"),
        ("나", "일단 삼 퍼센트로 잡고, 일주일 뒤에 다시 보죠. 일본 시장은 아직 정하지 못했습니다."),
        ("상대", "알겠습니다. 일본은 다음 회의에서 다시 이야기하시죠."),
    ]),
    # 상대가 셋: 상대 목소리는 줄 앞 "상대:목소리" 로 정한다.
    "ko3": ("Yuna", "Minsu (Enhanced)", [
        ("나", "오늘은 세 분과 출시 일정을 맞춰 보려고 합니다. 먼저 개발 쪽부터 말씀해 주세요."),
        ("상대:Minsu (Enhanced)", "개발은 다음 주 수요일까지 마무리할 수 있습니다. 결제 화면만 남았어요."),
        ("상대:Sora (Enhanced)", "디자인은 아이콘 두 개가 아직 안 끝났습니다. 금요일까지 드릴게요."),
        ("상대:Reed (한국어(대한민국))", "마케팅은 광고 소재가 준비되면 바로 집행하겠습니다. 예산은 오십 달러로 시작하죠."),
        ("상대:Minsu (Enhanced)", "결제 화면은 디자인이 나와야 붙일 수 있어서 금요일 이후가 되겠네요."),
        ("상대:Sora (Enhanced)", "그럼 결제 화면 시안을 먼저 수요일에 드리겠습니다."),
        ("나", "좋습니다. 출시는 다음 달 첫째 주로 잡겠습니다."),
        ("상대:Reed (한국어(대한민국))", "알겠습니다. 그 일정에 맞춰 광고 계획을 다시 보내드릴게요."),
    ]),
    "en": ("Samantha", "Daniel", [
        ("나", "Hi, today we need to decide the ad budget for next month's launch."),
        ("상대", "Sure. I suggest fifty dollars per creative for the first week, three creatives in total."),
        ("나", "Agreed. Two icons and one thumbnail. I will make the creatives by Friday."),
        ("상대", "Then I will finish the ad account setup by next Monday. What click-through target should we use?"),
        ("나", "Let's start with three percent and review it in a week. We haven't decided on Japan yet."),
        ("상대", "Okay, let's discuss Japan at the next meeting."),
    ]),
    "ja": ("Kyoko", "Eddy (일본어(일본))", [
        ("나", "こんにちは。今日は来月リリースするゲームの広告予算を決めたいと思います。"),
        ("상대", "はい、最初の一週間は素材三つで、それぞれ五十ドルずつテストするのが良いと思います。"),
        ("나", "いいですね。アイコン二つとサムネイル一つにしましょう。素材は私が金曜日までに作ります。"),
        ("상대", "では私は来週の月曜日までに広告アカウントの設定を終わらせます。クリック率の目標はどうしますか。"),
        ("나", "まずは三パーセントにして、一週間後に見直しましょう。韓国市場はまだ決めていません。"),
        ("상대", "わかりました。韓国については次の会議で話しましょう。"),
    ]),
}


def dur(p):
    r = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(p)],
                       capture_output=True, text=True, check=True)
    return float(r.stdout)


def main():
    out = Path(sys.argv[1]).expanduser()
    lang = sys.argv[2] if len(sys.argv) > 2 else "ko"
    me_voice, other_voice, lines = SCRIPTS[lang]
    out.mkdir(parents=True, exist_ok=True)
    tmp = Path(tempfile.mkdtemp())
    t, parts = 0.8, []
    for i, (who, text) in enumerate(lines):
        f = tmp / f"{i}.aiff"
        voice = me_voice if who == "나" else (who.split(":", 1)[1] if ":" in who else other_voice)
        subprocess.run(["say", "-v", voice, "-o", str(f), text], check=True)
        parts.append(("나" if who == "나" else "상대", f, t))
        t += dur(f) + 0.7
    total = t + 0.5

    def track(name, items, echo=()):
        inputs, chains, labels = [], [], []
        for k, (f, start, gain) in enumerate(list(items) + list(echo)):
            inputs += ["-i", str(f)]
            chains.append(f"[{k}:a]aresample=48000,volume={gain},adelay={int(start * 1000)}:all=1[a{k}]")
            labels.append(f"[a{k}]")
        graph = ";".join(chains) + f";{''.join(labels)}amix=inputs={len(labels)}:normalize=0,apad=whole_dur={total}"
        ch = 1 if name == "mic" else 2
        subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-y", *inputs, "-filter_complex", graph,
                        "-ac", str(ch), "-ar", "48000", "-c:a", "pcm_f32le", "-t", str(total), str(out / f"{name}.caf")],
                       check=True)

    track("mic", [(f, s, 1.0) for w, f, s in parts if w == "나"], echo=[(f, s, 0.063) for w, f, s in parts if w == "상대"])
    track("system", [(f, s, 0.8) for w, f, s in parts if w == "상대"])
    meta = {"started_at": datetime.now(timezone.utc).isoformat(), "duration": total,
            "mic": {"file": "mic.caf", "offset": 0.0, "seconds": total, "gap_seconds": 0},
            "system": {"file": "system.caf", "offset": 0.0, "seconds": total, "gap_seconds": 0}}
    (out / "recording.json").write_text(json.dumps(meta, indent=1))
    (out / "title.txt").write_text(f"가짜 회의 시험 ({lang})", encoding="utf-8")
    (out / "expected.json").write_text(json.dumps([{"speaker": w if w == "나" else ("상대" + w.split(":", 1)[1] if ":" in w else "상대"), "text": x}
                                           for w, x in lines], ensure_ascii=False, indent=1),
                                       encoding="utf-8")
    print(f"만듦: {out} · {total:.1f}초")


if __name__ == "__main__":
    main()

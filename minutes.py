#!/usr/bin/env python3
"""local-minutes: 이 맥 안에서만 도는 회의 녹음 · 전사 · 회의록.

  minutes record [-t 제목] [-l auto|ko|en|ja]   녹음 → 끝나면 전사 · 회의록
  minutes process <폴더 또는 오디오 파일>        이미 있는 녹음을 처리
  minutes notes <폴더>                           회의록만 다시 쓰기
  minutes check                                  네트워크 차단 · 모델 · 도구 점검

녹음 뒤의 모든 단계(ffmpeg · whisper · llama)는 macOS 샌드박스 안에서 돈다.
샌드박스는 이 컴퓨터 자신(localhost)을 뺀 모든 네트워크를 막는다.
"""
import argparse
import array
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import time
import urllib.request
import wave
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent   # 코드(앱 안 engine/ 또는 개발 폴더)
# 데이터: 회의 · 모델 · 기록. iCloud 로 동기화되는 문서 폴더가 아닌 Application Support 에 둔다.
DATA = Path(os.environ.get("LOCAL_MINUTES_HOME") or Path.home() / "Library/Application Support/LocalMinutes")
MODELS = DATA / "models"
MEETINGS = DATA / "meetings"
LOGS = DATA / "logs"
RECORDER_APP = ROOT / "recorder" / "LocalMinutesRecorder.app"   # 명령줄 record 전용(개발 폴더)
WHISPER_MODEL = MODELS / "ggml-large-v3-turbo-q5_0.bin"
VAD_MODEL = MODELS / "ggml-silero-v6.2.0.bin"
LLM_MODEL = MODELS / "gemma-4-26B-A4B-it-UD-Q4_K_M.gguf"
GLOSSARY = DATA / "glossary.txt"

SANDBOX_PROFILE = """(version 1)
(allow default)
(deny network*)
(allow network-bind (local ip "localhost:*"))
(allow network-inbound (local ip "localhost:*"))
(allow network-outbound (remote ip "localhost:*"))
(allow network-outbound (remote unix-socket))
"""
# 주의: (allow network* (local ip "localhost:*")) 는 바깥 연결까지 열어 버린다(2026-10-27 시험).

LANG_NAMES = {"ko": "한국어", "en": "English", "ja": "日本語"}


def say(msg):
    # 진행 메시지는 stderr 로. stdout 은 앱이 읽는 결과(chunk 명령의 JSON) 자리다.
    print(msg, file=sys.stderr, flush=True)


def run(cmd, **kw):
    return subprocess.run(cmd, check=True, **kw)


# ---------- 오디오 (앱 경로는 ffmpeg 없이: Python wave + macOS afconvert) ----------

def to_mono(stereo, mono):
    """16-bit 스테레오 WAV → 같은 표본률 모노 WAV(두 채널 평균)."""
    with wave.open(str(stereo)) as w:
        rate, nch = w.getframerate(), w.getnchannels()
        a = array.array("h", w.readframes(w.getnframes()))
    if nch == 2:
        a = array.array("h", ((a[i] + a[i + 1]) // 2 for i in range(0, len(a), 2)))
    with wave.open(str(mono), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(a.tobytes())


def raw_to_wav(raw, wav, rate=16000, channels=2):
    with wave.open(str(wav), "wb") as w:
        w.setnchannels(channels)
        w.setsampwidth(2)
        w.setframerate(rate)
        with open(raw, "rb") as f:
            while chunk := f.read(1 << 22):
                w.writeframes(chunk)


def afconvert(src, dst, *args):
    run(["/usr/bin/afconvert", *args, str(src), str(dst)], stdout=subprocess.DEVNULL)


# ---------- 샌드박스 ----------

def in_sandbox():
    return os.environ.get("LOCAL_MINUTES_SANDBOX") == "1"


def reexec_in_sandbox():
    """외부 네트워크가 막힌 샌드박스 안에서 이 스크립트를 다시 띄운다."""
    if in_sandbox():
        return
    env = dict(os.environ, LOCAL_MINUTES_SANDBOX="1")
    cmd = ["/usr/bin/sandbox-exec", "-p", SANDBOX_PROFILE, sys.executable, "-I", "-B", str(Path(__file__).resolve()), *sys.argv[1:]]
    os.execve(cmd[0], cmd, env)


def network_blocked():
    """샌드박스 안에서 바깥 주소 두 곳과 DNS 로 연결을 시도해 모두 막히는지 본다."""
    for host in [("1.1.1.1", 443), ("8.8.8.8", 53)]:
        try:
            socket.create_connection(host, timeout=3).close()
            return False
        except OSError:
            pass
    try:
        urllib.request.urlopen("https://huggingface.co", timeout=5)
        return False
    except OSError:
        return True


# ---------- 녹음 ----------

def meeting_dir(title):
    stamp = datetime.now().strftime("%Y-%m-%d_%H%M")
    slug = re.sub(r"[^\w가-힣ぁ-んァ-ン一-龥-]+", "-", title).strip("-") if title else ""
    d = MEETINGS / (f"{stamp}_{slug}" if slug else stamp)
    d.mkdir(parents=True, exist_ok=True)
    return d


def bar(peak):
    n = min(8, int(peak * 24 + 0.999)) if peak > 0.002 else 0
    return "▮" * n + "·" * (8 - n)


def recorder_pids(out):
    r = subprocess.run(["pgrep", "-f", f"LocalMinutesRecorder {out}"], capture_output=True, text=True)
    return [int(p) for p in r.stdout.split()]


def record(args):
    if not RECORDER_APP.exists():
        sys.exit(f"녹음기가 없습니다. 먼저 빌드하세요: {ROOT}/recorder/build.sh")
    out = meeting_dir(args.title)
    if args.title:
        (out / "title.txt").write_text(args.title, encoding="utf-8")
    logf = out / "recorder.log"
    run(["open", "-n", "-a", str(RECORDER_APP), "--stdout", str(logf), "--stderr", str(logf), "--args", str(out)])
    say(f"녹음 폴더: {out}")
    say("처음이면 '화면 및 시스템 오디오 녹음'과 '마이크' 권한 창이 뜹니다. 허용하세요.")
    status = out / "status.json"
    deadline = time.time() + 60
    while not status.exists():
        if (out / "error.txt").exists():
            sys.exit("녹음 시작 실패: " + (out / "error.txt").read_text(encoding="utf-8"))
        if time.time() > deadline:
            sys.exit(f"녹음기가 응답하지 않습니다. 로그: {logf}")
        time.sleep(0.5)
    say("녹음 중입니다. 끝내려면 Enter 또는 Ctrl-C.")

    stop = {"now": False}
    signal.signal(signal.SIGINT, lambda *_: stop.update(now=True))
    import select
    while not stop["now"]:
        try:
            s = json.loads(status.read_text())
        except (OSError, json.JSONDecodeError):
            s = {}
        if s.get("state") == "stopped" or (out / "error.txt").exists():
            break
        sec = int(s.get("seconds", 0))
        print(f"\r  {sec // 60:02d}:{sec % 60:02d}  나 {bar(s.get('mic_peak', 0))}  상대 {bar(s.get('system_peak', 0))} ",
              end="", flush=True)
        r, _, _ = select.select([sys.stdin], [], [], 1.0)
        if r:
            sys.stdin.readline()
            break
    print()
    for pid in recorder_pids(out):
        os.kill(pid, signal.SIGINT)
    deadline = time.time() + 15
    while not (out / "recording.json").exists() and time.time() < deadline:
        time.sleep(0.3)
    if not (out / "recording.json").exists():
        sys.exit(f"녹음기가 제대로 끝나지 않았습니다. 로그: {logf}")
    meta = json.loads((out / "recording.json").read_text())
    say(f"녹음 끝: {meta['duration'] / 60:.1f}분")
    signal.signal(signal.SIGINT, signal.default_int_handler)
    # 처리 단계는 네트워크가 막힌 샌드박스에서 다시 시작한다.
    cmd = [sys.executable, "-I", str(Path(__file__).resolve()), "process", str(out), "-l", args.lang]
    if args.keep_raw:
        cmd.append("--keep-raw")
    os.execv(sys.executable, cmd)


# ---------- 오디오 준비 ----------

def prepare_audio(src, out, keep_raw):
    """mic.caf + system.caf → stereo.wav(왼쪽 나 · 오른쪽 상대, 16 kHz). 파일 하나면 mono.wav."""
    if src.is_file():
        mono = out / "mono.wav"
        run(["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-i", str(src), "-ac", "1", "-ar", "16000", str(mono)])
        return mono, None
    meta = json.loads((src / "recording.json").read_text())
    tracks = [t for t in ("mic", "system") if (src / f"{t}.caf").exists() and meta.get(t, {}).get("seconds", 0) > 0.5]
    if not tracks:
        sys.exit("녹음된 소리가 없습니다.")
    inputs, chains = [], []
    for i, t in enumerate(tracks):
        inputs += ["-i", str(src / f"{t}.caf")]
        delay = int(round((meta[t].get("offset") or 0) * 1000))
        chains.append(f"[{i}:a]aresample=16000,pan=mono|c0=0.5*c0+0.5*c1,adelay={delay}:all=1[{t}]"
                      if t == "system" else f"[{i}:a]aresample=16000,pan=mono|c0=c0,adelay={delay}:all=1[{t}]")
    if len(tracks) == 2:
        graph = ";".join(chains) + ";[mic][system]amerge=inputs=2[st];[st]asplit[st1][st2];[st2]pan=mono|c0=0.5*c0+0.5*c1[mono]"
        stereo, mono = out / "stereo.wav", out / "mono.wav"
        run(["ffmpeg", "-nostdin", "-loglevel", "error", "-y", *inputs, "-filter_complex", graph,
             "-map", "[st1]", "-c:a", "pcm_s16le", str(stereo), "-map", "[mono]", "-c:a", "pcm_s16le", str(mono)])
    else:
        mono, stereo = out / "mono.wav", None
        run(["ffmpeg", "-nostdin", "-loglevel", "error", "-y", *inputs, "-filter_complex", chains[0],
             "-map", f"[{tracks[0]}]", "-c:a", "pcm_s16le", str(mono)])
    # 들어 볼 원본은 작게 남기고, 큰 float 원본은 지운다.
    keep = out / "audio.m4a"
    if not keep.exists():
        run(["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-i", str(stereo or mono), "-c:a", "aac", "-b:a", "64k", str(keep)])
    if not keep_raw:
        for t in tracks:
            (src / f"{t}.caf").unlink(missing_ok=True)
    return mono, stereo


# ---------- 전사 ----------

SENTENCE_END = re.compile("(?:[.!?]|。|！|？)+(?!\\d)\\s*".encode())


def split_sentences(seg):
    """whisper 한 덩어리를 문장으로 자르고, 토큰 시각으로 문장마다 시작 · 끝을 정한다.

    토큰 글자는 한 글자의 일부 바이트일 수 있어(한글 · 한자) 글자는 덩어리 원문에서 자르고,
    토큰은 바이트 위치 → 시각을 찾는 데만 쓴다.
    """
    text_b = seg["text"].encode("utf-8", "surrogateescape")
    toks, pos = [], 0
    for t in seg.get("tokens", []):
        if t["text"].startswith("[_"):
            continue
        pos += len(t["text"].encode("utf-8", "surrogateescape"))
        toks.append((pos, t["offsets"]["from"] / 1000, t["offsets"]["to"] / 1000))
    seg_start, seg_end = seg["offsets"]["from"] / 1000, seg["offsets"]["to"] / 1000
    if not toks or pos != len(text_b):
        return [{"start": seg_start, "end": seg_end, "text": text_b.decode("utf-8", "replace").strip()}]
    cuts = [m.end() for m in SENTENCE_END.finditer(text_b) if m.end() < len(text_b)] + [len(text_b)]
    out, a = [], 0
    for b in cuts:
        piece = text_b[a:b].decode("utf-8", "replace").strip()
        if piece:
            first = next(t for t in toks if t[0] > a)
            last = next(t for t in toks if t[0] >= b)
            out.append({"start": first[1], "end": max(last[2], first[1] + 0.1), "text": piece})
        a = b
    return out


def whisper_prompt(terms="", previous=""):
    """whisper 초기 프롬프트. 용어 목록 · 회의 맥락 · 앞 문장. whisper 는 프롬프트가 길면 앞쪽을 잘라내므로
    (약 220 토큰), 짧게 유지하고 맥락은 뒤쪽에 둔다."""
    glossary = ""
    if GLOSSARY.exists():
        glossary = " ".join(l.strip() for l in GLOSSARY.read_text(encoding="utf-8").splitlines() if l.strip() and not l.startswith("#"))
    terms = " ".join(terms.split())
    return " ".join(p for p in (previous[-60:], glossary[:120], terms[:160]) if p).strip()


def transcribe(mono, out, lang, use_vad=False, context="", name="whisper", terms=""):
    prefix = out / name
    # VAD 를 켜면 말이 붙은 구간에서 문장을 건너뛰는 일이 있었다(일본어 시험 2026-10-27).
    # 기본은 끄고, 무음 구간의 헛문장은 label_speakers 에서 소리 크기로 거른다.
    cmd = ["whisper-cli", "-m", str(WHISPER_MODEL), "-f", str(mono), "-l", lang, "-ojf", "-of", str(prefix), "-np",
           "-t", str(max(4, (os.cpu_count() or 8) - 2))]
    if use_vad:
        cmd += ["--vad", "-vm", str(VAD_MODEL)]
    hint = whisper_prompt(terms, context)
    if hint:
        cmd += ["--prompt", hint]
    t0 = time.time()
    run(cmd, stdout=subprocess.DEVNULL, stderr=open(out / f"{name}.log", "w"))
    raw = prefix.with_suffix(".json").read_bytes().decode("utf-8", "surrogateescape")
    data = json.loads(raw)
    segs = [p for s in data.get("transcription", []) for p in split_sentences(s) if p["text"] and plausible(p["text"])]
    detected = data.get("result", {}).get("language", lang)
    say(f"전사 끝: 문장 {len(segs)}개 · 언어 {detected} · {time.time() - t0:.0f}초")
    return segs, detected


def channel_levels(path):
    """채널마다 초당 100칸으로 RMS 를 잰다."""
    with wave.open(str(path)) as w:
        assert w.getsampwidth() == 2
        nch, hop = w.getnchannels(), w.getframerate() // 100
        levels = [[] for _ in range(nch)]
        while True:
            raw = w.readframes(hop)
            if not raw:
                break
            a = array.array("h", raw)
            for c in range(nch):
                x = a[c::nch]
                levels[c].append((sum(v * v for v in x) / max(1, len(x))) ** 0.5)
    return levels


def label_speakers(segs, audio):
    """소리 크기로 문장을 거르고, 스테레오면 말한 사람을 정한다.

    - 모든 채널이 조용한 구간의 문장은 버린다. VAD 없이 돌린 whisper 가 무음에서 지어낸 문장이다.
    - 스테레오(왼쪽 마이크 = 나, 오른쪽 시스템 오디오 = 상대)면 더 큰 쪽이 말한 사람이다.
      두 채널은 녹음 크기가 다르므로 각 채널을 그 채널의 큰 소리 기준(90번째 백분위)으로 나눈 뒤 비교한다.
      스피커로 들은 상대 소리가 마이크로 다시 들어가도(에코) 시스템 쪽이 더 크게 잡힌다.
    """
    levels = channel_levels(audio)

    def seg_level(ch, s):
        a = int(s["start"] * 100)
        part = ch[a:max(a + 1, int(s["end"] * 100))] or [0]
        return sum(part) / len(part)

    def p90(vals):
        # 바닥 300(약 -40 dBFS): 말소리가 없는 채널을 잡음 기준으로 나누면 잡음이 말소리만큼 커진다
        # (2026-10-27 실녹음: 조용한 마이크 때문에 상대 말이 "나"로 붙음).
        v = sorted(x for x in vals if x > 30) or [1]
        return max(300, v[max(0, int(len(v) * 0.9) - 1)])

    per = [[seg_level(ch, s) for s in segs] for ch in levels]
    norms = [p90(v) for v in per]
    kept = []
    for i, s in enumerate(segs):
        lv = [per[c][i] / norms[c] for c in range(len(levels))]
        if max(lv) < 0.05:
            continue
        if len(lv) == 2:
            s["speaker"] = "나" if lv[0] >= lv[1] else "상대"
        kept.append(s)
    if len(kept) < len(segs):
        say(f"  조용한 구간의 문장 {len(segs) - len(kept)}개를 버림(환각 의심)")
    return kept


# ---------- 화자 분리 (상대 쪽 여러 명) ----------

def speakers_module():
    """speakers.py(sherpa-onnx · numpy 필요)를 불러온다. .venv 밖이라 없으면 None — 그때는 '상대' 하나로 둔다."""
    if str(ROOT) not in sys.path:
        sys.path.insert(0, str(ROOT))
    try:
        import speakers
        import sherpa_onnx  # noqa: F401
        return speakers if speakers.MODEL.exists() else None
    except ImportError:
        return None


def read_channel(stereo, ch):
    import numpy as np
    with wave.open(str(stereo)) as w:
        a = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).reshape(-1, w.getnchannels())
    return a[:, ch].astype(np.float32) / 32768


def embed_others(segs, stereo, embedder, min_seconds):
    """'상대' 문장마다 시스템 오디오(오른쪽)에서 목소리 지문을 뽑는다. 짧은 문장은 None."""
    x = read_channel(stereo, 1)
    out = []
    for s in segs:
        a, b = int(s["start"] * 16000), int(s["end"] * 16000)
        out.append(embedder.embed(x[a:b]) if s.get("speaker") == "상대" and b - a >= min_seconds * 16000 else None)
    return out


def fill_short(labels, spans=None, default=0):
    """지문이 없는(짧은) 상대 문장은 시간상 더 가까운 앞 · 뒤 사람을 따른다.

    짧은 '알겠습니다.'가 앞 사람을 따라가 틀린 일이 있었다(2026-10-29 상대 3명 시험). 말 차례가 바뀌는
    자리에서는 짧은 대답이 다음 말의 첫머리인 경우가 많다.
    """
    n = len(labels)
    spans = spans or [(i, i) for i in range(n)]
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


def keep_numbers(found, previous):
    """새로 나눈 번호(found)를 이전 번호(previous)와 가장 많이 겹치는 것으로 바꾼다 — 바꿔 둔 이름이 유지되게."""
    votes = {}
    for f, p in zip(found, previous):
        votes.setdefault(f, []).append(p)
    mapping, used = {}, set()
    for f in sorted(votes, key=lambda f: -len(votes[f])):
        k = next((v for v in sorted(set(votes[f]), key=lambda v: -votes[f].count(v)) if v not in used), None)
        if k is None:
            k = max(used | set(previous) | {-1}) + 1
            while k in used:
                k += 1
        mapping[f] = k
        used.add(k)
    return [mapping[f] for f in found]


def diarize_others(segs, x, sp, embedder=None, n_speakers=None):
    """segs 안의 상대 문장을 사람별로 나눠 speaker 를 '상대N' 으로 바꾼다. 번호는 이전 번호를 이어받는다."""
    others = sorted((s for s in segs if str(s.get("speaker", "")).startswith("상대")), key=lambda s: s["start"])
    if not others:
        return 0
    previous = [int(m.group(1)) - 1 if (m := re.fullmatch(r"상대(\d+)", s["speaker"])) else 0 for s in others]
    found = sp.diarize(others, x, embedder or sp.Embedder(), n_speakers=n_speakers)
    for s, k in zip(others, keep_numbers(found, previous)):
        s["speaker"] = f"상대{k + 1}"
    return len(set(found))


def diarize_offline(segs, stereo, n_speakers=None):
    """명령줄 처리용: 상대 문장을 모두 모아 한 번에 나눈다."""
    sp = speakers_module()
    if not sp or not stereo:
        return segs
    n = diarize_others(segs, read_channel(stereo, 1), sp, n_speakers=n_speakers)
    if n:
        say(f"  상대 쪽 화자 {n}명")
    return segs


class LiveSpeakers:
    """회의 중(작업자 안)의 화자 상태: 실시간 묶기 + 끝난 뒤 다시 묶기."""

    def __init__(self, sp):
        self.sp = sp
        self.embedder = sp.Embedder()
        self.clusterer = sp.Clusterer()
        self.last = 0     # 앞 조각의 마지막 상대 번호

    def label_chunk(self, segs, stereo, offset):
        others = [s for s in segs if s.get("speaker") == "상대"]
        if not others:
            return
        embs = embed_others(others, stereo, self.embedder, self.sp.MIN_SECONDS)
        labels = [self.clusterer.assign(e, s["end"] - s["start"]) if e is not None else None for s, e in zip(others, embs)]
        # 짧은 문장: 이 조각 안에서 가까운 사람, 조각에 아무도 없으면 앞 조각의 마지막 사람
        labels = fill_short(labels, [(s["start"], s["end"]) for s in others], self.last)
        for s, k in zip(others, labels):
            s["speaker"] = f"상대{k + 1}"
        self.last = labels[-1]

    def final_labels(self, raw, segs, n_speakers=None):
        """회의가 끝난 뒤: 전체 녹음(audio.raw)으로 상대 화자를 다시 나눈다(speakers.diarize).
        번호는 실시간 번호와 가장 많이 겹치는 것을 이어받는다(회의 중에 바꾼 이름이 유지되게)."""
        import numpy as np
        x = np.fromfile(raw, dtype=np.int16).reshape(-1, 2)[:, 1].astype(np.float32) / 32768
        segs = [dict(s) for s in segs]
        diarize_others(segs, x, self.sp, self.embedder, n_speakers)
        return [{"start": s["start"], "speaker": s["speaker"]} for s in segs if str(s.get("speaker", "")).startswith("상대")]


def ts(sec):
    sec = int(sec)
    return f"{sec // 3600:d}:{sec // 60 % 60:02d}:{sec % 60:02d}" if sec >= 3600 else f"{sec // 60:02d}:{sec % 60:02d}"


def write_transcript(segs, out, title):
    lines = [f"# {title} — 전사", ""]
    prev = None
    for s in segs:
        who = s.get("speaker")
        if who and who != prev:
            lines += ["", f"**{who}** [{ts(s['start'])}]"]
            prev = who
        lines.append(f"[{ts(s['start'])}] {s['text']}" if not who else s["text"])
    (out / "transcript.md").write_text("\n".join(lines).strip() + "\n", encoding="utf-8")
    (out / "transcript.json").write_text(json.dumps(segs, ensure_ascii=False, indent=1), encoding="utf-8")


# ---------- 회의록 ----------

SYSTEM_PROMPT = """You are a meticulous meeting secretary. You write meeting minutes ONLY from the transcript given.
Rules:
- Never invent facts, names, numbers, dates or decisions that are not in the transcript. If something is unclear, write it as unclear.
- The transcript comes from automatic speech recognition, so it has errors. Fix obvious recognition errors silently, but keep proper nouns as heard if unsure (mark with "(?)").
- Speakers are labeled "{me}" (the user, recorded by microphone) and "{other}" or "{other}1", "{other}2"… (other participants heard through the computer, told apart by voice). Some labels may be replaced by real names. Use the labels as they are.
- Write dates and deadlines exactly as spoken ("금요일까지" stays "금요일", not "이번 주 금요일"). Do not resolve them to calendar dates.
- Be concise and concrete. Prefer short bullet points. Keep important numbers and dates.
- Output GitHub-flavored Markdown only, no preamble."""

TEMPLATE = {
    "ko": """다음 형식으로 한국어 회의록을 써라.

# {title}
- 일시: {when}
- 길이: {length}

## 한눈에 보기
(3~5줄 요약)

## 논의 내용
(주제별 소제목과 요점. 누가 어떤 입장이었는지 필요하면 "나" / "상대" 로 표시)

## 결정 사항
(정해진 것만. 없으면 "없음")

## 할 일
| 할 일 | 담당 | 기한 |
|---|---|---|
(담당 · 기한이 언급되지 않았으면 "미정")

## 남은 질문
(답이 나지 않은 것. 없으면 "없음")""",
    "en": """Write the minutes in English in this format.

# {title}
- Date: {when}
- Length: {length}

## At a glance
(3-5 line summary)

## Discussion
(subheadings by topic with key points; mark positions with "Me" / "Other side" when useful)

## Decisions
(only what was decided; "None" if none)

## Action items
| Task | Owner | Due |
|---|---|---|
("TBD" when not stated)

## Open questions
("None" if none)""",
    "ja": """次の形式で日本語の議事録を書いてください。

# {title}
- 日時: {when}
- 長さ: {length}

## 要点
（3〜5行の要約）

## 議論の内容
（トピックごとの小見出しと要点。必要なら「自分」／「相手」で立場を示す）

## 決定事項
（決まったことのみ。なければ「なし」）

## アクションアイテム
| タスク | 担当 | 期限 |
|---|---|---|
（言及がなければ「未定」）

## 未解決の質問
（なければ「なし」）""",
}


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


class LocalLLM:
    def __init__(self, ctx):
        self.port = free_port()
        LOGS.mkdir(parents=True, exist_ok=True)
        self.log = open(LOGS / "llama-server.log", "w")
        self.proc = subprocess.Popen(
            ["llama-server", "-m", str(LLM_MODEL), "--host", "127.0.0.1", "--port", str(self.port),
             "-c", str(ctx), "-ngl", "99", "-fa", "on", "-np", "1", "--no-webui", "--jinja",
             # 생각하기 끔: 149자 전사에 생각만 1,600 토큰을 써 80초 넘게 걸렸다(2026-10-28).
             "--reasoning-budget", "0"],
            stdout=self.log, stderr=subprocess.STDOUT)
        deadline = time.time() + 300
        while True:
            if self.proc.poll() is not None:
                raise RuntimeError(f"llama-server 가 멈춤. 로그: {LOGS / 'llama-server.log'}")
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{self.port}/health", timeout=2) as r:
                    if r.status == 200:
                        break
            except OSError:
                pass
            if time.time() > deadline:
                raise RuntimeError("llama-server 가 5분 안에 준비되지 않음")
            time.sleep(1)

    def chat(self, system, user, max_tokens=4096, json_mode=False):
        payload = {
            "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
            "temperature": 0.3, "top_p": 0.95, "max_tokens": max_tokens,
        }
        if json_mode:
            payload["response_format"] = {"type": "json_object"}
        body = json.dumps(payload).encode()
        req = urllib.request.Request(f"http://127.0.0.1:{self.port}/v1/chat/completions", body,
                                     {"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=3600) as r:
            j = json.loads(r.read())
        msg = j["choices"][0]["message"]
        return (msg.get("content") or "").strip(), j.get("usage", {})

    def close(self):
        self.proc.terminate()
        try:
            self.proc.wait(10)
        except subprocess.TimeoutExpired:
            self.proc.kill()


SPEAKER_LABELS = {"ko": ("나", "상대"), "en": ("Me", "Other side"), "ja": ("自分", "相手")}
MINUTES_UNIT = {"ko": "{}분", "en": "{} min", "ja": "{}分"}


def load_names(out):
    """speakers.json: 화자 번호 → 사용자가 붙인 이름. 예: {"상대1": "김부장"}"""
    try:
        return {k: v.strip() for k, v in json.loads((out / "speakers.json").read_text(encoding="utf-8")).items() if v.strip()}
    except (OSError, ValueError, AttributeError):
        return {}


def display_name(raw, lang, names):
    if raw in names:
        return names[raw]
    me, other = SPEAKER_LABELS[lang]
    if raw == "나":
        return me
    m = re.fullmatch(r"상대(\d*)", raw or "")
    if m:
        return f"{other}{m.group(1)}" if lang != "en" else f"{other} {m.group(1)}".strip()
    return raw or ""


def read_context(out):
    p = out / "context.md"
    return p.read_text(encoding="utf-8").strip() if p.exists() else ""


def transcript_text(segs, lang, names=None):
    names = names or {}
    out, prev = [], None
    for s in segs:
        who = display_name(s.get("speaker"), lang, names)
        if who != prev or not out:
            out.append(f"\n[{ts(s['start'])}] {who or ''}: {s['text']}")
            prev = who
        else:
            out[-1] += " " + s["text"]
    return "\n".join(x.strip() for x in out)


def write_minutes(out, title, when, length, lang):
    segs = json.loads((out / "transcript.json").read_text(encoding="utf-8"))
    if not segs:
        sys.exit("전사가 비어 있어 회의록을 쓰지 않습니다.")
    out_lang = lang if lang in TEMPLATE else "ko"
    text = transcript_text(segs, out_lang, load_names(out))
    me, other = SPEAKER_LABELS[out_lang]
    system = SYSTEM_PROMPT.format(me=me, other=other)
    glossary = ""
    if GLOSSARY.exists():
        glossary = "\n\n용어 · 이름 목록(철자 참고):\n" + GLOSSARY.read_text(encoding="utf-8")
    context = read_context(out)
    if context:
        glossary += ("\n\nBackground the user gave about this meeting (participants, agenda, terms). Use it to "
                     "understand the transcript and spell names correctly, but do not report it as discussion:\n"
                     "<context>\n" + context + "\n</context>")
    my_notes = (out / "notes.md").read_text(encoding="utf-8").strip() if (out / "notes.md").exists() else ""
    if my_notes:
        glossary += ("\n\nNotes the user typed during the meeting. They show what the user found important; "
                     "reflect them, but facts still come from the transcript:\n<user_notes>\n" + my_notes + "\n</user_notes>")
    fmt = TEMPLATE[out_lang].format(title=title, when=when, length=MINUTES_UNIT[out_lang].format(length))
    # 한 번에 넣기 너무 길면 나눠 요약한 뒤 합친다. 일본어는 글자당 토큰이 많아 4만 자 안팎이 한 조각이다.
    chunk_chars = 40000
    chunks = [text[i:i + chunk_chars] for i in range(0, len(text), chunk_chars)]
    say(f"회의록 쓰는 중 (로컬 모델, 글자 {len(text):,}자{f' · {len(chunks)}조각' if len(chunks) > 1 else ''})…")
    t0 = time.time()
    llm = LocalLLM(ctx=65536)
    try:
        if len(chunks) == 1:
            body = text
        else:
            notes = []
            for i, c in enumerate(chunks, 1):
                n, _ = llm.chat(system, f"This is part {i}/{len(chunks)} of a meeting transcript. "
                                f"List every topic, decision, number, date, owner and action item in detail, in {LANG_NAMES[out_lang]}."
                                f"\n\n<transcript>\n{c}\n</transcript>")
                notes.append(f"### Part {i}\n{n}")
                say(f"  조각 {i}/{len(chunks)} 끝")
            body = "\n\n".join(notes)
        md, usage = llm.chat(system, f"{fmt}{glossary}\n\n<transcript>\n{body}\n</transcript>")
    finally:
        llm.close()
    md = re.sub(r"^```(?:markdown)?\s*|\s*```$", "", md.strip())
    # 머리말의 일시 · 길이는 코드가 아는 값으로 덮는다. 모델이 "날짜는 말한 그대로" 규칙을 여기까지 적용해
    # "일시: 미정"으로 쓴 일이 있었다(2026-10-28).
    length_text = MINUTES_UNIT[out_lang].format(length)
    md = re.sub(r"(?m)^- (일시|Date|日時)\s*[:：].*$", lambda m: f"- {m.group(1)}: {when}", md, count=1)
    md = re.sub(r"(?m)^- (길이|Length|長さ)\s*[:：].*$", lambda m: f"- {m.group(1)}: {length_text}", md, count=1)
    (out / "minutes.md").write_text(md + "\n", encoding="utf-8")
    say(f"회의록 끝: {time.time() - t0:.0f}초 · 입력 {usage.get('prompt_tokens', '?')} · 출력 {usage.get('completion_tokens', '?')} 토큰")


# ---------- 상세 회의록 ----------
# 로컬 모델에 한 번에 쓰게 하면 짧게 뭉뚱그린다. 단계를 나눠 쓴다(2026-10-29, 사용자 예시 수준을 목표로):
#   ① 회의 정보(제목 · 참석자 · 프로젝트 · 목적) ② 목차(주제 · 시간대) ③ 주제마다 절 하나씩
#   ④ 핵심 요약 · 결정 · Action Items · 다음 확인 사항 · 종합 정리. 일시는 코드가 채운다.

DETAIL_HEAD = {
    "ko": dict(when="일시", who="참석자", project="프로젝트", purpose="회의 목적", summary="회의 핵심 요약",
               decisions="결정 사항 및 후속 액션", agreed="주요 합의 및 확인 사항", considering="검토 중인 사항",
               actions="Action Items",
               owner="담당", action="액션", due="목표 일정", next="다음 미팅에서 확인할 사항", overall="종합 정리"),
    "en": dict(when="Date", who="Attendees", project="Project", purpose="Purpose", summary="Key Summary",
               decisions="Decisions and Follow-ups", agreed="Agreements and Confirmations",
               considering="Under Consideration", actions="Action Items",
               owner="Owner", action="Action", due="Target", next="Questions for the Next Meeting", overall="Overall Assessment"),
    "ja": dict(when="日時", who="参加者", project="プロジェクト", purpose="会議の目的", summary="会議の要点",
               decisions="決定事項とフォローアップ", agreed="主な合意・確認事項", considering="検討中の事項",
               actions="Action Items",
               owner="担当", action="アクション", due="目標時期", next="次回確認事項", overall="総括"),
}

DETAIL_STYLE = {
    "ko": "한국어 보고서체(~다, ~했다, ~할 예정이다)로 쓴다. 고유명사 · 도구 이름 · 숫자는 원문 그대로 둔다.",
    "en": "Write in clear business English, past tense for what was said.",
    "ja": "日本語の報告書体（である調）で書く。固有名詞・ツール名・数字は原文のまま。",
}

DETAIL_SYSTEM = """You are an expert meeting secretary who writes detailed, well-structured minutes for executives.
Facts come ONLY from the transcript (plus the user's context and notes). Never invent names, numbers, dates, prices, tools or decisions.
The transcript is automatic speech recognition with errors: silently fix obvious mishearings using context; keep uncertain proper nouns with "(?)".
Clearly separate what was decided from what was only proposed, estimated or discussed. When something is not yet decided, say so explicitly.
Attribute statements to people by name when the speaker is known.
Common mistakes to avoid (they happened before):
- When a speaker compares THIS project with another game or project, never attribute the other one's genre, features or numbers to this project. Keep each project distinct.
- Only list something as agreed/decided if the participants explicitly agreed. Plans, proposals and things "being considered" are written as such (예정, 검토 중, 제안).
- Keep the direction of actions exactly as in the transcript: who sends what to whom, who reviews whose documents.
- Do not translate idioms literally (e.g. "taking a break from a project" is not "on leave from school")."""


def format_when(out, lang):
    rec = out / "recording.json"
    if not rec.exists():
        return meeting_when(out)[0]
    meta = json.loads(rec.read_text())
    d = datetime.fromisoformat(meta["started_at"].replace("Z", "+00:00")).astimezone()
    if lang == "ko":
        ampm = "오전" if d.hour < 12 else "오후"
        return f"{d.year}년 {d.month}월 {d.day}일({'월화수목금토일'[d.weekday()]}) {ampm} {d.hour % 12 or 12}:{d.minute:02d}"
    if lang == "ja":
        return f"{d.year}年{d.month}月{d.day}日({'月火水木金土日'[d.weekday()]}) {d.hour}:{d.minute:02d}"
    return d.strftime("%A, %B %-d, %Y, %-I:%M %p")


def transcript_turns(segs, lang, names):
    turns = []
    for s in segs:
        who = display_name(s.get("speaker"), lang, names)
        if turns and turns[-1]["who"] == who and s["start"] - turns[-1]["end"] < 3:
            turns[-1]["text"] += " " + s["text"]
            turns[-1]["end"] = s["end"]
        else:
            turns.append({"who": who, "start": s["start"], "end": s["end"], "text": s["text"]})
    return turns


def turns_text(turns, a=None, b=None):
    return "\n".join(f"[{ts(t['start'])}] {t['who']}: {t['text']}" for t in turns
                     if (a is None or t["end"] >= a) and (b is None or t["start"] <= b))


def parse_ts(v):
    if isinstance(v, (int, float)):
        return float(v)
    parts = [float(p) for p in re.findall(r"\d+(?:\.\d+)?", str(v))]
    sec = 0.0
    for p in parts:
        sec = sec * 60 + p
    return sec


def loads_json(text):
    m = re.search(r"\{.*\}", text, re.S)
    return json.loads(m.group(0) if m else text)


def write_minutes_detailed(out, title, lang):
    segs = json.loads((out / "transcript.json").read_text(encoding="utf-8"))
    if not segs:
        sys.exit("전사가 비어 있어 회의록을 쓰지 않습니다.")
    lang = lang if lang in DETAIL_HEAD else "ko"
    H = DETAIL_HEAD[lang]
    names = load_names(out)
    turns = transcript_turns(segs, lang, names)
    full = turns_text(turns)
    if len(full) > 150000:
        say("  전사가 매우 길어 앞 15만 자로 목차를 잡습니다.")
    context = read_context(out)
    my_notes = (out / "notes.md").read_text(encoding="utf-8").strip() if (out / "notes.md").exists() else ""
    glossary = GLOSSARY.read_text(encoding="utf-8") if GLOSSARY.exists() else ""
    speakers = sorted({t["who"] for t in turns})
    background = "\n\n".join(p for p in [
        f"Speaker labels in the transcript: {', '.join(speakers)}. '{display_name('나', lang, names)}' is the user (recorded by microphone).",
        f"<user_context>\n{context}\n</user_context>" if context else "",
        f"<user_notes>\n{my_notes}\n</user_notes>" if my_notes else "",
        f"<glossary>\n{glossary}\n</glossary>" if glossary else "",
    ] if p)
    style = DETAIL_STYLE[lang]
    out_lang = LANG_NAMES[lang]
    t0 = time.time()
    say(f"상세 회의록 쓰는 중 (로컬 모델, 전사 {len(full):,}자)…")
    llm = LocalLLM(ctx=65536)
    try:
        # ① 회의 정보
        meta_raw, _ = llm.chat(DETAIL_SYSTEM, f"""{background}

<transcript>
{full[:150000]}
</transcript>

Return JSON with these keys, all values written in {out_lang}:
- "title": a specific, descriptive title for these minutes (who × whom, what), like "【A × B】신규 X 개발 미팅 회의록"
- "attendees": one line listing attendees with affiliation/role in parentheses where known
- "project": the project this meeting is about (one line), or "" if none
- "purpose": the purpose of the meeting (one sentence)
- "note": one sentence clarifying a likely confusion (e.g. two similar projects), or "" if none""", max_tokens=800, json_mode=True)
        meta = loads_json(meta_raw)
        say(f"  ① 회의 정보 · {time.time() - t0:.0f}초")
        # ② 목차
        outline_raw, _ = llm.chat(DETAIL_SYSTEM, f"""{background}

<transcript>
{full[:150000]}
</transcript>

Plan the body sections of detailed minutes. Split the discussion into 8-14 topics in a logical order.
Keep distinct subjects in separate sections rather than merging them (e.g. game design, art/3D pipeline, team & outsourcing management,
AI tooling, schedule & milestones, game economy & monetization, IP/copyright, budget, documents to deliver & meeting cadence,
participants' other projects/activities, events & networking). Skip pure greetings. Each topic lists the time ranges where it was discussed (it may come up several times).
Return JSON: {{"sections": [{{"title": "...in {out_lang}", "ranges": [["mm:ss", "mm:ss"], ...],
"points": ["key facts to cover, in {out_lang}", ...]}}]}}""", max_tokens=3000, json_mode=True)
        sections = loads_json(outline_raw).get("sections", [])[:12]
        say(f"  ② 목차 {len(sections)}개 · {time.time() - t0:.0f}초")
        if not sections:
            raise RuntimeError("목차를 만들지 못했습니다")
        titles = "\n".join(f"{i + 2}. {s.get('title', '')}" for i, s in enumerate(sections))
        facts = (f"Meeting facts: project = {meta.get('project') or '?'}; attendees = {meta.get('attendees') or '?'}; "
                 f"purpose = {meta.get('purpose') or '?'}")
        # ③ 주제마다 절
        bodies = []
        for i, sec in enumerate(sections):
            n = i + 2
            ranges = [(parse_ts(a) - 20, parse_ts(b) + 20) for a, b in sec.get("ranges", []) if a is not None and b is not None]
            excerpt = "\n".join(turns_text(turns, a, b) for a, b in ranges) if ranges else full[:40000]
            if len(excerpt) < 200:
                excerpt = full[:40000]
            body, _ = llm.chat(DETAIL_SYSTEM, f"""{background}

{facts}

All sections of the minutes (write ONLY section {n}; do not repeat other sections' content):
{titles}

Points to cover in section {n}: {json.dumps(sec.get('points', []), ensure_ascii=False)}

<transcript_excerpt>
{excerpt[:60000]}
</transcript_excerpt>

Write section {n} in {out_lang}. {style}
Format (GitHub Markdown):
- Start with exactly "## {n}. {sec.get('title', '')}"
- Use 2-5 subsections "### {n}.1. ...", "### {n}.2. ..." etc.
- Under each: short explanatory paragraphs (who said what and why), then bullet lists for enumerations.
- Use a table when comparing items (people/roles, tools, costs, schedule phases, assets).
- Use numbered steps for processes.
- Keep every concrete number, price, period, tool and name mentioned.
- End a subsection with what is still undecided or needs confirmation, when relevant.
- Roughly 250-700 words depending on how much was said. No preamble, no closing remarks.""", max_tokens=3500)
            body = re.sub(r"^```(?:markdown)?\s*|\s*```$", "", body.strip())
            if not body.startswith("## "):
                body = f"## {n}. {sec.get('title', '')}\n\n{body}"
            bodies.append(body)
            say(f"  ③ 절 {i + 1}/{len(sections)} · {time.time() - t0:.0f}초")
        n_dec, n_next, n_all = len(sections) + 2, len(sections) + 3, len(sections) + 4
        draft = "\n\n".join(bodies)
        # ④ 요약 · 결정 · 다음 확인 · 종합
        tail, _ = llm.chat(DETAIL_SYSTEM, f"""{background}

{facts}

Below are the body sections of the minutes, already written from the transcript.

<sections>
{draft}
</sections>

Write the remaining parts in {out_lang}. {style} Output exactly these four blocks with these exact headings:

## SUMMARY
6-10 bullets. Each starts with a bold label then a colon, e.g. "- **개발 일정:** ...". Cover plan, schedule, team, production, budget, economy, IP, follow-ups as applicable.

## DECISIONS
### AGREED
A numbered list of agreements and confirmations. Only what was explicitly agreed or confirmed; mark estimates as estimates.
### CONSIDERING
A numbered list of things proposed or under consideration but not decided (omit the block if none).
### ACTIONS
A table: | {H['owner']} | {H['action']} | {H['due']} | with every follow-up action. Use "미정"/"TBD"/"未定" when no date was given.

## NEXT
Questions to confirm at the next meeting, grouped under 2-4 "### " category headings, each a bullet ending with "?".

## OVERALL
3-5 short paragraphs assessing the meeting; the last sentence in **bold** states the most important next step.""", max_tokens=4000)
    finally:
        llm.close()

    def block(name):
        m = re.search(rf"^## {name}\s*$(.*?)(?=^## [A-Z]+\s*$|\Z)", tail, re.S | re.M)
        return m.group(1).strip() if m else ""

    decisions = block("DECISIONS")
    decisions = re.sub(r"(?m)^### AGREED\s*$", f"### {n_dec}.1. {H['agreed']}", decisions)
    sub_no = iter(range(2, 5))
    decisions = re.sub(r"(?m)^### CONSIDERING.*$", lambda m: f"### {n_dec}.{next(sub_no)}. {H['considering']}", decisions)
    decisions = re.sub(r"(?m)^### ACTIONS\s*$", lambda m: f"### {n_dec}.{next(sub_no)}. {H['actions']}", decisions)
    head_title = title if title and not re.fullmatch(r"\d+월 \d+일 (오전|오후) \d+:\d+ 회의", title) else meta.get("title") or title
    head = [f"# {head_title}", "", f"**{H['when']}:** {format_when(out, lang)}  "]
    if meta.get("attendees"):
        head.append(f"**{H['who']}:** {meta['attendees']}  ")
    if meta.get("project"):
        head.append(f"**{H['project']}:** {meta['project']}  ")
    if meta.get("purpose"):
        head.append(f"**{H['purpose']}:** {meta['purpose']}")
    if meta.get("note"):
        head += ["", f"> {meta['note']}"]
    parts = ["\n".join(head), f"## 1. {H['summary']}\n\n{block('SUMMARY')}", *bodies,
             f"## {n_dec}. {H['decisions']}\n\n{decisions}",
             f"## {n_next}. {H['next']}\n\n{block('NEXT')}",
             f"## {n_all}. {H['overall']}\n\n{block('OVERALL')}"]
    md = "\n\n---\n\n".join(p.strip() for p in parts) + "\n"
    if (out / "minutes.md").exists():
        (out / "minutes.prev.md").write_text((out / "minutes.md").read_text(encoding="utf-8"), encoding="utf-8")
    (out / "minutes.md").write_text(md, encoding="utf-8")
    say(f"상세 회의록 끝: {time.time() - t0:.0f}초 · {len(md):,}자 · 절 {len(sections)}개")


# ---------- 명령 ----------

def process(args):
    reexec_in_sandbox()
    if not network_blocked():
        sys.exit("네트워크가 막히지 않았습니다. 안전을 위해 멈춥니다.")
    src = Path(args.path).expanduser().resolve()
    out = src if src.is_dir() else meeting_dir(src.stem)
    title = (out / "title.txt").read_text(encoding="utf-8").strip() if (out / "title.txt").exists() else (
        src.stem if src.is_file() else "회의")
    say(f"외부 네트워크 차단 확인. 처리 폴더: {out}")
    mono, stereo = prepare_audio(src, out, args.keep_raw)
    segs, detected = transcribe(mono, out, args.lang, args.vad, terms=read_context(out))
    segs = label_speakers(segs, stereo or mono)
    segs = diarize_offline(segs, stereo)
    write_transcript(segs, out, title)
    when, length = meeting_when(out, mono)
    (out / "language.txt").write_text(detected, encoding="utf-8")
    if not args.transcribe_only:
        write_minutes(out, title, when, length, args.out_lang or detected)
    for f in (mono, stereo):
        if f:
            f.unlink(missing_ok=True)
    say(f"\n완료\n  회의록: {out / 'minutes.md'}\n  전사:   {out / 'transcript.md'}\n  녹음:   {out / 'audio.m4a'}")


def meeting_when(out, wav=None):
    rec = out / "recording.json"
    if rec.exists():
        meta = json.loads(rec.read_text())
        start = datetime.fromisoformat(meta["started_at"].replace("Z", "+00:00")).astimezone()
        return start.strftime("%Y-%m-%d %H:%M"), max(1, round(meta["duration"] / 60))
    secs = 0
    if wav and Path(wav).exists():
        with wave.open(str(wav)) as w:
            secs = w.getnframes() / w.getframerate()
    elif (out / "transcript.json").exists():
        segs = json.loads((out / "transcript.json").read_text(encoding="utf-8"))
        secs = segs[-1]["end"] if segs else 0
    return datetime.now().strftime("%Y-%m-%d %H:%M"), max(1, round(secs / 60))


def notes(args):
    reexec_in_sandbox()
    if not network_blocked():
        sys.exit("네트워크가 막히지 않았습니다. 안전을 위해 멈춥니다.")
    out = Path(args.path).expanduser().resolve()
    title = (out / "title.txt").read_text(encoding="utf-8").strip() if (out / "title.txt").exists() else out.name
    detected = (out / "language.txt").read_text().strip() if (out / "language.txt").exists() else "ko"
    lang = args.out_lang or detected
    if args.style == "detailed":
        write_minutes_detailed(out, title, lang)
    else:
        when, length = meeting_when(out)
        write_minutes(out, title, when, length, lang)
    say(f"회의록: {out / 'minutes.md'}")


JUNK = re.compile(r"(.)\1{4,}|(..)\2{3,}")
LETTER = re.compile(r"[A-Za-z0-9가-힣ぁ-んァ-ヶ一-龥]")


def plausible(text, seg=None):
    """무음 · 잡음에서 whisper 가 지어낸 문장을 거른다(2026-10-28 실녹음: '롤롤롤롤', 'ᅠᅠᅠᅡ')."""
    if not LETTER.search(text) or JUNK.search(text.replace(" ", "")):
        return False
    if seg is not None and (seg.get("no_speech_prob", 0) > 0.6 or seg.get("avg_logprob", 0) < -1.0):
        return False
    return True


def server_sentences(seg):
    """whisper-server verbose_json 의 한 덩어리를 단어 시각으로 문장마다 자른다."""
    words = [w for w in seg.get("words", []) if w.get("word", "").strip() and not w["word"].startswith("[_")]
    if not words:
        return [{"start": seg["start"], "end": seg["end"], "text": seg["text"].strip()}]
    out, cur = [], []
    for w in words:
        cur.append(w)
        if re.search(r"(?:[.!?。！？])$", w["word"].strip()):
            out.append(cur)
            cur = []
    if cur:
        out.append(cur)
    return [{"start": c[0]["start"], "end": max(c[-1]["end"], c[0]["start"] + 0.1),
             "text": "".join(w["word"] for w in c).strip()} for c in out]


class WhisperServer:
    """모델을 한 번만 읽고 계속 켜 두는 whisper-server(localhost). 샌드박스 안에서만 띄운다."""

    def __init__(self):
        self.port = free_port()
        LOGS.mkdir(parents=True, exist_ok=True)
        self.log = open(LOGS / "whisper-server.log", "w")
        self.proc = subprocess.Popen(
            ["whisper-server", "-m", str(WHISPER_MODEL), "--host", "127.0.0.1", "--port", str(self.port),
             "-t", str(max(4, (os.cpu_count() or 8) - 2))],
            stdout=self.log, stderr=subprocess.STDOUT)
        deadline = time.time() + 60
        while True:
            if self.proc.poll() is not None:
                raise RuntimeError("whisper-server 가 멈춤")
            try:
                urllib.request.urlopen(f"http://127.0.0.1:{self.port}/", timeout=1)
                break
            except urllib.error.HTTPError:
                break
            except OSError:
                if time.time() > deadline:
                    raise RuntimeError("whisper-server 가 준비되지 않음")
                time.sleep(0.2)

    def transcribe(self, wav, lang, prompt):
        boundary = f"----lm{time.time_ns()}"
        fields = {"language": lang, "response_format": "verbose_json", "temperature": "0",
                  "temperature_inc": "0.2", "prompt": prompt}
        body = b""
        for k, v in fields.items():
            body += f"--{boundary}\r\nContent-Disposition: form-data; name=\"{k}\"\r\n\r\n{v}\r\n".encode()
        body += (f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.wav\"\r\n"
                 f"Content-Type: audio/wav\r\n\r\n").encode() + Path(wav).read_bytes() + f"\r\n--{boundary}--\r\n".encode()
        req = urllib.request.Request(f"http://127.0.0.1:{self.port}/inference", body,
                                     {"Content-Type": f"multipart/form-data; boundary={boundary}"})
        with urllib.request.urlopen(req, timeout=300) as r:
            return json.loads(r.read())

    def close(self):
        self.proc.terminate()
        try:
            self.proc.wait(5)
        except subprocess.TimeoutExpired:
            self.proc.kill()


def worker(args):
    """앱이 회의 동안 켜 두는 전사 작업자. stdin 한 줄(JSON 요청) → stdout 한 줄(JSON 결과).

    조각 요청: {"wav": 스테레오 16 kHz 조각, "offset": 초, "lang": "auto", "context": "앞 문장",
               "meeting": 회의 폴더, "terms": 회의 맥락}
    화자 정리: {"cmd": "speakers", "meeting": 회의 폴더, "raw": audio.raw, "segments": [{start, end, speaker}]}
              → {"labels": [{"start", "speaker"}]}
    stdin 이 닫히면(앱이 끝나면) whisper-server 와 함께 끝난다.
    """
    reexec_in_sandbox()
    if not network_blocked():
        sys.exit("네트워크가 막히지 않았습니다. 안전을 위해 멈춥니다.")
    t0 = time.time()
    server = WhisperServer()
    sp = speakers_module()
    live = {}   # 회의 폴더 → LiveSpeakers
    say(f"전사 작업자 준비: {time.time() - t0:.1f}초 · 화자 분리 {'켬' if sp else '끔(.venv 없음)'}")
    print(json.dumps({"ready": True, "speakers": bool(sp)}), flush=True)
    try:
        for line in sys.stdin:
            if not line.strip():
                continue
            try:
                req = json.loads(line)
                meeting = req.get("meeting", "")
                if req.get("cmd") == "speakers":
                    if meeting not in live and sp:
                        live[meeting] = LiveSpeakers(sp)
                    labels = live[meeting].final_labels(req["raw"], req.get("segments", []), req.get("n_speakers")) if sp else []
                    say(f"화자 정리: 상대 문장 {len(labels)}개 · {len({l['speaker'] for l in labels})}명")
                    print(json.dumps({"labels": labels}, ensure_ascii=False), flush=True)
                    continue
                stereo = Path(req["wav"])
                mono = stereo.with_name(stereo.stem + "-mono.wav")
                t1 = time.time()
                to_mono(stereo, mono)
                res = server.transcribe(mono, req.get("lang", "auto"), whisper_prompt(req.get("terms", ""), req.get("context", "")))
                mono.unlink(missing_ok=True)
                segs = [p for s in res.get("segments", []) if plausible(s["text"], s)
                        for p in server_sentences(s) if p["text"] and plausible(p["text"])]
                segs = label_speakers(segs, stereo) if segs else []
                off = float(req.get("offset", 0))
                if sp and segs:
                    if meeting not in live:
                        live[meeting] = LiveSpeakers(sp)
                    live[meeting].label_chunk(segs, stereo, off)
                for s in segs:
                    s["start"] = round(s["start"] + off, 2)
                    s["end"] = round(s["end"] + off, 2)
                lang = res.get("detected_language") or res.get("language") or ""
                lang = {"korean": "ko", "english": "en", "japanese": "ja"}.get(lang.lower(), lang)
                say(f"조각 전사: {len(segs)}문장 · {lang} · {time.time() - t1:.1f}초")
                print(json.dumps({"language": lang if segs else None, "segments": segs}, ensure_ascii=False), flush=True)
            except Exception as e:  # 조각 하나가 실패해도 작업자는 산다
                say(f"조각 실패: {e!r}")
                print(json.dumps({"error": repr(e), "segments": []}), flush=True)
    finally:
        server.close()


def chunk(args):
    """스테레오 16 kHz 조각 하나를 전사해 문장 JSON 을 stdout 으로 낸다(명령줄 시험용. 앱은 worker 를 쓴다)."""
    reexec_in_sandbox()
    if not network_blocked():
        sys.exit("네트워크가 막히지 않았습니다. 안전을 위해 멈춥니다.")
    stereo = Path(args.wav).resolve()
    work = stereo.parent
    mono = work / f"{stereo.stem}-mono.wav"
    to_mono(stereo, mono)
    try:
        segs, detected = transcribe(mono, work, args.lang, context=args.context, name=stereo.stem)
        segs = label_speakers(segs, stereo) if segs else []
    finally:
        mono.unlink(missing_ok=True)
        for ext in (".json", ".log"):
            (work / f"{stereo.stem}{ext}").unlink(missing_ok=True)
    for s in segs:
        s["start"] = round(s["start"] + args.offset, 2)
        s["end"] = round(s["end"] + args.offset, 2)
    print(json.dumps({"language": detected, "segments": segs}, ensure_ascii=False), flush=True)


def respeak(args):
    """이미 끝난 회의의 상대 화자를 다시 나눈다(audio.m4a 의 오른쪽 = 상대). 화자 분리 전에 녹음한 회의용."""
    reexec_in_sandbox()
    out = Path(args.path).resolve()
    sp = speakers_module()
    if not sp:
        sys.exit("화자 분리를 쓸 수 없습니다(.venv 의 sherpa-onnx · numpy 확인).")
    audio = out / "audio.m4a"
    if not audio.exists():
        sys.exit("audio.m4a 가 없습니다.")
    stereo = out / ".respeak.wav"
    afconvert(audio, stereo, "-f", "WAVE", "-d", "LEI16@16000", "-c", "2")
    try:
        segs = json.loads((out / "transcript.json").read_text(encoding="utf-8"))
        # 상대 이름을 붙여 둔 적이 없으면 이전 번호는 버린다(잘못 나뉜 번호를 이어받지 않게).
        if not any(k.startswith("상대") for k in load_names(out)):
            for s in segs:
                if str(s.get("speaker", "")).startswith("상대"):
                    s["speaker"] = "상대"
        segs = diarize_offline(segs, stereo, args.count or None)
    finally:
        stereo.unlink(missing_ok=True)
    (out / "transcript.json").write_text(json.dumps(segs, ensure_ascii=False, indent=1), encoding="utf-8")
    title = (out / "title.txt").read_text(encoding="utf-8").strip() if (out / "title.txt").exists() else out.name
    write_transcript(segs, out, title)
    counts = {}
    for s in segs:
        counts[s.get("speaker")] = counts.get(s.get("speaker"), 0) + 1
    print(json.dumps(counts, ensure_ascii=False), flush=True)


def finalize(args):
    """앱 녹음을 마무리한다. audio.raw(16 kHz 스테레오 s16le) → audio.m4a."""
    reexec_in_sandbox()
    out = Path(args.path).resolve()
    raw = out / "audio.raw"
    if raw.exists() and raw.stat().st_size > 0:
        wav = out / ".audio.wav"
        raw_to_wav(raw, wav)
        afconvert(wav, out / "audio.m4a", "-f", "m4af", "-d", "aac", "-b", "64000")
        wav.unlink()
        raw.unlink()
    say(f"녹음 저장: {out / 'audio.m4a'}")


def check(args):
    reexec_in_sandbox()
    ok = True
    blocked = network_blocked()
    say(f"{'OK ' if blocked else 'FAIL'} 외부 네트워크 차단 (1.1.1.1:443 연결 시도 → {'막힘' if blocked else '연결됨'})")
    ok &= blocked
    for name, p in [("전사 모델", WHISPER_MODEL), ("VAD 모델", VAD_MODEL), ("회의록 모델", LLM_MODEL), ("녹음기", RECORDER_APP)]:
        exists = p.exists()
        say(f"{'OK ' if exists else 'FAIL'} {name}: {p}")
        ok &= exists
    for tool in ["ffmpeg", "whisper-cli", "llama-server"]:
        found = shutil.which(tool)
        say(f"{'OK ' if found else 'FAIL'} {tool}: {found}")
        ok &= bool(found)
    sys.exit(0 if ok else 1)


def main():
    p = argparse.ArgumentParser(prog="minutes", description="로컬 전용 회의 녹음 · 전사 · 회의록")
    sub = p.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("record", help="녹음 후 전사 · 회의록")
    r.add_argument("-t", "--title", default="")
    r.add_argument("-l", "--lang", default="auto", help="말하는 언어: auto · ko · en · ja")
    r.add_argument("--keep-raw", action="store_true", help="큰 원본(caf)도 남김")
    r.set_defaults(fn=record)
    pr = sub.add_parser("process", help="녹음 폴더나 오디오 파일 처리")
    pr.add_argument("path")
    pr.add_argument("-l", "--lang", default="auto")
    pr.add_argument("-o", "--out-lang", default="", help="회의록 언어: ko · en · ja (기본: 회의 언어)")
    pr.add_argument("--keep-raw", action="store_true")
    pr.add_argument("--transcribe-only", action="store_true", help="전사만 하고 회의록은 쓰지 않음")
    pr.add_argument("--vad", action="store_true", help="whisper VAD 사용(빠르지만 문장을 건너뛸 수 있음)")
    pr.set_defaults(fn=process)
    n = sub.add_parser("notes", help="회의록만 다시 쓰기")
    n.add_argument("path")
    n.add_argument("-o", "--out-lang", default="")
    n.add_argument("-s", "--style", choices=["detailed", "brief"], default="detailed",
                   help="detailed = 주제별 절 · 표 · Action Items(몇 분 걸림), brief = 한 장 요약")
    n.set_defaults(fn=notes)
    ch = sub.add_parser("chunk", help="(앱용) 스테레오 조각 하나 전사 → JSON")
    ch.add_argument("wav")
    ch.add_argument("--offset", type=float, default=0.0)
    ch.add_argument("-l", "--lang", default="auto")
    ch.add_argument("--context", default="")
    ch.set_defaults(fn=chunk)
    wk = sub.add_parser("worker", help="(앱용) 상주 전사 작업자")
    wk.set_defaults(fn=worker)
    rs = sub.add_parser("respeak", help="끝난 회의의 상대 화자를 다시 나누기")
    rs.add_argument("path")
    rs.add_argument("-n", "--count", type=int, default=0, help="상대 인원(모르면 0 = 자동)")
    rs.set_defaults(fn=respeak)
    fz = sub.add_parser("finalize", help="(앱용) 녹음 마무리")
    fz.add_argument("path")
    fz.set_defaults(fn=finalize)
    c = sub.add_parser("check", help="점검")
    c.set_defaults(fn=check)
    a = p.parse_args()
    if a.cmd == "record":
        a.out_lang = ""
        a.transcribe_only = False
        a.vad = False
    a.fn(a)


if __name__ == "__main__":
    main()

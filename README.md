# LocalMinutes

맥 안에서만 도는 회의 녹음 · 전사 · 회의록 앱. 한국어 · 영어 · 일본어.

- **녹음**: 내 마이크("나")와 컴퓨터 소리(Zoom · Meet · Teams 의 상대방)를 따로 녹음한다.
- **실시간 전사**: whisper large-v3-turbo(Metal GPU). 말이 끊길 때마다 2~3초 뒤 화면에 쌓인다.
- **화자 분리**: 나 · 상대1 · 상대2 … 로 나누고, 이름을 바꿀 수 있다.
- **회의록**: Gemma 4 26B-A4B 가 상세(주제별 절 · 표 · 결정 사항 · Action Items) 또는 간단 회의록을 쓴다.
  회의 언어와 다른 언어로 쓸 수 있다(영어 회의 → 한국어 회의록).
- **노트**: 회의마다 메모 · 맥락 · 회의록 칸, 폴더 · 이름 바꾸기, 전사 전체 복사.

## 개인정보: 무엇이 맥 밖으로 나가나

**회의 녹음 · 전사 · 메모 · 회의록은 맥 밖으로 나가지 않는다.** 녹음 뒤의 모든 처리(전사 · 화자 분리 · 회의록)는
macOS 샌드박스 안에서 돌고, 샌드박스는 이 맥 자신(localhost)을 뺀 모든 네트워크를 막는다. 처리를 시작할 때마다
바깥 연결이 실제로 막혔는지 시험하고, 안 막혔으면 멈춘다.

앱이 인터넷을 쓰는 곳은 둘뿐이다.

| 언제 | 어디로 | 보내는 것 |
|---|---|---|
| 처음 설정 | Hugging Face · GitHub(모델 원본) | 파일 요청뿐 |
| 업데이트 확인(6시간에 한 번, 메뉴에서 끌 수 있음) | GitHub API(이 저장소의 최신 릴리스) | 요청뿐 |

데이터는 `~/Library/Application Support/LocalMinutes` 에 있다(iCloud 로 동기화되는 문서 폴더가 아님). 메뉴 → 데이터 폴더 열기.

## 설치 (받는 사람)

필요: **Apple Silicon 맥(M1 이후) · macOS 15 이상 · 메모리 32 GB 이상 · 디스크 약 20 GB**

1. [Releases](https://github.com/anchored-kr/local-minutes/releases/latest) 에서 `LocalMinutes-버전.zip` 을 받아 연다.
2. 나온 **LocalMinutes** 를 **응용 프로그램** 폴더로 옮긴다(그래야 업데이트가 된다).
3. 더블클릭 → "확인되지 않은 개발자" 경고가 뜨면 **완료**를 누르고,
   **시스템 설정 → 개인정보 보호 및 보안** 맨 아래 "LocalMinutes 이(가) 차단되었습니다" 옆 **그래도 열기** → 암호.
   (Apple 개발자 인증을 받지 않은 앱이라 처음 한 번만 필요하다. 업데이트 때는 다시 묻지 않는다.)
4. 처음 화면에서 **모델 내려받기**(약 17.5 GB). 끊겨도 다시 누르면 이어받는다. 받은 파일은 원본 해시(SHA-256)로 확인한다.
5. **회의 시작**을 처음 누르면 **마이크**, **화면 및 시스템 오디오 녹음** 권한을 묻는다. 허용하고,
   시스템 설정에서 LocalMinutes 를 켠 뒤 앱을 **⌘Q 로 끄고 다시 연다**.

## 쓰는 법

1. **새 회의**(⌘N). **맥락** 탭에 참석자 이름 · 회사 · 프로젝트 · 헷갈릴 만한 다른 이름 · 전문 용어를 짧게 적는다.
   전사(이름 · 용어 인식)와 회의록(머리말 · 구분)이 정확해진다. 회의 중에 고쳐도 다음 문장부터 반영된다.
2. **회의 시작**(⌘↩). 오른쪽에 실시간 전사. 가운데 **메모**에 자유롭게 적으면 회의록이 참고한다.
3. **회의 끝** → 남은 전사 · 화자 정리 → 회의록(상세: 30분 회의에 약 5~10분, 간단: 약 1분).
4. **화자**: 전사 위 화자 단추를 눌러 이름을 바꾼다. 한 사람이 두 번호로 나뉘면 같은 이름을 붙인다.
   상대 인원을 알면 '화자' 메뉴에서 정해 두면 정확하다. 지난 회의는 '화자 다시 나누기'.
5. **전체 복사**: 전사 위 '전체 복사'(제목 · 맥락 · `[시각] 이름: 문장`), 회의록 탭 '복사'.
6. **목록**: ⇧⌘N 새 폴더. 회의를 끌어 폴더 이름 · 폴더 안 회의 위에 놓으면 넣고, '폴더 밖' 위에 놓으면 뺀다.

**결과는 한 번 읽고 고친다.** 드문 받아쓰기 오류, 가볍게 오간 말을 합의로 올리는 실수, 짧게 지나간 곁가지 주제 누락이
있을 수 있다. 회의록 탭에서 바로 고칠 수 있다.

## 업데이트

앱이 6시간에 한 번 새 버전을 확인해 알려 준다(메뉴 → 업데이트 확인… 으로 바로 확인). **지금 업데이트**를 누르면
받기 → SHA-256 확인 → 받은 앱이 지금 앱과 **같은 인증서로 서명**됐는지 확인 → 앱을 바꿔 끼우고 다시 연다.
같은 인증서라 마이크 · 화면 녹음 권한은 그대로 유지된다. 녹음 · 회의록 작업 중에는 업데이트하지 않는다.

---

## 만드는 사람용

### 구조

```
app/               Swift 앱(녹음 엔진 Capture · 목록 · 화면 · 첫 설정 Setup · 업데이트 Updater) · Info.plist · 아이콘
minutes.py         엔진: 샌드박스 · 전사 작업자(whisper-server) · 화자 · 회의록(llama-server) · 명령줄
speakers.py        화자 분리(sherpa-onnx · 3D-Speaker CAM++)
scripts/package.sh 배포용 앱(dist/LocalMinutes.app): 앱 + engine(코드 · whisper/llama + 라이브러리 · 독립형 Python)
scripts/release.sh 버전 올리기 → package → zip · SHA-256 → git 태그 → GitHub 릴리스
app/build.sh       개발: package 후 ~/Applications 에 설치
recorder/          명령줄 녹음기(개발용 minutes record)
tests/             가짜 회의(macOS 음성) · 채점 · 작업자 시험 · 화자 기준값 시험
```

### 빌드 · 릴리스 (만드는 맥)

필요: Command Line Tools · Homebrew `whisper-cpp` `llama.cpp` · `uv`(독립형 cpython 3.14: `uv python install 3.14`)
· 로그인 키체인의 자체 서명 인증서 **LocalMinutes Signing**.

```bash
app/build.sh                                  # 이 맥에 설치해 써 보기
scripts/release.sh 1.0.1 "고친 것" "더한 것"     # 새 버전 공개 → 받는 사람 앱이 업데이트
```

**인증서를 잃으면 안 된다.** 받는 사람 앱은 같은 인증서로 서명된 업데이트만 설치하고, macOS 권한도 이 인증서에 묶인다.
키체인 접근에서 "LocalMinutes Signing" 을 개인 키와 함께 내보내(.p12) 안전한 곳에 보관한다. 저장소에는 올리지 않는다.

### 명령줄 (개발 폴더)

```bash
./minutes check                       # 네트워크 차단 · 모델 · 도구 점검
./minutes process <오디오 파일 또는 회의 폴더> [-l ko|en|ja]
./minutes notes <회의 폴더> [-s detailed|brief] [-o ko|en|ja]
./minutes respeak <회의 폴더> [-n 상대 인원]
```

데이터 위치는 앱과 같다(`LOCAL_MINUTES_HOME` 로 바꿀 수 있음).

### 설계 메모

- **전사**: 녹음을 말이 끊긴 곳(4~15초)에서 잘라, 모델을 한 번만 읽어 켜 두는 whisper-server 에 넘긴다. whisper VAD 는
  말이 붙은 구간의 문장을 건너뛰어 끄고, 무음 · 잡음의 헛문장은 소리 크기 · 반복 글자 · whisper 신뢰도로 거른다.
- **나 / 상대**: 마이크(왼쪽)와 컴퓨터 소리(오른쪽) 중 큰 쪽. 채널마다 큰 소리 기준(바닥 약 -40 dBFS)으로 맞춘 뒤 비교.
- **상대 여럿**: 1.5초 이상 문장마다 목소리 지문 → 평균 연결 묶기(코사인 0.45) → 상대 전체 말의 5%(최소 5초)도 안 되는
  묶음은 합침 → 짧은 문장은 시간상 가까운 사람. whisper 가 문장 사이 쉼을 앞 문장에 붙여 사람이 바뀌어도 간격이 0초라
  "이어진 말 묶기"는 쓰지 않는다. 기준값은 실제 회의(상대 2명)와 합성 음성 회의(상대 3명)로 정했다(`tests/speaker_calibrate.py`).
- **상세 회의록**: 한 번에 쓰게 하면 짧게 뭉뚱그려, ① 회의 정보 ② 목차(8~14개 · 시간대) ③ 절마다 해당 전사 구간만 보고
  ④ 요약 · 합의 · 검토 중 · Action Items · 다음 확인 · 종합 순서로 쓴다. 일시는 코드가 채운다. 다른 프로젝트와 비교한 말을
  이 프로젝트 특징으로 옮기지 말 것 · 제안을 합의로 쓰지 말 것 · 검토 방향을 뒤집지 말 것을 규칙으로 준다.
- **샌드박스 규칙**: `(allow network* (local ip "localhost:*"))` 는 바깥 연결까지 열어 버린다. bind · inbound · outbound 를 따로 건다.

### 모델 출처

| 모델 | 출처 | 라이선스 |
|---|---|---|
| ggml-large-v3-turbo-q5_0.bin | huggingface.co/ggerganov/whisper.cpp | MIT |
| 3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx | github.com/k2-fsa/sherpa-onnx (speaker-recongition-models) | Apache 2.0 |
| gemma-4-26B-A4B-it-UD-Q4_K_M.gguf | huggingface.co/unsloth/gemma-4-26B-A4B-it-GGUF | Apache 2.0 |

앱에 담는 것: whisper.cpp · llama.cpp · ggml(MIT), Python(PSF), sherpa-onnx · onnxruntime(Apache 2.0 · MIT), numpy(BSD).

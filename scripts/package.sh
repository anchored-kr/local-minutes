#!/bin/zsh
# 배포용 LocalMinutes.app 을 dist/ 에 만든다. 앱 하나에 엔진(minutes.py · speakers.py · whisper-server ·
# llama-server · 독립형 Python + sherpa-onnx · numpy)을 담아 받는 맥에 Homebrew · Python 이 없어도 돈다.
# 모델(약 18 GB)은 담지 않는다 — 앱이 첫 실행 때 원본에서 받는다(app/Setup.swift).
#
# 필요(만드는 맥): Command Line Tools · Homebrew whisper-cpp · llama.cpp · uv(cpython 3.14 standalone)
# 서명: 로그인 키체인의 "LocalMinutes Signing"(없으면 임시 서명 — 그러면 업데이트 확인이 실패한다).
set -euo pipefail
setopt null_glob
root=${0:A:h:h}
dist="$root/dist"
app="$dist/LocalMinutes.app"
engine="$app/Contents/Resources/engine"
sign_id="LocalMinutes Signing"
security find-certificate -c "$sign_id" >/dev/null 2>&1 || { echo "경고: $sign_id 인증서 없음 → 임시 서명"; sign_id="-"; }

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$engine/bin"
cp "$root/app/Info.plist" "$app/Contents/Info.plist"
cp "$root/app/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"

# 1. 앱(Swift). Command Line Tools 의 모듈 중복 버그(SwiftBridging)는 빈 파일로 덮어 우회한다.
overlay_args=()
dup=/Library/Developer/CommandLineTools/usr/include/swift/bridging.modulemap
if [[ -f $dup ]]; then
  : > "$dist/empty.modulemap"
  print -r -- "{ \"version\": 0, \"case-sensitive\": \"false\", \"roots\": [ { \"type\": \"file\", \"name\": \"$dup\", \"external-contents\": \"$dist/empty.modulemap\" } ] }" > "$dist/vfs-overlay.yaml"
  overlay_args=(-vfsoverlay "$dist/vfs-overlay.yaml" -Xcc -ivfsoverlay -Xcc "$dist/vfs-overlay.yaml")
fi
swiftc -O -swift-version 5 -parse-as-library "${overlay_args[@]}" -target arm64-apple-macos15.0 \
  -framework SwiftUI -framework AppKit -framework ScreenCaptureKit -framework AVFoundation -framework CoreMedia \
  -o "$app/Contents/MacOS/LocalMinutes" \
  "$root/app/Capture.swift" "$root/app/Model.swift" "$root/app/Views.swift" "$root/app/Setup.swift" "$root/app/Updater.swift" \
  2> >(grep -v "warning:" >&2 || true)

# 2. 엔진 코드
cp "$root/minutes.py" "$root/speakers.py" "$engine/"

# 3. whisper-server · llama-server + ggml 백엔드(.so, 실행 파일 옆에서 찾는다) + 라이브러리
cp -L /opt/homebrew/bin/whisper-server /opt/homebrew/bin/llama-server "$engine/bin/"
cp /opt/homebrew/opt/ggml/libexec/*.so "$engine/bin/"
python3 -I "$root/scripts/bundle_dylibs.py" "$engine"

# 4. 독립형 Python(python-build-standalone) + 화자 분리 패키지
py_src=$(uv python find --managed-python 3.14)
py_home=${py_src:A:h:h}
ditto "$py_home" "$engine/python"
rm -rf "$engine/python/include" "$engine/python/share" "$engine/python/lib/tcl"* "$engine/python/lib/tk"* "$engine/python/lib/itcl"* \
       "$engine/python/lib/python3.14/"{test,idlelib,tkinter,turtledemo,ensurepip,lib2to3} \
       "$engine/python/lib/python3.14/config-"*
rm -f "$engine/python/lib/python3.14/EXTERNALLY-MANAGED"
uv pip install --quiet --offline --python "$engine/python/bin/python3" "sherpa-onnx==2.0.1" "numpy==2.5.4"
# 필요 없는 것 빼기(pip · 테스트), 만든 맥의 경로가 박힌 sysconfig 를 일반 경로로
# 보조 스크립트(만든 맥의 경로가 박힘)와 그 링크를 뺀다 — 앱은 python3 만 쓴다. 깨진 링크가 남으면 서명 검증이 실패한다.
find "$engine/python/bin" -mindepth 1 ! -name python ! -name python3 ! -name python3.14 -delete
rm -rf "$engine/python/lib/python3.14/site-packages/"pip* \
       "$engine/python/lib/python3.14/site-packages/numpy/"{tests,*/tests,_core/tests}
sed -i '' "s#${py_home}#/LocalMinutes/engine/python#g" "$engine/python/lib/python3.14/"_sysconfigdata_*.py
find "$engine" -name __pycache__ -type d -prune -exec rm -rf {} +
if grep -rIl "$HOME" "$engine" >/dev/null 2>&1; then
  echo "경고: 엔진에 만든 맥의 경로가 남음:"; grep -rIl "$HOME" "$engine" | head
fi

# 5. 서명: 안쪽 실행 코드부터 하나씩, 마지막에 앱
n=0
while IFS= read -r -d '' f; do
  if file -b "$f" | grep -q "Mach-O"; then
    codesign --force --sign "$sign_id" --timestamp=none "$f" 2>/dev/null
    n=$((n + 1))
  fi
done < <(find "$engine" -type f \( -perm -u+x -o -name "*.so" -o -name "*.dylib" \) -print0)
codesign --force --sign "$sign_id" --timestamp=none "$app"
codesign --verify --deep --strict "$app"
echo "서명: 실행 코드 $n개 + 앱 ($sign_id)"
du -sh "$app"
echo "built $app"

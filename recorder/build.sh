#!/bin/zsh
# 녹음기 .app 을 만든다. 다시 빌드하면 서명이 바뀌어 권한을 다시 받아야 할 수 있다.
set -euo pipefail
here=${0:A:h}
app="$here/LocalMinutesRecorder.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$here/Info.plist" "$app/Contents/Info.plist"
# Command Line Tools 의 모듈 중복 버그(SwiftBridging) 우회: 중복 파일을 빈 파일로 덮는 overlay 를 그때그때 만든다.
dup=/Library/Developer/CommandLineTools/usr/include/swift/bridging.modulemap
: > "$here/empty.modulemap"
print -r -- "{ \"version\": 0, \"case-sensitive\": \"false\", \"roots\": [ { \"type\": \"file\", \"name\": \"$dup\", \"external-contents\": \"$here/empty.modulemap\" } ] }" > "$here/vfs-overlay.yaml"
swiftc -O -swift-version 5 -vfsoverlay "$here/vfs-overlay.yaml" -Xcc -ivfsoverlay -Xcc "$here/vfs-overlay.yaml" -target arm64-apple-macos15.0 \
  -framework ScreenCaptureKit -framework AVFoundation -framework CoreMedia \
  -o "$app/Contents/MacOS/LocalMinutesRecorder" "$here/main.swift"
# 고정 서명: 로그인 키체인의 "LocalMinutes Signing" 인증서(2026-10-28 생성). 서명 요건이
# "식별자 + 이 인증서"로 고정돼 다시 빌드해도 화면 · 마이크 권한이 유지된다. 없으면 임시 서명.
if security find-certificate -c "LocalMinutes Signing" >/dev/null 2>&1; then
  codesign --force --sign "LocalMinutes Signing" "$app"
else
  echo "경고: LocalMinutes Signing 인증서가 없어 임시 서명합니다(다시 빌드하면 권한을 다시 켜야 함)"
  codesign --force --sign - "$app"
fi
echo "built $app"

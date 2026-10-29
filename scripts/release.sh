#!/bin/zsh
# 새 버전을 만들어 GitHub 릴리스로 올린다. 받는 사람의 앱은 이 릴리스를 보고 스스로 업데이트한다.
#
#   scripts/release.sh 1.0.1 "고친 것 한 줄" ["고친 것 두 줄" …]
#
# 1) app/Info.plist 버전 → 2) scripts/package.sh(같은 인증서로 서명) → 3) zip · SHA-256
# 4) git 커밋 · 태그 · push → 5) gh release create (zip · .sha256 첨부, 노트 = 넘긴 줄들)
# 인증서 "LocalMinutes Signing" 이 없으면 멈춘다 — 다른 인증서로 서명하면 받는 사람 앱이 업데이트를 거부하고
# 마이크 · 화면 녹음 권한도 다시 받아야 한다.
set -euo pipefail
root=${0:A:h:h}
repo="anchored-kr/local-minutes"
version=${1:?버전을 주세요. 예: scripts/release.sh 1.0.1 "고친 것"}
shift
[[ $version =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "버전은 1.2.3 꼴"; exit 1; }
security find-certificate -c "LocalMinutes Signing" >/dev/null 2>&1 || { echo "LocalMinutes Signing 인증서가 없습니다. 멈춥니다."; exit 1; }
cd "$root"
[[ -z $(git status --porcelain) ]] || { echo "커밋 안 된 변경이 있습니다. 먼저 정리하세요."; git status --short; exit 1; }
git rev-parse "v$version" >/dev/null 2>&1 && { echo "v$version 태그가 이미 있습니다."; exit 1; }

build=$(( $(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" app/Info.plist) + 1 ))
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $version" -c "Set CFBundleVersion $build" app/Info.plist

scripts/package.sh
zip="dist/LocalMinutes-$version.zip"
rm -f "$zip" "$zip.sha256"
ditto -c -k --sequesterRsrc --keepParent dist/LocalMinutes.app "$zip"
( cd dist && shasum -a 256 "LocalMinutes-$version.zip" > "LocalMinutes-$version.zip.sha256" )

notes="## 바뀐 것"$'\n'
for line in "$@"; do notes+="- $line"$'\n'; done
notes+=$'\n'"앱을 이미 쓰고 있으면 앱이 알려 줍니다(메뉴 → 업데이트 확인…). 처음 설치는 README 의 '설치' 를 보세요."

git add app/Info.plist
git commit -q -m "release: $version"
git tag "v$version"
git push -q origin HEAD "v$version"
gh release create "v$version" "$zip" "$zip.sha256" --repo "$repo" --title "LocalMinutes $version" --notes "$notes"
echo "올림: https://github.com/$repo/releases/tag/v$version"

#!/bin/zsh
# 개발용: 배포본과 똑같이 만든 앱(scripts/package.sh)을 ~/Applications 에 설치한다(런치패드 · Spotlight).
set -euo pipefail
root=${0:A:h:h}
"$root/scripts/package.sh"
osascript -e 'quit app id "local.minutes.app"' 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/LocalMinutes.app"
ditto "$root/dist/LocalMinutes.app" "$HOME/Applications/LocalMinutes.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$HOME/Applications/LocalMinutes.app"
echo "installed $HOME/Applications/LocalMinutes.app"

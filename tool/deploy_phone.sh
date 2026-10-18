#!/usr/bin/env bash
# 릴리스 APK를 빌드해서 연결된 폰에 덮어쓰기 설치(-r, 라이브러리 유지)하고 실행한다.
#
# 사용법 (Git Bash):
#   tool/deploy_phone.sh              # 빌드 + 설치 + 실행
#   tool/deploy_phone.sh --no-build   # 기존 APK 그대로 설치
#   tool/deploy_phone.sh --shot       # 설치 후 스크린샷(build/phone_shot.png)도 저장
#   tool/deploy_phone.sh -s <기기ID>  # 기기가 여러 대일 때 지정
set -euo pipefail

FLUTTER=${FLUTTER:-/c/src/flutter/bin/flutter}
ADB=${ADB:-/c/src/android-sdk/platform-tools/adb.exe}
PKG=com.osuedit.osu_edit
APK=build/app/outputs/flutter-apk/app-release.apk

build=1 shot=0 serial=""
while [ $# -gt 0 ]; do
  case "$1" in
    --no-build) build=0 ;;
    --shot) shot=1 ;;
    -s) serial=$2; shift ;;
    *) echo "알 수 없는 옵션: $1" >&2; exit 2 ;;
  esac
  shift
done

cd "$(dirname "$0")/.."
[ -x "$ADB" ] || ADB=adb

# 연결된 기기 확인
if [ -z "$serial" ]; then
  mapfile -t ready < <("$ADB" devices | tr -d '\r' | awk 'NR>1 && $2=="device"{print $1}')
  if "$ADB" devices | tr -d '\r' | awk 'NR>1 && $2=="unauthorized"{f=1} END{exit !f}'; then
    echo "폰이 unauthorized 상태입니다. 폰에서 'USB 디버깅 허용'을 눌러주세요." >&2
    exit 1
  fi
  case ${#ready[@]} in
    0) echo "연결된 기기가 없습니다. USB 연결과 USB 디버깅을 확인하세요." >&2; exit 1 ;;
    1) serial=${ready[0]} ;;
    *) echo "기기가 여러 대입니다. -s <ID>로 지정하세요: ${ready[*]}" >&2; exit 1 ;;
  esac
fi
echo "대상 기기: $serial"

if [ "$build" = 1 ]; then
  "$FLUTTER" build apk --release --target-platform android-arm64
fi
[ -f "$APK" ] || { echo "APK가 없습니다: $APK" >&2; exit 1; }

# -r: 기존 앱 데이터(라이브러리) 유지. flutter install은 삭제 후 설치하므로 쓰지 않는다.
"$ADB" -s "$serial" install -r "$APK"
"$ADB" -s "$serial" shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null
echo "설치 및 실행 완료."

if [ "$shot" = 1 ]; then
  sleep 3
  "$ADB" -s "$serial" exec-out screencap -p > build/phone_shot.png
  echo "스크린샷: build/phone_shot.png"
fi

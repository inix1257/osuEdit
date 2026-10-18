#!/usr/bin/env bash
# Builds the Android release APK and publishes it as a GitHub release, which is
# what the in-app update check (lib/platform/app_updater.dart) looks for:
# tag v<version> with an asset named osuEdit-<version>.apk.
#
#   1. Bump `version:` in pubspec.yaml (name+build, e.g. 0.2.0+3; the build
#      number must go up or Android refuses the update).
#   2. tool/release_android.sh            # build only, prints the command
#      tool/release_android.sh --publish  # build + `gh release create`
#
# Updates only install over an app signed with the same key: release builds are
# signed with the keystore named in android/key.properties (not in git; keep a
# backup of the .jks and its password!). Without that file the build falls back
# to the machine's debug key and can't update an app installed from a release.
set -euo pipefail
cd "$(dirname "$0")/.."
FLUTTER=${FLUTTER:-/c/src/flutter/bin/flutter}
version=$(sed -n 's/^version: *\([0-9.]*\).*/\1/p' pubspec.yaml)
[ -n "$version" ] || { echo "no version in pubspec.yaml" >&2; exit 1; }
"$FLUTTER" build apk --release --target-platform android-arm64
apk="build/app/outputs/flutter-apk/osuEdit-$version.apk"
cp build/app/outputs/flutter-apk/app-release.apk "$apk"
echo "built $apk"
if [ "${1:-}" = "--publish" ]; then
  gh release create "v$version" "$apk" --title "osuEdit v$version" --generate-notes
else
  echo "publish: gh release create v$version \"$apk\" --title \"osuEdit v$version\" --notes '...'"
fi

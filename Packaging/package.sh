#!/bin/sh
# MactteryGuard 릴리즈 패키징
# Release 빌드 → dist/MactteryGuard-<버전>.zip + dist/MactteryGuard-<버전>.dmg
# (Homebrew Cask 등록용. 유료 공증 없음 — README의 Gatekeeper 우회 안내 참조)
set -e
cd "$(dirname "$0")/.."

VERSION=$(grep -m1 'MARKETING_VERSION = ' BatteryGuard.xcodeproj/project.pbxproj \
    | sed 's/.*MARKETING_VERSION = //; s/;//')
echo "MactteryGuard $VERSION 패키징"

xcodebuild -project BatteryGuard.xcodeproj -target BatteryGuard \
    -configuration Release -derivedDataPath .build build

APP=".build/Build/Products/Release/MactteryGuard.app"
if [ ! -d "$APP" ]; then
    echo "빌드 산출물을 찾을 수 없음: $APP" >&2
    exit 1
fi

# 헬퍼 데몬이 앱 번들에 임베딩됐는지 확인 (Embed Helper Daemon 단계)
HELPER="$APP/Contents/Library/LaunchDaemons/MactteryGuardHelper"
PLIST="$APP/Contents/Library/LaunchDaemons/com.loveaimg.mactteryguard.helper.plist"
if [ ! -x "$HELPER" ] || [ ! -f "$PLIST" ]; then
    echo "헬퍼 데몬 임베딩 실패: $HELPER / $PLIST" >&2
    exit 1
fi

rm -rf dist staging
mkdir -p dist staging
cp -R "$APP" staging/

ditto -c -k --sequesterRsrc --keepParent \
    staging/MactteryGuard.app "dist/MactteryGuard-${VERSION}.zip"

hdiutil create -volname "MactteryGuard" -srcfolder staging \
    -ov -format UDZO "dist/MactteryGuard-${VERSION}.dmg"

rm -rf staging
echo "완료:"
ls -lh "dist/MactteryGuard-${VERSION}.zip" "dist/MactteryGuard-${VERSION}.dmg"

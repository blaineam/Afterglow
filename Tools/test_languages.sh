#!/bin/zsh
# Launches the app on the Simulator in each of the nine languages and passes when, in every one, it
# is still running after opening its Home window with a translated title, and the built bundles
# carry the phone, watch and permission strings. Shuts the Simulator down afterwards.
#   zsh Tools/test_languages.sh            # all nine
#   zsh Tools/test_languages.sh de ja      # just these; screens land in $TMPDIR/afterglow/languages
set -u
P=${0:A:h:h}
N=$P/app
BUNDLE=com.wemiller.afterglow
DERIVED=${AFTERGLOW_DERIVED:-$HOME/Library/Developer/Afterglow/native-derived}
LOGS=${TMPDIR:-/tmp}/afterglow
OUT=$LOGS/languages
mkdir -p $OUT
LANGUAGES=(en de es fr it ja ko pt-BR zh-Hans)
[ $# -gt 0 ] && LANGUAGES=("$@")

SIM=$(xcrun simctl list devices available | grep -E "iPhone 1[6-9] Pro Max" | grep -oE '[0-9A-F-]{36}' | tail -1)
[ -n "$SIM" ] || { echo "No iPhone Pro Max Simulator" >&2; exit 1; }
trap 'xcrun simctl shutdown $SIM >/dev/null 2>&1' EXIT

xcodebuild -project $N/Afterglow.xcodeproj -scheme Afterglow -configuration Debug -destination "id=$SIM" \
    -derivedDataPath $DERIVED CODE_SIGNING_ALLOWED=NO build > $LOGS/native-xcode-languages.log 2>&1 \
    || { tail -5 $LOGS/native-xcode-languages.log; echo "Build failed" >&2; exit 1; }
APP=$DERIVED/Build/Products/Debug-iphonesimulator/Afterglow.app

FAILED=0
for L in de es fr it ja ko pt-BR zh-Hans; do
    for B in "$APP" "$APP/Watch/AfterglowWatch.app"; do
        if ! plutil -lint "$B/$L.lproj/Localizable.strings" >/dev/null 2>&1; then
            echo "FAIL: ${B:t} has no $L strings" >&2; FAILED=1
        fi
    done
    if ! plutil -lint "$APP/$L.lproj/InfoPlist.strings" >/dev/null 2>&1; then
        echo "FAIL: no $L permission strings" >&2; FAILED=1
    fi
done

xcrun simctl boot $SIM 2>/dev/null
xcrun simctl bootstatus $SIM -b >/dev/null
xcrun simctl install $SIM "$APP" || exit 1
for L in $LANGUAGES; do
    xcrun simctl terminate $SIM $BUNDLE 2>/dev/null
    xcrun simctl launch $SIM $BUNDLE -AppleLanguages "($L)" -AppleLocale "$L" >/dev/null || { echo "FAIL: $L would not launch" >&2; FAILED=1; continue; }
    sleep 8
    xcrun simctl io $SIM screenshot $OUT/$L.png >/dev/null 2>&1
    RUNNING=$(xcrun simctl spawn $SIM launchctl list)
    if [[ $RUNNING != *"UIKitApplication:$BUNDLE"* ]]; then
        echo "FAIL: the app stopped running in $L" >&2
        FAILED=1
    else
        echo "ok: $L"
    fi
done
xcrun simctl terminate $SIM $BUNDLE 2>/dev/null
[ $FAILED -eq 0 ] || exit 1
echo "PASS: ${#LANGUAGES} languages"

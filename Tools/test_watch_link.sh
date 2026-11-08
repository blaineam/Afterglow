#!/bin/zsh
# Proves the Apple Watch link end to end on a paired iPhone and Apple Watch Simulator: builds the
# app, installs both sides, has the watch press Select and turn the crown by itself (a Debug-only
# launch option), and passes only when the phone logged them reaching its frame loop and the app
# is still running. Shuts the Simulators down afterwards. A real watch's double tap and Digital
# Crown are the one thing this can't press.
#   zsh Tools/test_watch_link.sh
set -u
P=${0:A:h:h}
N=$P/app
BUNDLE=com.wemiller.afterglow
WATCH_BUNDLE=$BUNDLE.watchkitapp
DERIVED=${AFTERGLOW_DERIVED:-$HOME/Library/Developer/Afterglow/native-derived}
LOGS=${TMPDIR:-/tmp}/afterglow
mkdir -p $LOGS

PAIR=$(xcrun simctl list -j pairs | python3 -I -c '
import json, sys
pairs = json.load(sys.stdin)["pairs"].values()
good = [p for p in pairs if "iPhone" in p["phone"]["name"] and "Pro" in p["phone"]["name"] and p["state"].startswith("(active")]
good.sort(key=lambda p: p["phone"]["name"], reverse=True)
if good: print(good[0]["phone"]["udid"], good[0]["watch"]["udid"])
')
[ -n "$PAIR" ] || { echo "No paired iPhone and Apple Watch Simulator (Xcode: Devices and Simulators, Pair)" >&2; exit 1; }
PHONE=${PAIR%% *}
WATCH=${PAIR##* }
trap 'xcrun simctl shutdown $WATCH >/dev/null 2>&1; xcrun simctl shutdown $PHONE >/dev/null 2>&1' EXIT

xcodebuild -project $N/Afterglow.xcodeproj -scheme Afterglow -configuration Debug -destination "id=$PHONE" \
    -derivedDataPath $DERIVED CODE_SIGNING_ALLOWED=NO build > $LOGS/native-xcode-link.log 2>&1 \
    || { tail -5 $LOGS/native-xcode-link.log; echo "Build failed; see $LOGS/native-xcode-link.log" >&2; exit 1; }
APP=$DERIVED/Build/Products/Debug-iphonesimulator/Afterglow.app

xcrun simctl boot $PHONE 2>/dev/null; xcrun simctl bootstatus $PHONE -b >/dev/null
xcrun simctl boot $WATCH 2>/dev/null; xcrun simctl bootstatus $WATCH -b >/dev/null
xcrun simctl install $PHONE "$APP" || exit 1
xcrun simctl install $WATCH "$APP/Watch/AfterglowWatch.app" || exit 1
xcrun simctl terminate $PHONE $BUNDLE 2>/dev/null
xcrun simctl terminate $WATCH $WATCH_BUNDLE 2>/dev/null
SESSION_LOG=$(xcrun simctl get_app_container $PHONE $BUNDLE data)/Documents/session.log
rm -f "$SESSION_LOG"
xcrun simctl launch $PHONE $BUNDLE >/dev/null || exit 1
sleep 5
SIMCTL_CHILD_AFTERGLOW_WATCH_AUTOPRESS=3 xcrun simctl launch $WATCH $WATCH_BUNDLE >/dev/null || exit 1

# Nothing arrives for about 2.5 minutes after a cold boot: the phone Simulator's connectivity daemon
# fails its first setup ("initial set up failed. Awaiting trigger") until appconduitd is up. The
# watch's presses wait in its queue and all arrive at once when it recovers.
RESULT=1
for _ in {1..120}; do
    sleep 3
    if grep -q "\[Watch\] Select reached the frame" "$SESSION_LOG" 2>/dev/null \
        && grep -q "\[Watch\] Scroll" "$SESSION_LOG" 2>/dev/null; then RESULT=0; break; fi
done
sleep 3
grep "\[Watch\]" "$SESSION_LOG" 2>/dev/null
RUNNING=$(xcrun simctl spawn $PHONE launchctl list)
if [[ $RUNNING != *"UIKitApplication:$BUNDLE"* ]]; then
    echo "FAIL: the phone app stopped running" >&2
    exit 1
fi
[ $RESULT -eq 0 ] || { echo "FAIL: the phone never logged the watch's select and scroll" >&2; exit 1; }
echo "PASS: the watch's select and scroll reached the phone, which is still running"

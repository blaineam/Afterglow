#!/bin/zsh
# Builds the app for the iOS Simulator, installs it on a booted iPhone simulator, launches it and
# prints the start of the session log. For working on the screens, the media browser, playback and
# the browser without a phone in hand.
#   zsh Tools/ios_sim_build_and_run.sh                   # Unity export, then Xcode, then the simulator
#   zsh Tools/ios_sim_build_and_run.sh --xcode           # skip Unity and rebuild from the existing export
#   zsh Tools/ios_sim_build_and_run.sh --launch          # skip both and relaunch what's installed
#   zsh Tools/ios_sim_build_and_run.sh --ei demo 1       # with launch options, as on the phone
#
# What the Simulator cannot do, and this script does not pretend it can: ARKit, so no 6DoF, no
# passthrough, no surfaces and no camera-tracked hands. The app notices (Capabilities) and runs in
# 3DoF, with a drag to look around and a click as the tap (DeskHeadLook). Photos, WKWebView and
# video decoding all work. Spatial photos and videos can be added to the simulator's library with
#   xcrun simctl addmedia booted ~/Pictures/some-spatial-photo.HEIC
#
# SIMULATOR names the device (default "iPhone 18 Pro Max"); the first available one of that name
# is used, booted if it has to be. The simulator is left running for you to look at.
set -u
P=${0:A:h:h}
U=${UNITY:-/Applications/Unity/Hub/Editor/6000.6.0f1/Unity.app/Contents/MacOS/Unity}
BUNDLE=${CARDBOARDXR_BUNDLE_ID:-com.brenpoly.cardboardxr}
SIMULATOR=${SIMULATOR:-iPhone 18 Pro Max}
XCODE_PROJECT=$P/Builds/iOS-Simulator/Unity-iPhone.xcodeproj
DERIVED=$P/Builds/ios-sim-derived
LOGS=${TMPDIR:-/tmp}/cardboardxr
mkdir -p $LOGS
cd $P || exit 1

STAGE=all
case "${1:-}" in
    --xcode) STAGE=xcode; shift ;;
    --launch) STAGE=launch; shift ;;
esac
zsh $P/Tools/ios_launch.sh --check "$@" || exit 1

# The launch options, as the environment devicectl would set on a phone: simctl passes a child
# process any variable prefixed SIMCTL_CHILD_.
typeset -a CHILD_ENV
OPTIONS=("$@")
while [ $# -gt 0 ]; do
    CHILD_ENV+=("SIMCTL_CHILD_CARDBOARDXR_$2=$3")
    shift 3
done

if [ $STAGE = all ]; then
    if pgrep -f "Unity.app/Contents/MacOS/Unity" >/dev/null; then echo "Unity is running; close it first"; exit 1; fi
    zsh $P/Tools/make_videos.sh || exit 1
    echo "== Unity export for the Simulator"
    rm -f $LOGS/ios-sim.log
    CARDBOARDXR_SIMULATOR=1 $U -batchmode -quit -projectPath $P -buildTarget iOS \
        -executeMethod ProjectBootstrap.StereoBuilder.BuildIos -logFile $LOGS/ios-sim.log
    grep -E "\[Build\]|error CS" $LOGS/ios-sim.log | head -10
    grep -q "Build Succeeded" $LOGS/ios-sim.log || { echo "Unity export failed; see $LOGS/ios-sim.log"; exit 1; }
fi

# The simulator: an available device of that name, preferring one already booted.
UDID=$(xcrun simctl list devices available | grep -E "^ *$SIMULATOR \(" | grep -oE '[0-9A-F-]{36}' | head -1)
BOOTED=$(xcrun simctl list devices booted | grep -E "^ *$SIMULATOR \(" | grep -oE '[0-9A-F-]{36}' | head -1)
[ -n "$BOOTED" ] && UDID=$BOOTED
if [ -z "$UDID" ]; then
    echo "No simulator named \"$SIMULATOR\". Available iPhones:"
    xcrun simctl list devices available | grep -E "^ *iPhone" | sed 's/^ */   /'
    exit 1
fi
echo "== simulator $SIMULATOR $UDID"

if [ $STAGE != launch ]; then
    echo "== Xcode build for the Simulator"
    xcodebuild -project $XCODE_PROJECT -scheme Unity-iPhone -configuration Debug \
        -sdk iphonesimulator -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath $DERIVED \
        CODE_SIGNING_ALLOWED=NO build > $LOGS/xcode-sim.log 2>&1
    XCODE_STATUS=$?
    tail -5 $LOGS/xcode-sim.log
    if [ $XCODE_STATUS -ne 0 ]; then
        grep -m 5 -E "error:" $LOGS/xcode-sim.log
        echo "Xcode build failed; the full output is in $LOGS/xcode-sim.log. Nothing was installed."
        exit 1
    fi
fi
APP=$(ls -d $DERIVED/Build/Products/Debug-iphonesimulator/*.app 2>/dev/null | head -1)
[ -n "$APP" ] || { echo "No .app built; see $LOGS/xcode-sim.log."; exit 1; }

if [ -z "$BOOTED" ]; then
    echo "== booting"
    xcrun simctl boot $UDID || exit 1
    xcrun simctl bootstatus $UDID -b >/dev/null
fi
# The Simulator app shows the booted device; opening it again only brings it to the front. Xcode 27
# no longer ships it inside Xcode.app, so a missing one is not an error: the device still runs, and
# any viewer that attaches to a booted simulator shows it.
SIM_APP="$(xcode-select -p)/Applications/Simulator.app"
if [ -d "$SIM_APP" ]; then
    open -a "$SIM_APP" --args -CurrentDeviceUDID $UDID
else
    echo "(no Simulator.app in this Xcode; the simulator runs without its window)"
fi

if [ $STAGE != launch ]; then
    echo "== install"
    xcrun simctl install $UDID "$APP" || exit 1
fi

echo "== launch ${OPTIONS[*]:-without options}"
xcrun simctl terminate $UDID $BUNDLE 2>/dev/null
env "${CHILD_ENV[@]}" xcrun simctl launch $UDID $BUNDLE || exit 1

echo "== waiting for the app to write its log"
sleep 20
CONTAINER=$(xcrun simctl get_app_container $UDID $BUNDLE data 2>/dev/null)
if [ -n "$CONTAINER" ] && [ -f "$CONTAINER/Documents/session.log" ]; then
    cp "$CONTAINER/Documents/session.log" $LOGS/sim-session.log
    echo "== session log ($LOGS/sim-session.log)"
    grep -E "\[Stereo\]|\[Demos\]|\[Pose\]|\[AR\]|\[Viewer\]|Warning|Error|Exception" $LOGS/sim-session.log \
        | grep -v stereoTargetEye | cut -c1-200 | head -30
else
    echo "No session log yet. The simulator's app data is at: ${CONTAINER:-unknown}"
fi

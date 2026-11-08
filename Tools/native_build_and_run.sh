#!/bin/zsh
# Builds the native iOS app in ios-native/, signs it, installs it and launches it on the iPhone,
# then prints the start of its session log. The native counterpart of ios_build_and_run.sh.
#   zsh Tools/native_build_and_run.sh                       # build, install, launch
#   zsh Tools/native_build_and_run.sh --ei passthrough 1    # with launch options (see ios-native/README.md)
#   zsh Tools/native_build_and_run.sh --launch              # skip the build; launch what's installed
#   zsh Tools/native_build_and_run.sh --log                 # only copy the session log back
#   zsh Tools/native_build_and_run.sh --test                # run the unit tests on a simulator instead
#   zsh Tools/native_build_and_run.sh --sim --ei dump 3     # build for the iOS Simulator and run it there
# Launch options are "--ei name value" pairs, reaching the app as AFTERGLOW_name, as on the Unity side.
# The phone: the first reachable iPhone, or the one AFTERGLOW_DEVICE names (a UDID, or a word from
# devicectl's model column such as "iPhone18,2" for the 17 Pro Max), so the 18 Pro Max can be kept
# free while another phone takes the builds. The Simulator has no ARKit: it draws the surroundings
# in stereo through the lenses with the head still, which is enough to check the rig and shaders.
# Needs xcodegen (brew install xcodegen) only when project.yml has changed since the project was
# generated. Signing: the same team detection as ios_build_and_run.sh (TEAM=... overrides).
set -u
P=${0:A:h:h}
N=$P/ios-native
# The same bundle id as the Unity app: installing this replaces that one on the phone.
BUNDLE=${AFTERGLOW_NATIVE_BUNDLE_ID:-com.wemiller.afterglow}
PROJECT=$N/Afterglow.xcodeproj
# Build output lives off iCloud: in the repo's folder iCloud made "Afterglow 2.app" conflict copies
# that the Simulator then ran (2026-11-08). AFTERGLOW_DERIVED overrides.
DERIVED=${AFTERGLOW_DERIVED:-$HOME/Library/Developer/Afterglow/native-derived}
LOGS=${TMPDIR:-/tmp}/afterglow
mkdir -p $LOGS
cd $P || exit 1

MODE=build
case "${1:-}" in
    --launch) MODE=launch; shift ;;
    --log) MODE=log; shift ;;
    --test) MODE=test; shift ;;
    --sim) MODE=sim; shift ;;
esac

# The options as the JSON dictionary devicectl takes.
ENVIRONMENT=""
SIMENV=()
DUMP=0
OPTIONS=("$@")
while [ $# -gt 0 ]; do
    if [ "$1" != "--ei" ] || [ $# -lt 3 ]; then echo "Launch options are \"--ei name value\" pairs; got: $*"; exit 1; fi
    case "$2" in (''|*[!A-Za-z0-9]*) echo "Option names are letters and digits, got \"$2\""; exit 1 ;; esac
    # Numbers, except "url" (an address) and "actions" (a test script).
    if [ "$2" != url ] && [ "$2" != actions ]; then
        case "$3" in (-|'') echo "Option $2 needs a whole number, got \"$3\""; exit 1 ;; (*[!0-9-]*) echo "Option $2 needs a whole number, got \"$3\""; exit 1 ;; esac
    fi
    ENVIRONMENT+="${ENVIRONMENT:+, }\"AFTERGLOW_$2\": \"$3\""
    SIMENV+=("SIMCTL_CHILD_AFTERGLOW_$2=$3")   # simctl passes the environment this way
    [ "$2" = dump ] && DUMP=$3
    shift 3
done

# iCloud leaves " 2" copies of files beside the originals; Xcode would compile them twice.
find $N -name '* 2.*' -not -path '*/xcuserdata/*' -print -exec rm -f {} \; 2>/dev/null | sed 's/^/== removed iCloud duplicate /'

# Regenerate the project when its spec is newer.
if [ ! -d $PROJECT ] || [ $N/project.yml -nt $PROJECT/project.pbxproj ]; then
    command -v xcodegen >/dev/null || { echo "xcodegen is needed to (re)generate the project: brew install xcodegen"; exit 1; }
    (cd $N && xcodegen generate) || exit 1
fi

if [ $MODE = test ] || [ $MODE = sim ]; then
    # A Pro Max simulator first (the screen the lens geometry is built for), else any recent iPhone.
    SIM=$(xcrun simctl list devices available | grep -E "iPhone 1[6-9] Pro Max" | grep -oE '[0-9A-F-]{36}' | tail -1)
    [ -n "$SIM" ] || SIM=$(xcrun simctl list devices available | grep -E "iPhone 1[6-9]|iPhone 2" | grep -oE '[0-9A-F-]{36}' | head -1)
    [ -n "$SIM" ] || { echo "No iPhone simulator available"; exit 1; }
fi

if [ $MODE = sim ]; then
    echo "== simulator $SIM"
    xcodebuild -project $PROJECT -scheme Afterglow -configuration Debug -destination "id=$SIM" \
        -derivedDataPath $DERIVED CODE_SIGNING_ALLOWED=NO build > $LOGS/native-xcode-sim.log 2>&1
    STATUS=$?
    grep -E "warning:|error:" $LOGS/native-xcode-sim.log | sort -u | head -20
    [ $STATUS -eq 0 ] || { echo "Simulator build failed; see $LOGS/native-xcode-sim.log"; exit 1; }
    # By name: iCloud leaves "Afterglow 2.app" conflict copies in the build folder, which sort first
    # and installed a stale app for a whole round of Simulator checks (2026-11-08).
    APP=$DERIVED/Build/Products/Debug-iphonesimulator/Afterglow.app
    xcrun simctl boot $SIM 2>/dev/null; xcrun simctl bootstatus $SIM -b >/dev/null
    xcrun simctl install $SIM "$APP" || exit 1
    xcrun simctl terminate $SIM $BUNDLE 2>/dev/null
    # The fixture media (Tools/make_fixture_media.py) into the app's Media folder for the Files app.
    FIX=${TMPDIR:-/tmp}/afterglow/fixtures
    if [ -d $FIX ]; then
        DATA=$(xcrun simctl get_app_container $SIM $BUNDLE data 2>/dev/null) && mkdir -p "$DATA/Documents/Media" && cp -n $FIX/* "$DATA/Documents/Media/" 2>/dev/null
    fi
    # The last run's log goes first: the screenshot steps are counted in it, and a stale one with
    # more steps than this run made every screenshot fire at launch (2026-11-08).
    rm -f "$(xcrun simctl get_app_container $SIM $BUNDLE data 2>/dev/null)/Documents/session.log"
    env "${SIMENV[@]}" xcrun simctl launch $SIM $BUNDLE >/dev/null || exit 1
    echo "== launched in the simulator ${ENVIRONMENT:+with {$ENVIRONMENT}}"
    # While the app runs, a screenshot of the Simulator's screen for every "screenshot" step the
    # test script logs (native-sim-screen-N.png), since the app's own eye dump cannot show a page
    # that has taken the screen.
    DATA=$(xcrun simctl get_app_container $SIM $BUNDLE data)
    SHOTS=0
    rm -f $LOGS/native-sim-screen-*.png
    for i in $(seq 1 $(( 8 + DUMP ))); do
        sleep 1
        COUNT=$(grep -c "\[Actions\] screenshot" "$DATA/Documents/session.log" 2>/dev/null | head -1); COUNT=${COUNT:-0}
        while [ "$SHOTS" -lt "$COUNT" ]; do
            SHOTS=$(( SHOTS + 1 ))
            xcrun simctl io $SIM screenshot $LOGS/native-sim-screen-$SHOTS.png >/dev/null 2>&1 && echo "== screenshot $SHOTS: $LOGS/native-sim-screen-$SHOTS.png"
        done
    done
    cp "$DATA/Documents/session.log" $LOGS/native-sim-session.log 2>/dev/null && { echo "== session log ($LOGS/native-sim-session.log)"; grep -vE "Drawable" $LOGS/native-sim-session.log | cut -c1-220 | head -30; }
    [ -f "$DATA/Documents/eye-left.png" ] && { cp "$DATA/Documents/eye-left.png" $LOGS/native-sim-eye-left.png; echo "== left eye: $LOGS/native-sim-eye-left.png"; }
    xcrun simctl io $SIM screenshot $LOGS/native-sim-screen.png >/dev/null 2>&1 && echo "== screen: $LOGS/native-sim-screen.png"
    xcrun simctl terminate $SIM $BUNDLE 2>/dev/null
    xcrun simctl shutdown $SIM >/dev/null 2>&1
    exit 0
fi

if [ $MODE = test ]; then
    xcodebuild -project $PROJECT -scheme Afterglow -destination "id=$SIM" -derivedDataPath $DERIVED \
        CODE_SIGNING_ALLOWED=NO test > $LOGS/native-tests.log 2>&1
    STATUS=$?
    grep -E "Test Suite|Test Case.*(passed|failed)|error:|\*\* TEST" $LOGS/native-tests.log | tail -30
    xcrun simctl shutdown $SIM >/dev/null 2>&1
    exit $STATUS
fi

# The phone, by UDID: a real iPhone, not a simulator or an Apple TV (see ios_build_and_run.sh),
# narrowed to AFTERGLOW_DEVICE when that is set.
UDID=$(xcrun devicectl list devices 2>/dev/null \
    | grep -v 'simulated' \
    | grep -iE '[[:space:]]iPhone[0-9]+,[0-9]+|[[:space:]]iPhone [0-9]' \
    | grep -E '[[:space:]](connected|available)([[:space:]]|$|[[:space:]]\(paired\))' \
    | { if [ -n "${AFTERGLOW_DEVICE:-}" ]; then grep -F "$AFTERGLOW_DEVICE"; else cat; fi; } \
    | grep -oE '[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}' | head -1)
if [ -z "$UDID" ]; then
    echo "No reachable iPhone. Plug it in, unlock it, and trust this Mac."
    exit 1
fi
echo "== iPhone $UDID"

if [ $MODE = build ]; then
    TEAM=${TEAM:-$(security find-certificate -c "Apple Development" -p 2>/dev/null \
        | openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*OU *= *\([A-Z0-9]\{10\}\).*/\1/p')}
    if [ -n "$TEAM" ]; then echo "== team $TEAM"; TEAM_SETTING=(DEVELOPMENT_TEAM=$TEAM); else TEAM_SETTING=(); fi
    echo "== Xcode build and sign"
    xcodebuild -project $PROJECT -scheme Afterglow -configuration Debug \
        -destination "id=$UDID" -derivedDataPath $DERIVED \
        -allowProvisioningUpdates "${TEAM_SETTING[@]}" CODE_SIGN_STYLE=Automatic \
        build > $LOGS/native-xcode.log 2>&1
    STATUS=$?
    grep -E "warning:|error:" $LOGS/native-xcode.log | grep -v "^$" | sort -u | head -20
    if [ $STATUS -ne 0 ]; then
        echo "Xcode build failed; the full output is in $LOGS/native-xcode.log. Nothing was installed."
        exit 1
    fi
    APP=$DERIVED/Build/Products/Debug-iphoneos/Afterglow.app
    [ -d "$APP" ] || APP=""
    [ -n "$APP" ] || { echo "No .app built"; exit 1; }
    echo "== install"
    xcrun devicectl device install app --device $UDID "$APP" > $LOGS/native-install.log 2>&1 || {
        tail -5 $LOGS/native-install.log
        echo "Install failed. If the phone asks, turn on Developer Mode and run this again."
        exit 1
    }
fi

if [ $MODE = build ] || [ $MODE = launch ]; then
    if [ -n "$ENVIRONMENT" ]; then
        LAUNCH=$(xcrun devicectl device process launch --device $UDID --terminate-existing -e "{$ENVIRONMENT}" $BUNDLE 2>&1)
        LAUNCHED="with {$ENVIRONMENT}"
    else
        LAUNCH=$(xcrun devicectl device process launch --device $UDID --terminate-existing $BUNDLE 2>&1)
        LAUNCHED="without options"
    fi
    case "$LAUNCH" in
        *Locked*|*unlocked*) echo "The phone is locked. Unlock it and run: zsh Tools/native_build_and_run.sh --launch ${OPTIONS[*]}"; exit 1 ;;
        *ERROR*) echo "$LAUNCH" | tail -5; echo "On the first run, trust the developer under Settings > General > VPN & Device Management."; exit 1 ;;
    esac
    echo "== launched $LAUNCHED"
    echo "== waiting for the app to write its log"
    sleep 20
fi

# The copy sometimes fails once right after a launch; a second try a moment later works.
copy_log() {
    xcrun devicectl device copy from --device $UDID --domain-type appDataContainer \
        --domain-identifier $BUNDLE --source Documents/session.log --destination $LOGS/native-session.log >/dev/null 2>&1
}
rm -f $LOGS/native-session.log
copy_log || { sleep 3; copy_log; } \
    && { echo "== session log ($LOGS/native-session.log)"; grep -E "\[Stereo\]|\[AR\]|\[Pose\]|\[Frames\]|\[Thermal\]|\[Passthrough\]|Warning|Error" $LOGS/native-session.log | cut -c1-220 | head -40; } \
    || echo "No session log yet: $LOGS/native-session.log"

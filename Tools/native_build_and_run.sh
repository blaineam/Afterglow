#!/bin/zsh
# Builds the native iOS app in ios-native/, signs it, installs it and launches it on the iPhone,
# then prints the start of its session log. The native counterpart of ios_build_and_run.sh.
#   zsh Tools/native_build_and_run.sh                       # build, install, launch
#   zsh Tools/native_build_and_run.sh --ei passthrough 1    # with launch options (see ios-native/README.md)
#   zsh Tools/native_build_and_run.sh --launch              # skip the build; launch what's installed
#   zsh Tools/native_build_and_run.sh --log                 # only copy the session log back
#   zsh Tools/native_build_and_run.sh --test                # run the unit tests on a simulator instead
# Launch options are "--ei name value" pairs, reaching the app as AFTERGLOW_name, as on the Unity side.
# Needs xcodegen (brew install xcodegen) only when project.yml has changed since the project was
# generated. Signing: the same team detection as ios_build_and_run.sh (TEAM=... overrides).
set -u
P=${0:A:h:h}
N=$P/ios-native
BUNDLE=${AFTERGLOW_NATIVE_BUNDLE_ID:-com.wemiller.afterglow.native}
PROJECT=$N/Afterglow.xcodeproj
DERIVED=$P/Builds/native-derived
LOGS=${TMPDIR:-/tmp}/afterglow
mkdir -p $LOGS
cd $P || exit 1

MODE=build
case "${1:-}" in
    --launch) MODE=launch; shift ;;
    --log) MODE=log; shift ;;
    --test) MODE=test; shift ;;
esac

# The options as the JSON dictionary devicectl takes.
ENVIRONMENT=""
OPTIONS=("$@")
while [ $# -gt 0 ]; do
    if [ "$1" != "--ei" ] || [ $# -lt 3 ]; then echo "Launch options are \"--ei name value\" pairs; got: $*"; exit 1; fi
    case "$2" in (''|*[!A-Za-z0-9]*) echo "Option names are letters and digits, got \"$2\""; exit 1 ;; esac
    case "$3" in (-|'') echo "Option $2 needs a whole number, got \"$3\""; exit 1 ;; (*[!0-9-]*) echo "Option $2 needs a whole number, got \"$3\""; exit 1 ;; esac
    ENVIRONMENT+="${ENVIRONMENT:+, }\"AFTERGLOW_$2\": \"$3\""
    shift 3
done

# iCloud leaves " 2" copies of files beside the originals; Xcode would compile them twice.
find $N -name '* 2.*' -not -path '*/xcuserdata/*' -print -exec rm -f {} \; 2>/dev/null | sed 's/^/== removed iCloud duplicate /'

# Regenerate the project when its spec is newer.
if [ ! -d $PROJECT ] || [ $N/project.yml -nt $PROJECT/project.pbxproj ]; then
    command -v xcodegen >/dev/null || { echo "xcodegen is needed to (re)generate the project: brew install xcodegen"; exit 1; }
    (cd $N && xcodegen generate) || exit 1
fi

if [ $MODE = test ]; then
    SIM=$(xcrun simctl list devices available | grep -E "iPhone 1[6-9]|iPhone 2" | grep -oE '[0-9A-F-]{36}' | head -1)
    [ -n "$SIM" ] || { echo "No iPhone simulator available"; exit 1; }
    xcodebuild -project $PROJECT -scheme Afterglow -destination "id=$SIM" -derivedDataPath $DERIVED \
        CODE_SIGNING_ALLOWED=NO test > $LOGS/native-tests.log 2>&1
    STATUS=$?
    grep -E "Test Suite|Test Case.*(passed|failed)|error:|\*\* TEST" $LOGS/native-tests.log | tail -30
    xcrun simctl shutdown $SIM >/dev/null 2>&1
    exit $STATUS
fi

# The phone, by UDID: a real iPhone, not a simulator or an Apple TV (see ios_build_and_run.sh).
UDID=$(xcrun devicectl list devices 2>/dev/null \
    | grep -v 'simulated' \
    | grep -iE '[[:space:]]iPhone[0-9]+,[0-9]+|[[:space:]]iPhone [0-9]' \
    | grep -E '[[:space:]](connected|available)([[:space:]]|$|[[:space:]]\(paired\))' \
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
    APP=$(ls -d $DERIVED/Build/Products/Debug-iphoneos/*.app 2>/dev/null | head -1)
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

xcrun devicectl device copy from --device $UDID --domain-type appDataContainer \
    --domain-identifier $BUNDLE --source Documents/session.log --destination $LOGS/native-session.log 2>/dev/null \
    && { echo "== session log ($LOGS/native-session.log)"; grep -E "\[Stereo\]|\[AR\]|\[Pose\]|\[Frames\]|\[Thermal\]|\[Passthrough\]|Warning|Error" $LOGS/native-session.log | cut -c1-220 | head -40; } \
    || echo "No session log yet: $LOGS/native-session.log"

#!/bin/zsh
# The raw App Store screenshots, from a finished gallery run (Tools/capture_gallery.sh) and a new
# one of the watch app, into app/screenshots/<device key>. Then builds the Monkr projects
# that frame them, since those embed the images and are not committed.
#   zsh Tools/capture_store_screenshots.sh       # from anywhere; rocket shots runs it
set -eu
P=${0:A:h:h}
N=$P/app
LOGS=${TMPDIR:-/tmp}/afterglow
OUT=$N/screenshots/iphone-6.9
rm -rf $OUT; mkdir -p $OUT
# The order they appear in the listing. Afterglow is landscape: each is stored a quarter turn round
# so Monkr's frame, on its side with the Dynamic Island on the left as in landscape-right, shows it upright.
i=0
for shot in through-the-lenses windows place-world photo-360 browser-page games game-blobs game-coaster game-golf game-drive; do
    i=$(( i + 1 ))
    src=$LOGS/gallery/$shot.png
    [ -f "$src" ] || { echo "No $src: run Tools/capture_gallery.sh first" >&2; exit 1; }
    sips -r 90 "$src" --out "$OUT/$(printf %02d $i)-$shot.png" >/dev/null
done
ls $OUT | wc -l

# The watch app, on its own simulator.
WATCHDIR=$N/screenshots/watch-46mm
rm -rf $WATCHDIR; mkdir -p $WATCHDIR
WATCH=$(xcrun simctl list devices available | grep -E "Apple Watch Series 1[01] \(46mm\)" | grep -oE '[0-9A-F-]{36}' | tail -1)
[ -n "$WATCH" ] || { echo "No Apple Watch Series 10 or 11 46mm simulator" >&2; exit 1; }
xcrun simctl boot $WATCH 2>/dev/null || true
xcrun simctl bootstatus $WATCH -b >/dev/null
DERIVED=$HOME/Library/Developer/Afterglow/native-derived-watch
xcodebuild -project $N/Afterglow.xcodeproj -target AfterglowWatch -sdk watchsimulator -configuration Debug \
    SYMROOT=$DERIVED CODE_SIGNING_ALLOWED=NO build >$LOGS/native-xcode-watch.log 2>&1 || { tail -5 $LOGS/native-xcode-watch.log; exit 1; }
xcrun simctl install $WATCH $DERIVED/Debug-watchsimulator/AfterglowWatch.app
SIMCTL_CHILD_AFTERGLOW_WATCH_SHOT=1 xcrun simctl launch --terminate-running-process $WATCH com.wemiller.afterglow.watchkitapp >/dev/null
sleep 6
xcrun simctl io $WATCH screenshot $WATCHDIR/01-select.png >/dev/null 2>&1
xcrun simctl shutdown $WATCH

python3 $P/Tools/make_store_monkr.py

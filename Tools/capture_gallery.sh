#!/bin/zsh
# Renders the gallery: what each Afterglow experience looks like from inside, as pictures of the
# eye's own texture (no lens warp, no phone overlay) from the Simulator's phone view, plus a stereo
# pair through the lenses and the WebXR sessions, which only the screen can show. They land in
# docs/gallery as JPEGs, for the README and the marketing page.
#
#   WEBXR_VR_URL=<a WebXR VR page> WEBXR_AR_URL=<a WebXR AR page> SITE_URL=<a page to browse> \
#     zsh Tools/capture_gallery.sh
#
# The Simulator has no camera, so the room's passthrough is never in these; the pictures show the
# app's own surroundings. The URLs are given when it runs, so none is named in the repository;
# without them those shots are skipped. The app's Media folder is borrowed for the run: its test
# patterns are moved aside for some of the bundled photospheres and put back afterwards.
set -u
setopt NULL_GLOB
P=${0:A:h:h}
OUT=$P/docs/gallery
LOGS=${TMPDIR:-/tmp}/afterglow
BUNDLE=${AFTERGLOW_NATIVE_BUNDLE_ID:-com.wemiller.afterglow}
HARNESS=$P/Tools/native_build_and_run.sh
PLACES=$P/ios-native/Afterglow/Places
mkdir -p $OUT
rm -f $OUT/*.jpg

SIM=$(xcrun simctl list devices available | grep -E "iPhone 1[6-9] Pro Max" | grep -oE '[0-9A-F-]{36}' | tail -1)
xcrun simctl boot $SIM 2>/dev/null; xcrun simctl bootstatus $SIM -b >/dev/null
DATA=$(xcrun simctl get_app_container $SIM $BUNDLE data) || { echo "Run Tools/native_build_and_run.sh --sim once first"; exit 1; }
# The harness copies its fixtures back in when the folder it keeps them in exists; moved aside for the run.
FIX=$LOGS/fixtures; FIXAWAY=$LOGS/fixtures-away
[ -d $FIX ] && mv $FIX $FIXAWAY
AWAY=$DATA/Documents/Media-aside
mkdir -p "$AWAY"; mv "$DATA/Documents/Media/"* "$AWAY/" 2>/dev/null
for f in grand-library japanese-garden-autumn mountain-lake-dawn starship-cabin treehouse-night beach-bungalows-sunset forest-cabin-night space-station; do
    cp "$PLACES/$f.jpg" "$DATA/Documents/Media/"
done
restore() {
    rm -f "$DATA/Documents/Media/"*.jpg
    mv "$AWAY/"* "$DATA/Documents/Media/" 2>/dev/null; rmdir "$AWAY" 2>/dev/null
    [ -d $FIXAWAY ] && mv $FIXAWAY $FIX
}
trap restore EXIT

jpeg() { sips -s format jpeg -s formatOptions 84 -Z 1920 "$1" --out "$OUT/$2.jpg" >/dev/null && echo "  $2.jpg"; }

# One run in the phone view: the eye is the whole screen's shape, centred on the gaze.
GO=()
step() { GO+=("$1"); }
close() { step "press win:${1}:close"; step "wait 1"; }   # the braces: $1:c is a zsh modifier
game() {  # game <index>
    step "open games"; step "wait 1"; step "press game:$1"; step "wait 1.5"
    # The controls window out of the picture, except where it is the point.
    [ "${2:-}" = "controls" ] || { step "press win:gameControls:minimize"; step "wait 0.5"; }
}
stopgame() { step "look 0 0"; step "press stop"; step "wait 1"; step "press win:games:close"; step "wait 0.5"; }

step "wait 4"; step "shot home"
step "dock"; step "look 0 -24"; step "wait 1.5"; step "shot dock"; step "look 0 0"; step "wait 0.5"; close home
# A fresh tab, and the tabs a run before left behind closed, so no page's name is in the picture.
step "open browser"; step "wait 3"; step "press new"; step "wait 1"; step "press tab:0"; step "wait 0.5"; step "press close"; step "wait 2"; step "shot browser-start"
if [ -n "${SITE_URL:-}" ]; then step "js location.href='$SITE_URL'"; step "wait 7"; step "shot browser-page"; fi
close browser
step "open browser"; step "wait 2"; step "open music"; step "wait 2"; step "look -19 0"; step "wait 2"; step "shot windows"; step "look 0 0"; close music; close browser
step "open files"; step "wait 2"; step "press album:0"; step "wait 4"; step "shot files"
step "press item:0"; step "wait 4"; step "shot photo-360"; close files
step "open places"; step "wait 3"; step "shot places"; step "world 2"; step "wait 3"; step "shot place-world"
step "press synth"; step "wait 1"; close places
step "open music"; step "wait 2"; step "shot music"; close music
step "open settings"; step "wait 2"; step "shot settings"; step "press toggle:passcode"; step "wait 1"; step "shot lock"; step "press key:✕"; step "wait 0.5"; close settings
step "open games"; step "wait 2"; step "shot games"; step "press win:games:close"; step "wait 0.5"
# Paint: the hand follows the head, so a sweep of the gaze draws.
game 0; step "fakehand 0"; step "wait 0.3"; step "fakehand 1"
for a in "-20 -14" "-14 -4" "-8 -14" "-2 -4" "4 -14" "10 -4" "16 -14" "20 -6" "10 2" "0 -8" "-10 2" "-20 -6"; do step "look $a"; step "wait 0.25"; done
step "fakehand off"; step "look 0 -8"; step "wait 1"; step "shot game-paint"; stopgame
game 1; step "wait 7"; step "shot game-blobs"; stopgame
game 2; step "look 0 -32"; step "wait 2"; step "shot game-vacuum"; stopgame
game 3 controls; step "wait 1"; for i in 1 2 3 4; do step "press toy:new"; step "wait 0.5"; done; step "press toy:wake"; step "look 0 -28"; step "wait 3"; step "shot game-toys"; stopgame
game 4 controls; step "look 0 -22"; step "wait 2"; step "shot game-golf"; stopgame
game 5 controls; step "wait 0.5"; step "press ride:go"; step "wait 55"; step "shot game-coaster"; stopgame
game 6 controls; step "wait 3"; step "shot game-portal"; step "press portal:through"; step "wait 4"; step "shot game-portal-through"; step "press reset"; step "wait 1"; stopgame
game 7; step "wait 9"; step "shot game-rhythm"; stopgame
# The tower: a stack the script can't time for itself, then drops until one misses: the summary.
game 8; step "wait 1"; step "tower 11"; step "look 0 -24"; step "wait 1.5"; step "shot game-tower"
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do step "tap"; step "wait 0.53"; done; step "wait 1.5"; step "look 0 -5"; step "wait 1.5"; step "shot summary"; step "press exit"; step "wait 1"; stopgame
game 9; for a in "-24 -30" "-10 -38" "6 -34" "20 -30" "-16 -24" "12 -26"; do step "look $a"; step "wait 0.3"; step "tap"; step "wait 0.7"; done; step "look 0 -18"; step "wait 6"; step "shot game-garden"; stopgame
game 10; step "wait 2.5"; step "shot game-pong"; stopgame
game 11; step "wait 9"; step "shot game-drive"; stopgame
step "end"
SCRIPT=${(j:; :)GO}
# The harness keeps the app up this many seconds: the script's waits, with room for its half-second
# shots and for loading.
float WAITS=0
for s in $GO; do [[ $s == wait\ * ]] && WAITS=$(( WAITS + ${s#wait } )); done
integer SHOTS=$(( WAITS * 1.2 + 40 ))
echo "== phone-view run, up to $SHOTS seconds"
zsh $HARNESS --sim --ei view 1 --ei passthrough 0 --ei dump $SHOTS --ei actions "$SCRIPT" | grep -E "error:|gallery" | head
for f in $LOGS/gallery/*.png(N); do jpeg "$f" "${f:t:r}"; done

# One run through the lenses: the two eyes on the screen, and the WebXR sessions.
LENS="wait 5; screenshot; wait 2; end"
echo "== through the lenses"
zsh $HARNESS --sim --ei view 0 --ei passthrough 0 --ei dump 10 --ei actions "$LENS" | grep -E "error:" | head
[ -f $LOGS/native-sim-screen-1.png ] && { jpeg $LOGS/native-sim-screen-1.png through-the-lenses; cp $LOGS/native-sim-screen-1.png $LOGS/gallery/through-the-lenses.png; }
webxr() {  # webxr <url> <name>
    [ -n "$1" ] || return 0
    echo "== WebXR: $2"
    zsh $HARNESS --sim --ei view 0 --ei passthrough 0 --ei web 1 --ei url "$1" --ei dump 24 --ei actions "wait 8; immersive; wait 6; screenshot; wait 3; look 0 -30; wait 3; screenshot; wait 3; end" | grep -E "error:" | head
    # Looking down: the floor's reticle and the Exit VR button are both in view.
    [ -f $LOGS/native-sim-screen-3.png ] && jpeg $LOGS/native-sim-screen-3.png $2
    grep -E "\[WebXR\] (Immersive|Session|Exit|Eyes|The session)|averaged" $LOGS/native-sim-session.log | cut -c1-140 | head -8
}
webxr "${WEBXR_VR_URL:-}" webxr-vr
webxr "${WEBXR_AR_URL:-}" webxr-ar
echo "== $OUT"; ls $OUT | wc -l

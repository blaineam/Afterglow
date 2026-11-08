#!/bin/zsh
# Draws the fixture media (a 360 still, a panorama, two flat photos and a spatial photo) and adds
# it to a booted simulator's Photos library, so the media browser has something to show at a desk;
# a GPano photo sphere and a video with spherical boxes go into the app's Media folder instead.
# Adding the same file twice makes a second copy in the library, so this runs when the library is
# empty or after erasing the simulator.
#   zsh Tools/sim_add_media.sh                 # the booted iPhone 18 Pro Max, or SIMULATOR=<name>
set -u
P=${0:A:h:h}
SIMULATOR=${SIMULATOR:-iPhone 18 Pro Max}
OUT=${TMPDIR:-/tmp}/afterglow/fixtures
UDID=$(xcrun simctl list devices booted | grep -E "^ *$SIMULATOR \(" | grep -oE '[0-9A-F-]{36}' | head -1)
if [ -z "$UDID" ]; then echo "No booted simulator named $SIMULATOR; Tools/native_build_and_run.sh --sim boots one"; exit 1; fi

mkdir -p $OUT
python3 $P/Tools/make_fixture_media.py $OUT || exit 1
swift $P/Tools/make_spatial_photo.swift $OUT/fixture-spatial.heic || exit 1
# A short flat video with a counter, and a 2:1 one that the player should take for 360, if ffmpeg
# is about (brew install ffmpeg); without it the library just has no videos.
if command -v ffmpeg >/dev/null; then
    [ -f $OUT/fixture-video-flat.mp4 ] || ffmpeg -loglevel error -y -f lavfi -i "testsrc=size=1280x720:rate=30" -t 6 \
        -pix_fmt yuv420p -movflags +faststart $OUT/fixture-video-flat.mp4
    [ -f $OUT/fixture-video-360.mp4 ] || ffmpeg -loglevel error -y -f lavfi -i "testsrc=size=2048x1024:rate=30" -t 6 \
        -pix_fmt yuv420p -movflags +faststart $OUT/fixture-video-360.mp4
    # A square clip whose spherical boxes say 360 top/bottom, which nothing in its name does.
    [ -f $OUT/fixture-video-boxes.mp4 ] || { ffmpeg -loglevel error -y -f lavfi -i "testsrc=size=1024x1024:rate=30" -t 6 \
        -pix_fmt yuv420p $OUT/plain.mp4 && python3 $P/Tools/inject_spherical.py $OUT/plain.mp4 $OUT/fixture-video-boxes.mp4 --stereo top-bottom; }
fi
echo "== adding to $SIMULATOR ($UDID)"
xcrun simctl addmedia $UDID $OUT/fixture-360-still.png $OUT/fixture-panorama.jpg $OUT/fixture-flat.jpg $OUT/fixture-tall.jpg \
    $OUT/fixture-spatial.heic $OUT/fixture-video-flat.mp4(N) $OUT/fixture-video-360.mp4(N) || exit 1
# The metadata-marked files go to the app's Media folder, which is where the player reads a
# file's own boxes and GPano (the Photos library classifies its items by their subtypes).
CONTAINER=$(xcrun simctl get_app_container $UDID ${AFTERGLOW_BUNDLE_ID:-com.wemiller.afterglow} data 2>/dev/null)
if [ -n "$CONTAINER" ]; then
    mkdir -p "$CONTAINER/Documents/Media"
    cp $OUT/fixture-sphere.jpg $OUT/fixture-video-boxes.mp4(N) "$CONTAINER/Documents/Media/"
    echo "Copied the photo sphere and the boxed video into the app's Media folder."
else
    echo "The app isn't installed yet, so the Media folder files (fixture-sphere.jpg, fixture-video-boxes.mp4) weren't copied; run again after a build."
fi
echo "Added the library items. Allow Photos in the app, then open Media."

#!/bin/zsh
# Xcode Cloud, before the build. Custom environment variables reach these scripts but not Xcode's
# build phases, so the tempo catalogue's key goes to a file that Tools/embed_tempo_key.sh reads.
# Set it in the workflow's Environment as AUDIOMETA_API_KEY, marked secret.
set -euo pipefail
cd "$CI_PRIMARY_REPOSITORY_PATH/app"
if [ -n "${AUDIOMETA_API_KEY:-}" ]; then
    print -rn -- "$AUDIOMETA_API_KEY" > .audiometa-key
    echo "The tempo catalogue key is ready for the build"
elif [ "${CI_XCODEBUILD_ACTION:-}" = "archive" ]; then
    # A release without it would quietly lose online tempos.
    echo "error: AUDIOMETA_API_KEY is not set in this Xcode Cloud workflow" >&2
    exit 1
fi
# Above the builds uploaded from a Mac (1 to 3 so far): a build number can't be reused.
if [ "${CI_XCODEBUILD_ACTION:-}" = "archive" ]; then
    xcrun agvtool new-version -all "$(( CI_BUILD_NUMBER + 100 ))"
fi

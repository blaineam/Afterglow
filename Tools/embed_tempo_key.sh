#!/bin/sh
# Xcode build phase: writes the audiometa.io API key from this Mac's Keychain into the app, masked,
# so it is never in the repository. Without the Keychain item the app builds fine and just skips
# the online tempo lookup. To store the key (it asks for the value, and nothing is logged):
#   security add-generic-password -U -a "$USER" -s afterglow-audiometa-key -w
OUT="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/tempo-key.dat"
rm -f "$OUT"
# Xcode Cloud leaves it in a file (ci_scripts/ci_pre_xcodebuild.sh); a Mac has it in the Keychain.
if [ -f "$SRCROOT/.audiometa-key" ]; then
    KEY=$(cat "$SRCROOT/.audiometa-key")
else
    KEY=$(/usr/bin/security find-generic-password -a "$USER" -s afterglow-audiometa-key -w 2>/dev/null)
fi
if [ -z "$KEY" ]; then
    echo "note: no tempo catalogue key; this build skips the online tempo lookup"
    exit 0
fi
printf %s "$KEY" | /usr/bin/perl -pe 's/(.)/chr(ord($1) ^ 0x5A)/ges' > "$OUT"
echo "Embedded the tempo catalogue key"

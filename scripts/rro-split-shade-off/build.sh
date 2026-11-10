#!/bin/sh
# build.sh - compile the split-shade-off static RRO into a Magisk module zip.
# Prereq: Android SDK build-tools (tested with 34.0.0) and a debug keystore.
# The overlay flips com.android.systemui's config_use_split_notification_shade
# to false: full-screen top-down shade, so no background app band and no
# taskbar strip get re-rendered under the drawer animation.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
BT=${BT:-$HOME/Android/Sdk/build-tools/34.0.0}
PLATFORM=${PLATFORM:-$HOME/Android/Sdk/platforms/android-34/android.jar}
KS=${KS:-$HOME/.android/debug.keystore}
OUT=$HERE/out
rm -rf "$OUT"; mkdir -p "$OUT"

"$BT/aapt2" compile --dir "$HERE/res" -o "$OUT/res.zip"
"$BT/aapt2" link -o "$OUT/unsigned.apk" \
    --manifest "$HERE/AndroidManifest.xml" \
    -I "$PLATFORM" -R "$OUT/res.zip" \
    --auto-add-overlay --min-sdk-version 34 --target-sdk-version 34
"$BT/zipalign" -p 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"
"$BT/apksigner" sign --ks "$KS" --ks-pass pass:android --key-pass pass:android \
    --ks-key-alias androiddebugkey --out "$OUT/IfiveSplitShadeOffOverlay.apk" \
    "$OUT/aligned.apk"

# Fallback build (B): one APK per qualifier variant. aapt2 link with
# --auto-add-overlay does NOT merge several configs of the same resource name
# from command-line .flats (verified 2026-11-11: "failed to merge resource
# table", configCount stays 1 even with build-tools 36.1.0). If the device
# check `cmd overlay lookup` shows the base variant still wins, install this
# set instead: overlays are separate packages and each carries exactly one
# config, so all four participate in resolution by name+qualifier.
"$BT/aapt2" compile --dir "$HERE/res" -o "$OUT/res-split.zip"
mkdir -p "$OUT/split"
i=1
for v in values values-land values-sw600dp values-sw600dp-land; do
    rm -rf "$OUT/split/src$i"; mkdir -p "$OUT/split/src$i/res"
    cp -r "$HERE/res/$v" "$OUT/split/src$i/res/"
    sed 's/splitshadeoff/splitshadeoffPLACEHOLDER/' "$HERE/AndroidManifest.xml" \
        > "$OUT/split/src$i/AndroidManifest.xml"
    sed -i "s/PLACEHOLDER/$i/" "$OUT/split/src$i/AndroidManifest.xml"
    "$BT/aapt2" compile --dir "$OUT/split/src$i/res" -o "$OUT/split/r$i.zip"
    "$BT/aapt2" link -o "$OUT/split/u$i.apk" \
        --manifest "$OUT/split/src$i/AndroidManifest.xml" \
        -I "$PLATFORM" -R "$OUT/split/r$i.zip" \
        --auto-add-overlay --min-sdk-version 34 --target-sdk-version 34
    "$BT/zipalign" -p 4 "$OUT/split/u$i.apk" "$OUT/split/a$i.apk"
    "$BT/apksigner" sign --ks "$KS" --ks-pass pass:android --key-pass pass:android \
        --ks-key-alias androiddebugkey \
        --out "$OUT/split/IfiveSplitShadeOffOverlay-$i.apk" "$OUT/split/a$i.apk"
    i=$((i+1))
done

# module layout: module.prop at the zip root (magisk --install-module needs it)
MOD=$OUT/module
rm -rf "$MOD"; mkdir -p "$MOD/system/product/overlay"
cp "$OUT/IfiveSplitShadeOffOverlay.apk" "$MOD/system/product/overlay/"
cat > "$MOD/module.prop" <<'PROP'
id=ifive_splitshadeoff
name=iFive split-shade off (classic pull-down)
version=1.0
versionCode=1
author=leohearts
description=Forces the full-screen notification shade instead of the tablet left drawer. Removes the per-frame band redraws of the app behind and the taskbar that make the pull-down jank on RK3288.
PROP
(cd "$MOD" && zip -qr "$OUT/ifive-split-shade-off-module.zip" .)

echo "== overlay metadata check =="
"$BT/aapt2" dump badging "$OUT/IfiveSplitShadeOffOverlay.apk" | grep -a overlay || true
echo "module zip: $OUT/ifive-split-shade-off-module.zip"
sha256sum "$OUT/ifive-split-shade-off-module.zip" | sed 's/^/  /'

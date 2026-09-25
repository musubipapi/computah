#!/bin/zsh
set -eu
project_dir="${0:A:h:h}"
case "${1:-}" in
  "") ;;
  *) print -u2 'Usage: zsh scripts/build.sh'; exit 2 ;;
esac
cd "$project_dir"
swift build
app_dir="$project_dir/outputs/Computah.app"
# Replace generated resources so files from older builds cannot survive a rebuild.
rm -rf "$app_dir/Contents/Resources"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp .build/debug/Computah "$app_dir/Contents/MacOS/Computah"
ditto .build/debug/Computah_ComputahCore.bundle "$app_dir/Contents/Resources/Computah_ComputahCore.bundle"
ditto .build/debug/Computah_Computah.bundle "$app_dir/Contents/Resources/Computah_Computah.bundle"
python3 - "$app_dir/Contents/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as output:
    plistlib.dump({
        'CFBundleIdentifier': 'local.computah.v3',
        'CFBundleName': 'Computah',
        'CFBundleDisplayName': 'Computah',
        'CFBundleExecutable': 'Computah',
        'CFBundlePackageType': 'APPL',
        'LSUIElement': True,
        'NSHighResolutionCapable': True,
        'NSPrefersDisplaySafeAreaCompatibilityMode': False,
        'NSMicrophoneUsageDescription': 'Computah sends microphone audio to Deepgram while dictation is on.',
    }, output)
PY
# Retain the existing app identity so a rename does not intentionally reset macOS permissions.
signing_identity="${COMPUTAH_CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '$1 ~ /^[0-9]+\)$/ {print $2; exit}')}"
if [[ -z "$signing_identity" ]]; then signing_identity="-"; fi
codesign --force --sign "$signing_identity" --timestamp=none "$app_dir"
codesign --verify --strict "$app_dir"
print "Built $app_dir"

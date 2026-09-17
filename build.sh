#!/bin/zsh
set -eu
project_dir="${0:A:h}"
bundle_dir="$project_dir/outputs/Speech Test.app"
mkdir -p "$bundle_dir/Contents/MacOS"
xcrun swiftc -swift-version 5 -O "$project_dir/Sources/SpeechTest.swift" -o "$bundle_dir/Contents/MacOS/SpeechTest" -framework AppKit -framework AVFoundation -framework Security
cp "$project_dir/Sources/Info.plist" "$bundle_dir/Contents/Info.plist"
codesign --force --sign - "$bundle_dir"
"$bundle_dir/Contents/MacOS/SpeechTest" --self-test

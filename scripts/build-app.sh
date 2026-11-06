#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
app="$stage/AppleBooks2Folder.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Licenses"
for arch in arm64 x86_64; do
    triple="$arch-apple-macosx14.0"
    swift build -c release --product AppleBooks2Folder --triple "$triple" "$@"
    bin_dir=$(swift build -c release --show-bin-path --triple "$triple" "$@")
    cp "$bin_dir/AppleBooks2Folder" "$stage/$arch"
done
lipo -create "$stage/arm64" "$stage/x86_64" -output "$app/Contents/MacOS/AppleBooks2Folder"
cp scripts/Info.plist "$app/Contents/Info.plist"
cp -R scripts/Resources/. "$app/Contents/Resources/"
swift scripts/make-icon.swift "$app/Contents/Resources/AppIcon.icns" "$stage/AppleBooks2Folder-icon.png"
cp LICENSE "$app/Contents/Resources/Licenses/AppleBooks2Folder.txt"
cp Vendor/ZIPFoundation/LICENSE "$app/Contents/Resources/Licenses/ZIPFoundation.txt"
codesign --force --sign "${APPLEBOOKS_SIGN_IDENTITY:--}" --entitlements scripts/AppleBooks2Folder.entitlements "$app"
codesign --verify --deep --strict "$app"
ditto -c -k --norsrc --keepParent "$app" "$stage/AppleBooks2Folder-macOS.zip"
mkdir -p dist
cp "$stage/AppleBooks2Folder-macOS.zip" dist/AppleBooks2Folder-macOS.zip
cp "$stage/AppleBooks2Folder-icon.png" dist/AppleBooks2Folder-icon.png
printf '%s\n' "$PWD/dist/AppleBooks2Folder-macOS.zip"

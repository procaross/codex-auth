#!/bin/sh
# Build a universal, locally signed notification app next to the CLI executable.
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
output_dir=${1:-"$project_dir/zig-out/bin"}
mkdir -p "$output_dir"
output_dir=$(CDPATH= cd -- "$output_dir" && pwd)
app_path="$output_dir/Codex Auth.app"
staging_dir=$(mktemp -d "$output_dir/.notifier-build.XXXXXX")
trap 'rm -rf "$staging_dir"' EXIT HUP INT TERM
bundle="$staging_dir/Codex Auth.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources" "$staging_dir/AppIcon.iconset"
cp "$project_dir/native/macos/Info.plist" "$bundle/Contents/Info.plist"
for size in 16 32 128 256 512; do
  /usr/bin/sips -z "$size" "$size" "$project_dir/docs/assets/notification-icon.png" --out "$staging_dir/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  /usr/bin/sips -z "$double" "$double" "$project_dir/docs/assets/notification-icon.png" --out "$staging_dir/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$staging_dir/AppIcon.iconset" -o "$bundle/Contents/Resources/AppIcon.icns"
sdk_path=$(xcrun --sdk macosx --show-sdk-path)
for arch in arm64 x86_64; do
  xcrun swiftc -O -swift-version 5 -target "$arch-apple-macos12.0" -sdk "$sdk_path" \
    "$project_dir/native/macos/Notifier.swift" -o "$staging_dir/notifier-$arch" \
    -framework AppKit -framework UserNotifications
done
/usr/bin/lipo -create "$staging_dir/notifier-arm64" "$staging_dir/notifier-x86_64" -output "$bundle/Contents/MacOS/CodexAuthNotifier"
/usr/bin/codesign --force --sign - --timestamp=none "$bundle"
/usr/bin/codesign --verify --strict "$bundle"
# Preserve the previous app until the replacement is completely built and signed.
if [ -e "$app_path" ]; then mv "$app_path" "$staging_dir/previous.app"; fi
if ! mv "$bundle" "$app_path"; then
  if [ -e "$staging_dir/previous.app" ]; then mv "$staging_dir/previous.app" "$app_path"; fi
  exit 1
fi
printf 'Built %s\n' "$app_path"

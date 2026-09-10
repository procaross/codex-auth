#!/bin/sh
# Build a native macOS 26 menu bar companion. Does not change login files.
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
output_dir=${1:-"$project_dir/dist/menubar"}
cli_path=${2:-"$project_dir/zig-out/bin/codex-auth"}
if [ ! -x "$cli_path" ]; then
  printf 'Build this fork of codex-auth first, or supply its executable as argument 2.\n' >&2
  exit 1
fi
mkdir -p "$output_dir"
output_dir=$(CDPATH= cd -- "$output_dir" && pwd)
staging_dir=$(mktemp -d "$output_dir/.menubar-build.XXXXXX")
trap 'rm -rf "$staging_dir"' EXIT HUP INT TERM
bundle="$staging_dir/Codex Auth.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources" "$staging_dir/AppIcon.iconset"
cp "$project_dir/native/menubar/Info.plist" "$bundle/Contents/Info.plist"
cp "$project_dir/src/assets/portrait-64.txt" "$bundle/Contents/Resources/"
cp "$cli_path" "$bundle/Contents/Resources/codex-auth"
cp "$project_dir/LICENSE" "$bundle/Contents/Resources/LICENSE"
for size in 16 32 128 256 512; do
  /usr/bin/sips -z "$size" "$size" "$project_dir/docs/assets/notification-icon.png" --out "$staging_dir/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  /usr/bin/sips -z "$double" "$double" "$project_dir/docs/assets/notification-icon.png" --out "$staging_dir/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$staging_dir/AppIcon.iconset" -o "$bundle/Contents/Resources/AppIcon.icns"
sdk_path=$(xcrun --sdk macosx --show-sdk-path)
# The bundled CLI must match this architecture. Cross builds are explicit.
arch=${ARCH:-$(uname -m)}
/usr/bin/lipo "$cli_path" -verify_arch "$arch"
xcrun swiftc -O -swift-version 5 -target "$arch-apple-macos26.0" -sdk "$sdk_path" \
  "$project_dir"/native/menubar/*.swift -o "$bundle/Contents/MacOS/CodexAuthMenuBar" \
  -framework AppKit -framework SwiftUI -framework ServiceManagement
/usr/bin/codesign --force --sign - --timestamp=none "$bundle/Contents/Resources/codex-auth"
/usr/bin/codesign --force --sign - --timestamp=none "$bundle"
/usr/bin/codesign --verify --deep --strict "$bundle"
app_path="$output_dir/Codex Auth.app"
if [ -e "$app_path" ]; then mv "$app_path" "$staging_dir/previous.app"; fi
if ! mv "$bundle" "$app_path"; then
  if [ -e "$staging_dir/previous.app" ]; then mv "$staging_dir/previous.app" "$app_path"; fi
  exit 1
fi
printf 'Built %s\n' "$app_path"

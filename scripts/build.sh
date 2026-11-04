#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
# Compiler caches also need local filesystem semantics (atomic rename/index writes).
cache_key="$(printf '%s' "$PWD" | shasum -a 256 | cut -c 1-16)"
build_cache="${TURNSTYLE_BUILD_CACHE:-$HOME/Library/Caches/TurnSTYLE/SwiftPM/$cache_key}"
swift build --build-system native --scratch-path "$build_cache" -c release
bin_dir="$(swift build --build-system native --scratch-path "$build_cache" -c release --show-bin-path)"
# Signing on some mounted filesystems fails because of filesystem metadata.
# Assemble and sign a fresh bundle on the local disk, then export the result.
staging_dir="$(mktemp -d /private/tmp/turnstyle-build.XXXXXX)"
trap 'rm -rf "$staging_dir"' EXIT
app_dir="$staging_dir/TurnSTYLE.app"
mkdir -p "$PWD/dist"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Helpers" "$app_dir/Contents/Resources"
ditto --norsrc --noextattr --noacl "$bin_dir/TurnSTYLE" "$app_dir/Contents/MacOS/TurnSTYLE"
ditto --norsrc --noextattr --noacl "$bin_dir/turnstyle-hook" "$app_dir/Contents/Helpers/turnstyle-hook"
ditto --norsrc --noextattr --noacl scripts/remote-codex-bridge.py "$app_dir/Contents/Resources/remote-codex-bridge.py"
ditto --norsrc --noextattr --noacl LICENSE "$app_dir/Contents/Resources/LICENSE"
swift scripts/make-icon.swift "$staging_dir/TurnSTYLE.iconset"
iconutil -c icns "$staging_dir/TurnSTYLE.iconset" -o "$app_dir/Contents/Resources/AppIcon.icns"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>TurnSTYLE</string>
<key>CFBundleIdentifier</key><string>com.katinger.turnstyle</string>
<key>CFBundleName</key><string>TurnSTYLE</string>
<key>CFBundleDisplayName</key><string>TurnSTYLE</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.4.2</string>
<key>CFBundleVersion</key><string>6</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHumanReadableCopyright</key><string>TurnSTYLE · Local MVP</string>
</dict></plist>
PLIST
xattr -cr "$app_dir"
codesign --force --sign - "$app_dir/Contents/Helpers/turnstyle-hook"
codesign --force --sign - "$app_dir"
codesign --verify --deep --strict "$app_dir"
# The ZIP is the portable release artifact. Verify the exported bytes by
# extracting back onto local storage; mounted filesystems can taint app metadata.
archive_name="TurnSTYLE-0.4.2-macos-$(uname -m).zip"
ditto -c -k --norsrc --noextattr --noacl --keepParent "$app_dir" "$staging_dir/$archive_name"
cp "$staging_dir/$archive_name" "$PWD/dist/$archive_name"
rm -rf "$PWD/dist/TurnSTYLE.app"
mkdir -p "$staging_dir/verify"
ditto -x -k "$PWD/dist/$archive_name" "$staging_dir/verify"
codesign --verify --deep --strict "$staging_dir/verify/TurnSTYLE.app"
print "Packaged: $PWD/dist/$archive_name (ad-hoc signed; not notarized)"

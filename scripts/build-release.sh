#!/bin/zsh
# Builds build/Forkspaces.app and build/Forkspaces.dmg.
#   SIGN_IDENTITY  codesign identity for the app (default "-" = ad-hoc; e.g. "Developer ID Application: …")
#   BUILD_NUMBER   CFBundleVersion (default 1)
# Version comes from ./VERSION (Semantic Versioning).
set -eu
cd "${0:A:h:h}"
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
REPOSITORY_URL="https://github.com/gustavopmaia/forkspaces"
SRC=Sources/Forkspaces

rm -rf build/Forkspaces.app build/Forkspaces.dmg
mkdir -p .build/module-cache build
STAGE="$(mktemp -d "$PWD/build/.release.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/Forkspaces.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

COMMON=($SRC/Profile.swift $SRC/Icon.swift)
CORE=($COMMON $SRC/BundleBuilder.swift $SRC/ProfileStore.swift)
FLAGS=(-O -whole-module-optimization -target arm64-apple-macos13.0 -module-cache-path .build/module-cache)
swiftc $FLAGS $COMMON $SRC/Launcher.swift -o "$APP/Contents/Resources/ForkspacesLauncher"
swiftc $FLAGS $CORE $SRC/Tool.swift -o "$APP/Contents/Resources/ForkspacesTool"
swiftc $FLAGS $CORE $SRC/LoginRouting.swift $SRC/App.swift -o "$APP/Contents/MacOS/Forkspaces"
cp Resources/Space.entitlements Resources/Help.html "$APP/Contents/Resources/"
"$APP/Contents/Resources/ForkspacesTool" icon "$APP/Contents/Resources/Forkspaces.icns"

python3 - "$APP" "$VERSION" "$BUILD_NUMBER" "$REPOSITORY_URL" <<'PY'
import pathlib, plistlib, sys
app, version, build, repo = pathlib.Path(sys.argv[1]), *sys.argv[2:]
info = {'CFBundleIdentifier': 'dev.gustavomaia.forkspaces', 'CFBundleName': 'Forkspaces',
        'CFBundleDisplayName': 'Forkspaces', 'CFBundleExecutable': 'Forkspaces',
        'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': version, 'CFBundleVersion': build,
        'CFBundleIconFile': 'Forkspaces.icns', 'LSMinimumSystemVersion': '13.0',
        'NSHighResolutionCapable': True, 'NSPrincipalClass': 'NSApplication',
        'NSHumanReadableCopyright': 'Copyright © 2026 Gustavo Maia. Source-available.',
        'ForkspacesRepositoryURL': repo,
        'LSApplicationCategoryType': 'public.app-category.developer-tools'}
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
PY

# The launcher template is signed like the rest so the app can be notarized; each space's copy
# is re-signed ad-hoc on the user's Mac (BundleBuilder.codesign).
OPTS=(--force --sign "$SIGN_IDENTITY" --options runtime)
[[ "$SIGN_IDENTITY" == "-" ]] && OPTS+=(--timestamp=none) || OPTS+=(--timestamp)
codesign $OPTS "$APP/Contents/Resources/ForkspacesLauncher"
codesign $OPTS "$APP/Contents/Resources/ForkspacesTool"
codesign $OPTS "$APP"
codesign --verify --deep --strict "$APP"

mv "$APP" build/Forkspaces.app

# Drag-to-install disk image: Forkspaces.app next to an Applications shortcut.
DMG_ROOT="$STAGE/dmg"
mkdir -p "$DMG_ROOT"
ditto build/Forkspaces.app "$DMG_ROOT/Forkspaces.app"
ln -s /Applications "$DMG_ROOT/Applications"
hdiutil create -quiet -volname "Forkspaces $VERSION" -srcfolder "$DMG_ROOT" -fs HFS+ -format UDZO -ov build/Forkspaces.dmg
[[ "$SIGN_IDENTITY" == "-" ]] || codesign --force --sign "$SIGN_IDENTITY" --timestamp build/Forkspaces.dmg
hdiutil verify -quiet build/Forkspaces.dmg
print "Forkspaces $VERSION ($BUILD_NUMBER), signed with: $SIGN_IDENTITY"
print "  build/Forkspaces.app"
print "  build/Forkspaces.dmg"

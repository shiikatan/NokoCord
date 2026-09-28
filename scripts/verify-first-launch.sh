#!/bin/sh
# Interactive macOS smoke test: a new bundle identity must show its first window.
set -eu
cd "$(dirname "$0")/.."
work=$(mktemp -d "/private/tmp/nokocord-first-launch.XXXXXX")
pid=
trap 'if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || true; fi; rm -rf "$work"' EXIT
identity="com.shiikatan.nokocord.maomao.smoke.p$(uuidgen | tr 'A-Z' 'a-z' | cut -c1-12)"

if ! xcodebuild -project NokoCord.xcodeproj -scheme NokoCord -configuration Release \
    -destination 'platform=macOS' -derivedDataPath "$work/Derived" \
    NOKO_BUNDLE_ID="$identity" CODE_SIGN_IDENTITY=- build > "$work/build.log" 2>&1; then
    tail -40 "$work/build.log"
    exit 1
fi

app="$work/Derived/Build/Products/Release/NokoCord.app"
executable="$app/Contents/MacOS/NokoCord"
cat > "$work/visible-window.swift" <<'SWIFT'
import CoreGraphics
let pid = Int32(CommandLine.arguments[1])!
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let hasMainWindow = windows.contains { window in
    guard (window[kCGWindowOwnerPID as String] as? Int32) == pid,
          let bounds = window[kCGWindowBounds as String] as? [String: Int] else { return false }
    return (bounds["Width"] ?? 0) >= 900 && (bounds["Height"] ?? 0) >= 600
}
exit(hasMainWindow ? 0 : 1)
SWIFT

open -n -F -a "$app"
attempt=0
while [ "$attempt" -lt 15 ]; do
    pid=$(pgrep -f -x "$executable" | head -1 || true)
    if [ -n "$pid" ] && swift "$work/visible-window.swift" "$pid"; then
        echo "First-launch main window visible"
        exit 0
    fi
    attempt=$((attempt + 1))
    sleep 1
done
echo "First-launch main window did not appear" >&2
exit 1

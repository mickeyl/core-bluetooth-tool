#!/bin/bash
# LaunchServices supplies a GUI-session identity for macOS Bluetooth consent.
set -euo pipefail
cd "$(dirname "$0")/.."
bench_app="$PWD/.build/L2CAP Bench Reflector.app"
if [[ "${L2CAP_BENCH_REUSE_APP:-0}" != 1 ]]; then
    swift build -c release --disable-sandbox
    bench_bin_dir="$(swift build -c release --disable-sandbox --show-bin-path)"
fi
while read -r bench_old_pid; do
    bench_old_command="$(ps -p "$bench_old_pid" -o command=)"
    if [[ "$bench_old_command" == "$bench_app/Contents/MacOS/core-bluetooth-tool l2cap-reflect"* ]]; then
        kill -INT "$bench_old_pid"
        for ((bench_wait = 0; bench_wait < 20; bench_wait++)); do
            if ! kill -0 "$bench_old_pid" 2>/dev/null; then break; fi
            sleep 0.1
        done
        if kill -0 "$bench_old_pid" 2>/dev/null; then
            echo "Previous benchmark process is still stopping: $bench_old_pid" >&2
            exit 1
        fi
    fi
done < <(pgrep -f '/L2CAP Bench Reflector.app/Contents/MacOS/core-bluetooth-tool' || true)
if [[ "${L2CAP_BENCH_REUSE_APP:-0}" == 1 ]]; then
    test -x "$bench_app/Contents/MacOS/core-bluetooth-tool"
    codesign --verify "$bench_app"
else
mkdir -p "$bench_app/Contents/MacOS"
cp "$bench_bin_dir/core-bluetooth-tool" "$bench_app/Contents/MacOS/core-bluetooth-tool"
cat > "$bench_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>de.vanille.core-bluetooth-tool.l2cap-bench</string>
<key>CFBundleExecutable</key><string>core-bluetooth-tool</string>
<key>CFBundleName</key><string>L2CAP Bench Reflector</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSBluetoothAlwaysUsageDescription</key><string>Exchange L2CAP benchmark packets with the ESP test board.</string>
<key>NSBluetoothPeripheralUsageDescription</key><string>Publish the L2CAP benchmark reflector for the ESP test board.</string>
</dict></plist>
PLIST
bench_signing_identity="${L2CAP_BENCH_SIGNING_IDENTITY:--}"
codesign --force --sign "$bench_signing_identity" --identifier de.vanille.core-bluetooth-tool.l2cap-bench "$bench_app"
fi
bench_peer_log="${L2CAP_BENCH_LOG:-/tmp/l2cap-reflect-app.log}"
if [[ -s "$bench_peer_log" ]]; then
    bench_previous_log="$(mktemp "${bench_peer_log}.previous.XXXXXX")"
    cp "$bench_peer_log" "$bench_previous_log"
    echo "Previous reflector log: $bench_previous_log"
fi
touch "$bench_peer_log"
open -n --stdout "$bench_peer_log" --stderr "$bench_peer_log" "$bench_app" --args l2cap-reflect "$@"
echo "Reflector log: $bench_peer_log"

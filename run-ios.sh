#!/usr/bin/env bash
#
# run-ios.sh — launch the Spectre Flutter app on a connected iPhone against the
# dev relay, for an iPhone <-> desktop two-device test. Companion to
# run-macos.sh / run-linux.sh and spectre-relay/run-dev.sh.
#
# Sealed Sender is the only path: the app fetches + TOFU-pins the relay's CA
# key at startup and seals every message. No cleartext fallback.
#
# The iPhone can't use localhost — RELAY_HOST defaults to the LAN IP of the box
# running the relay (same default as run-macos.sh). Override:
#   RELAY_HOST=192.168.1.20 ./run-ios.sh
#   SPECTRE_RELAY_URL=ws://host:8080/ws ./run-ios.sh   # full override wins
#   IOS_DEVICE=<udid> ./run-ios.sh                     # pick a specific device
#
# PREREQS (one-time):
#   * iOS signing: open ios/Runner.xcworkspace in Xcode -> Runner target ->
#     Signing & Capabilities -> select your Apple ID team; trust the dev cert
#     on the phone (Settings -> General -> VPN & Device Management).
#   * The phone and the relay host must be on the same Wi-Fi/subnet, relay
#     port reachable (e.g. `sudo ufw allow 8080/tcp` on the relay box).
#   * iOS shows a one-time "allow local network" prompt on first connect — tap
#     allow (the app declares NSLocalNetworkUsageDescription / ATS local
#     networking in ios/Runner/Info.plist; DEV ONLY, see that file).
#
# --dart-define values are compile-time: changing them needs a full
# `flutter run` restart. Extra flags pass straight through (e.g. --release).
#
set -euo pipefail

# Resolve paths relative to this script so it works from any cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if ! command -v flutter >/dev/null 2>&1; then
  echo "error: flutter not found on PATH. Install Flutter, then re-run." >&2
  exit 1
fi

RELAY_HOST="${RELAY_HOST:-192.168.1.14}"
RELAY_PORT="${RELAY_PORT:-8080}"
RELAY_PATH="${RELAY_PATH:-/ws}"
RELAY_URL="${SPECTRE_RELAY_URL:-ws://${RELAY_HOST}:${RELAY_PORT}${RELAY_PATH}}"

if [[ "$RELAY_URL" != ws://* && "$RELAY_URL" != wss://* ]]; then
  echo "error: relay URL must be ws:// or wss:// (got: $RELAY_URL)" >&2
  exit 1
fi

# Target device: explicit IOS_DEVICE wins; otherwise auto-pick the first iOS
# device flutter reports. The --machine JSON is pretty-printed and lists "id"
# before "targetPlatform" within each device object, so track the most recent
# id and emit it when an ios targetPlatform line appears. Falls back to a
# friendly error so the run doesn't hang on the interactive device picker.
IOS_DEVICE="${IOS_DEVICE:-$(flutter devices --machine 2>/dev/null | awk -F'"' '
  /"id"[[:space:]]*:/ { id = $4 }
  /"targetPlatform"[[:space:]]*:[[:space:]]*"ios/ { print id; exit }
')}"

if [[ -z "$IOS_DEVICE" ]]; then
  echo "error: no iOS device found. Connect/unlock the iPhone and check 'flutter devices'." >&2
  echo "       (or set IOS_DEVICE=<udid> explicitly)" >&2
  exit 1
fi

echo "Launching Spectre on iPhone"
echo "  device:    ${IOS_DEVICE}"
echo "  relay url: ${RELAY_URL}  (sealed sender — CA pinned at startup)"
echo "  first run: set a signing team in Xcode (ios/Runner.xcworkspace) and"
echo "             allow the local-network prompt on the phone."
echo

# exec so Ctrl-C reaches flutter. Trailing "$@" forwards any extra run flags.
exec flutter run -d "$IOS_DEVICE" \
  --dart-define=SPECTRE_RELAY_URL="$RELAY_URL" \
  "$@"

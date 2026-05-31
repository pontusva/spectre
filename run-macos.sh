#!/usr/bin/env bash
#
# run-macos.sh — launch the Spectre Flutter app on macOS (desktop) against a
# dev relay, for local two-device testing. Companion to
# spectre-relay/run-dev.sh.
#
# Sealed Sender is the only path: the app fetches + TOFU-pins the relay's CA
# key at startup and seals every message. If the relay is unreachable on first
# run (no pinned CA yet), messaging stays disabled until it is — there is no
# cleartext fallback.
#
# The relay endpoint is built from parts so a shell-quoting slip can't mangle
# the --dart-define. Override:
#   RELAY_HOST=192.168.1.20 ./run-macos.sh
#   SPECTRE_RELAY_URL=ws://host:8080/ws ./run-macos.sh   # full override wins
#
# --dart-define values are compile-time: changing them needs a full
# `flutter run` restart (hot reload/restart r/R won't pick them up). Extra
# flags pass straight through, e.g. ./run-macos.sh --release
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

echo "Launching Spectre on macOS desktop"
echo "  relay url: ${RELAY_URL}  (sealed sender — CA pinned at startup)"
echo "  (first run / after schema changes: flutter pub get &&"
echo "   dart run build_runner build --delete-conflicting-outputs)"
echo

# exec so Ctrl-C reaches flutter. Trailing "$@" forwards any extra run flags.
exec flutter run -d macos \
  --dart-define=SPECTRE_RELAY_URL="$RELAY_URL" \
  "$@"

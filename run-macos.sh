#!/usr/bin/env bash
#
# run-macos.sh — launch the Spectre Flutter app on macOS (desktop) against a
# dev relay, for local two-device testing. Companion to
# spectre-relay/run-dev.sh.
#
# Defaults to the REAL Sealed Sender path (SPECTRE_DEV_ATTRIBUTION=false), to
# match run-linux.sh — if the two devices disagree on this flag, one side
# wraps a cleartext sender id while the other tries to open a sealed envelope,
# and every message is dropped. Keep them the same on both machines.
#
# DEV attribution (SPECTRE_DEV_ATTRIBUTION=true) wraps the sender id in
# CLEARTEXT on the wire so the receiver can attribute without Sealed Sender. It
# LEAKS the sender id to the relay and must NEVER ship in a production/activist
# build. If you use it, BOTH devices must set it.
#
# The relay endpoint is built from parts so a shell-quoting slip can't merge
# the two --dart-define flags (a backslash-escaped space once swallowed the
# second flag into the first, producing a malformed ws:// URL). Override:
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
DEV_ATTRIBUTION="${SPECTRE_DEV_ATTRIBUTION:-false}"

if [[ "$RELAY_URL" != ws://* && "$RELAY_URL" != wss://* ]]; then
  echo "error: relay URL must be ws:// or wss:// (got: $RELAY_URL)" >&2
  exit 1
fi

echo "Launching Spectre on macOS desktop"
echo "  relay url:       ${RELAY_URL}"
echo "  dev attribution: ${DEV_ATTRIBUTION} (false = real Sealed Sender)"
if [[ "$DEV_ATTRIBUTION" == "true" ]]; then
  echo "  WARNING: DEV attribution leaks the sender id in cleartext — local testing only."
fi
echo "  (first run / after schema changes: flutter pub get &&"
echo "   dart run build_runner build --delete-conflicting-outputs)"
echo

# exec so Ctrl-C reaches flutter. Trailing "$@" forwards any extra run flags.
exec flutter run -d macos \
  --dart-define=SPECTRE_RELAY_URL="$RELAY_URL" \
  --dart-define=SPECTRE_DEV_ATTRIBUTION="$DEV_ATTRIBUTION" \
  "$@"

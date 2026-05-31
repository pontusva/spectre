#!/usr/bin/env bash
#
# run-linux.sh — launch the Spectre Flutter app on Linux (desktop) against a
# dev relay. Companion to spectre-relay/run-dev.sh; see SEALED_SENDER_TEST.md
# for the full two-device checklist.
#
# Overridable from the environment:
#   SPECTRE_RELAY_URL        ws:// or wss:// relay endpoint (default localhost)
#   SPECTRE_DEV_ATTRIBUTION  true = insecure DEV cleartext sender wrapper
#                            (local testing only); false = real Sealed Sender
#
# Extra `flutter run` flags pass straight through, e.g.:
#   ./run-linux.sh --release
#   SPECTRE_RELAY_URL=ws://192.168.1.10:8080/ws ./run-linux.sh
#
set -euo pipefail

# Resolve paths relative to this script so it works from any cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if ! command -v flutter >/dev/null 2>&1; then
  echo "error: flutter not found on PATH. Install Flutter, then re-run." >&2
  exit 1
fi

# Built from parts (symmetric with run-macos.sh) so host/port can be overridden
# without re-typing the whole URL. localhost by default since the Linux box
# usually also runs the relay. A full SPECTRE_RELAY_URL override still wins.
RELAY_HOST="${RELAY_HOST:-localhost}"
RELAY_PORT="${RELAY_PORT:-8080}"
RELAY_PATH="${RELAY_PATH:-/ws}"
RELAY_URL="${SPECTRE_RELAY_URL:-ws://${RELAY_HOST}:${RELAY_PORT}${RELAY_PATH}}"
DEV_ATTRIBUTION="${SPECTRE_DEV_ATTRIBUTION:-false}"

if [[ "$RELAY_URL" != ws://* && "$RELAY_URL" != wss://* ]]; then
  echo "error: SPECTRE_RELAY_URL must be ws:// or wss:// (got: $RELAY_URL)" >&2
  exit 1
fi

echo "Launching Spectre on Linux desktop"
echo "  relay url:       ${RELAY_URL}"
echo "  dev attribution: ${DEV_ATTRIBUTION} (false = real Sealed Sender)"
if [[ "$DEV_ATTRIBUTION" == "true" ]]; then
  echo "  WARNING: DEV attribution leaks the sender id in cleartext — local testing only."
fi
echo "  (first run / after schema changes: flutter pub get &&"
echo "   dart run build_runner build --delete-conflicting-outputs)"
echo

# exec so Ctrl-C reaches flutter. Trailing "$@" forwards any extra run flags.
exec flutter run -d linux \
  --dart-define=SPECTRE_RELAY_URL="$RELAY_URL" \
  --dart-define=SPECTRE_DEV_ATTRIBUTION="$DEV_ATTRIBUTION" \
  "$@"

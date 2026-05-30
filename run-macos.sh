#!/usr/bin/env bash
#
# Launch Spectre on macOS for local two-device testing.
#
# Why this script exists: the relay URL and the dev-attribution flag are
# passed as separate --dart-define values. Typing them by hand has repeatedly
# led to a shell-quoting mistake (a backslash-escaped space) that swallows the
# second flag into the first value, producing a malformed ws:// URL. Each flag
# below is on its own line as its own argument, so that can't happen.
#
# RELAY_HOST defaults to the LAN IP last used; override inline, e.g.
#   RELAY_HOST=192.168.1.20 ./run-macos.sh
#
# DEV ATTRIBUTION (SPECTRE_DEV_ATTRIBUTION=true) wraps the sender id in
# CLEARTEXT on the wire so the receiver can attribute messages before Sealed
# Sender is wired. It LEAKS the sender id to the relay and must NEVER ship in a
# production/activist build. Both the sender and receiver devices must run with
# this flag for attribution to work.
#
# Note: --dart-define values are compile-time constants. Changing them requires
# a full restart of `flutter run` — hot reload/restart (r/R) will not pick them
# up.
set -euo pipefail

RELAY_HOST="${RELAY_HOST:-192.168.1.14}"
RELAY_PORT="${RELAY_PORT:-8080}"
RELAY_PATH="${RELAY_PATH:-/ws}"

RELAY_URL="ws://${RELAY_HOST}:${RELAY_PORT}${RELAY_PATH}"
echo "Launching Spectre -> relay ${RELAY_URL} (dev sender attribution ON)"

exec flutter run -d macos \
  --dart-define=SPECTRE_RELAY_URL="${RELAY_URL}" \
  --dart-define=SPECTRE_DEV_ATTRIBUTION=true

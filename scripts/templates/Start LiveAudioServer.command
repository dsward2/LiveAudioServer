#!/usr/bin/env bash
#
# Double-click this file to start LiveAudioServer with defaults tuned for the
# Gqrx + RTL-SDR + iPhone listening use case:
#
#   - Listens for 48 kHz stereo s16le PCM on UDP port 7355 (Gqrx's default
#     "UDP output" port).
#   - Advertises the streams on the LAN under your Mac's name so iPhone /
#     iPad / other Macs on the same network can discover them via Bonjour.
#   - Serves on HTTP port 8080.
#
# Press Control-C in this window (or close the window) to stop the server.
#
# To change settings, open this file in a text editor and edit the LAS_*
# variables below. The available flags are documented at:
#   https://github.com/dsward2/LiveAudioServer
#

set -euo pipefail

# Defaults — edit these if needed.
LAS_PORT=8080
LAS_UDP_PORT=7355
LAS_RATE=48000
LAS_CHANNELS=2
LAS_BONJOUR_NAME="$(scutil --get ComputerName 2>/dev/null || hostname -s)"

# Find the bundled binary that lives next to this launcher.
DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="${DIR}/liveaudioserver"

if [[ ! -x "${BIN}" ]]; then
    echo "ERROR: ${BIN} not found or not executable."
    echo "This launcher must stay in the same folder as the 'liveaudioserver' binary."
    echo
    read -r -p "Press Return to close this window."
    exit 1
fi

clear
cat <<EOF
================================================================
  LiveAudioServer — streaming on http://$(hostname -s).local:${LAS_PORT}/
================================================================

  Send 16-bit little-endian PCM to UDP port ${LAS_UDP_PORT}
  (e.g. point Gqrx's "UDP output" at this Mac).

  Open one of these URLs to listen:
    Mac / iPhone Safari:  http://$(hostname -s).local:${LAS_PORT}/
    VLC (MP3):            http://$(hostname -s).local:${LAS_PORT}/stream.mp3
    VLC (AAC):            http://$(hostname -s).local:${LAS_PORT}/stream.m4a

  Press Control-C (or close this window) to stop.
================================================================

EOF

exec "${BIN}" \
    --port "${LAS_PORT}" \
    --udp-input-port "${LAS_UDP_PORT}" \
    --rate "${LAS_RATE}" \
    --channels "${LAS_CHANNELS}" \
    --bonjour "${LAS_BONJOUR_NAME}" \
    --keep-alive

#!/usr/bin/env bash
set -euo pipefail

# mac_wrapper.sh
# Simple macOS-side wrapper to run the ThermalHeatmap binary on an uploaded file.
# Place this script on the macOS target (for the SSH account used by the uploader),
# make it executable and adjust `THERMAL_BIN` if needed.
# Usage (remote): /usr/local/bin/mac_wrapper.sh /path/to/uploaded/file

FILE="$1"
THERMAL_BIN="${THERMAL_BIN:-$HOME/ThermalHeatmap}"
OUT_DIR="${OUT_DIR:-$HOME/thermal_outputs}"

mkdir -p "$OUT_DIR"

BASENAME=$(basename "$FILE")
NAME="${BASENAME%.*}"

echo "[mac_wrapper] Processing $FILE -> $OUT_DIR"

if [ -x "$THERMAL_BIN" ]; then
  # Example invocation — adjust flags to match your local ThermalHeatmap CLI
  "$THERMAL_BIN" -i "$FILE" -o "$OUT_DIR/${NAME}_heatmap.mov" --summary "$OUT_DIR/${NAME}_summary.json"
  EXIT_CODE=$?
  echo "[mac_wrapper] ThermalHeatmap exited with $EXIT_CODE"
  exit $EXIT_CODE
else
  echo "[mac_wrapper] ThermalHeatmap binary not found or not executable at: $THERMAL_BIN" >&2
  ls -l "$THERMAL_BIN" || true
  exit 2
fi

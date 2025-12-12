#!/usr/bin/env bash
set -euo pipefail

# Helper to run the uploader Docker image locally on macOS/Linux.
# Usage:
#   MAC_HOST=your.mac.host MAC_USER=youruser ./scripts/run_local.sh [host_port] [image]
# Defaults: host_port=8081, image=thermo-uploader:local

PORT=${1:-8081}
IMAGE=${2:-thermo-uploader:local}

if [ -z "${MAC_HOST:-}" ] || [ -z "${MAC_USER:-}" ]; then
  echo "Error: set MAC_HOST and MAC_USER environment variables."
  echo "Example: MAC_HOST=mac.example.com MAC_USER=vincent ./scripts/run_local.sh 8081"
  exit 1
fi

KEY_FILE="${SSH_KEY_FILE:-$HOME/.ssh/id_rsa}"
if [ ! -f "$KEY_FILE" ]; then
  echo "SSH key not found at $KEY_FILE" >&2
  exit 1
fi

# Cross-platform base64 (macOS base64 doesn't accept -w)
if base64 --version >/dev/null 2>&1; then
  # GNU coreutils
  KEY_B64=$(base64 -w0 "$KEY_FILE")
else
  # macOS / BSD
  KEY_B64=$(base64 "$KEY_FILE" | tr -d '\n')
fi

echo "Starting container '$IMAGE' mapping host port $PORT -> container 8080"

docker run --rm -p "${PORT}:8080" \
  -e MAC_HOST="$MAC_HOST" \
  -e MAC_USER="$MAC_USER" \
  -e MAC_SSH_KEY_BASE64="$KEY_B64" \
  -e POST_PROCESS_CMD="${POST_PROCESS_CMD:-/usr/local/bin/mac_wrapper.sh %REMOTE_PATH%}" \
  "$IMAGE"

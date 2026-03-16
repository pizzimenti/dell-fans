#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_DIR="$ROOT_DIR/services/dell-fan-policy"

if [[ ! -f "$SERVICE_DIR/setup.sh" ]]; then
    echo "ERROR: Expected installer at $SERVICE_DIR/setup.sh"
    exit 1
fi

exec bash "$SERVICE_DIR/setup.sh"

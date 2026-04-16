#!/bin/bash
# =============================================================================
# Configuration for extract-insight-action Infrastructure Deployment (Linux/macOS)
#
# Reads variables from env.config and exports them.
# Source this file before running deployment scripts:
#   source config.env
#   ./deploy-infrastructure.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/env.config"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "[ERROR] env.config not found at $CONFIG_FILE"
    return 1 2>/dev/null || exit 1
fi

while IFS='=' read -r key value; do
    # Skip blank lines and comments
    key=$(echo "$key" | xargs)
    [ -z "$key" ] && continue
    [[ "$key" == \#* ]] && continue
    # Strip surrounding quotes from value
    value=$(echo "$value" | xargs | sed 's/^"\(.*\)"$/\1/')
    export "$key=$value"
done < "$CONFIG_FILE"

echo "[INFO] Environment variables loaded from env.config"

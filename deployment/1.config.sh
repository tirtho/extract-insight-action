#!/usr/bin/env bash
# =============================================================================
# Configuration for extract-insight-action Infrastructure Deployment (bash)
#
# Reads variables from a selected config file (default: env.config) and exports them, then prompts for the
# deployment suffix to derive AZURE_KEY_VAULT_URL.
#
# Source this file before running deployment scripts:
#   source ./1.config.sh
#   ./2.deploy-infrastructure.sh <suffix>
# =============================================================================

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
DEFAULT_CONFIG_FILE_NAME="env.config"
read -r -p "Enter config file name [$DEFAULT_CONFIG_FILE_NAME]: " CONFIG_FILE_INPUT
if [[ -z "${CONFIG_FILE_INPUT// }" ]]; then
    CONFIG_FILE_NAME="$DEFAULT_CONFIG_FILE_NAME"
else
    CONFIG_FILE_NAME="$CONFIG_FILE_INPUT"
fi

if [[ "$CONFIG_FILE_NAME" = /* || "$CONFIG_FILE_NAME" =~ ^[A-Za-z]:[\\/].* ]]; then
    CONFIG_FILE="$CONFIG_FILE_NAME"
else
    CONFIG_FILE="$SCRIPT_DIR/$CONFIG_FILE_NAME"
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "[ERROR] Config file '$CONFIG_FILE_NAME' not found at $CONFIG_FILE" >&2
    return 1 2>/dev/null || exit 1
fi

LOADED_VARS=()
while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"   # ltrim
    line="${line%"${line##*[![:space:]]}"}"   # rtrim
    [[ -z "$line" || "$line" == \#* ]] && continue
    if [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
        name="${BASH_REMATCH[1]// /}"
        value="${BASH_REMATCH[2]}"
        # strip surrounding quotes
        value="${value#\"}"; value="${value%\"}"
        export "$name=$value"
        LOADED_VARS+=("$name")
    fi
done < "$CONFIG_FILE"

echo "[INFO] Loaded ${#LOADED_VARS[@]} environment variable(s) from $CONFIG_FILE_NAME:"
for n in "${LOADED_VARS[@]}"; do
    echo "  $n = ${!n}"
done

# =============================================================================
# Prompt for suffix and derive AZURE_KEY_VAULT_URL
# =============================================================================
PROJECT_NAME="${PROJECT_NAME:-eia}"
ENVIRONMENT="${ENVIRONMENT:-dev}"

read -r -p "Enter deployment suffix (e.g. 1): " SUFFIX
if [[ -z "$SUFFIX" ]]; then
    echo "[ERROR] Suffix is required." >&2
    return 1 2>/dev/null || exit 1
fi

KEY_VAULT_NAME="kv-${PROJECT_NAME}-${ENVIRONMENT}-${SUFFIX}"
export SUFFIX
export KEY_VAULT_NAME
export AZURE_KEY_VAULT_URL="https://${KEY_VAULT_NAME}.vault.azure.net"

echo "[OK] SUFFIX                = $SUFFIX"
echo "[OK] KEY_VAULT_NAME        = $KEY_VAULT_NAME"
echo "[OK] AZURE_KEY_VAULT_URL   = $AZURE_KEY_VAULT_URL"

# =============================================================================
# Generate env.bat in the repo root (AZURE_KEY_VAULT_URL for tools that source env.bat)
# =============================================================================
REPO_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"
ENV_BAT="$REPO_ROOT/env.bat"
{
    printf '@echo off\r\n'
    printf 'set AZURE_KEY_VAULT_URL=%s\r\n' "$AZURE_KEY_VAULT_URL"
    printf 'set AI_FOUNDRY_REASONING_EFFORT=medium\r\n'
    printf 'set AGENT_CONVERSATION_TTL_HOURS=168\r\n'
} > "$ENV_BAT"
echo "[OK] Wrote $ENV_BAT"

# Detect if the script was sourced. If executed (not sourced), warn the user
# that the variables won't persist in the parent shell.
(return 0 2>/dev/null) || {
    echo ""
    echo "[WARNING] This script was not sourced. The environment variables" >&2
    echo "          will be lost when this script exits." >&2
    echo "          Re-run with:  source ./1.config.sh" >&2
}

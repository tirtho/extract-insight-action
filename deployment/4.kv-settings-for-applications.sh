#!/bin/bash
# =============================================================================
# Sets application configuration secrets in Azure Key Vault.
#
# Stores application settings as Key Vault secrets for use by Function Apps
# and other services. Idempotent - can be run multiple times safely.
#
# Usage:
#   ./kv-settings-for-applications.sh <suffix>
#
# Example:
#   ./kv-settings-for-applications.sh 999
# =============================================================================

set -euo pipefail

# =============================================================================
# ARGUMENTS
# =============================================================================
if [ -z "${1:-}" ]; then
    echo "[ERROR] Suffix is required. Usage: $0 <suffix>"
    exit 1
fi
SUFFIX="$1"

# =============================================================================
# CONFIGURATION
# =============================================================================
PROJECT_NAME="${PROJECT_NAME:-eia}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
KEY_VAULT_NAME="${KEY_VAULT_NAME:-kv-${PROJECT_NAME}-${ENVIRONMENT}-${SUFFIX}}"

# Resolve environment-sourced values
# USER_EMAIL_ADDRESS is required for the application to function
if [ -z "${USER_EMAIL_ADDRESS:-}" ]; then
    echo "[ERROR] USER_EMAIL_ADDRESS environment variable is not set."
    exit 1
fi

MAILBOX_POLLING_SCHEDULE="${MAILBOX_POLLING_SCHEDULE:-0 */5 * * * *}"
POLLING_MAILBOX_NAME="${POLLING_MAILBOX_NAME:-Inbox}"
READ_MAILBOX_FOR_PAST_N_SECONDS="${READ_MAILBOX_FOR_PAST_N_SECONDS:-60}"

# =============================================================================
# HELPER FUNCTION
# =============================================================================
set_keyvault_secret() {
    local vault_name="$1"
    local secret_name="$2"
    local secret_value="$3"

    echo "[INFO] Setting Key Vault secret: $secret_name"
    if az keyvault secret set --vault-name "$vault_name" --name "$secret_name" --value "$secret_value" --output none 2>&1; then
        echo "[OK]   Secret '$secret_name' set successfully."
        return 0
    else
        echo "[ERROR] Failed to set secret '$secret_name'"
        return 1
    fi
}

# =============================================================================
# SET KEY VAULT SECRETS
# =============================================================================
echo ""
echo "[INFO] ============================================================"
echo "[INFO] Setting application secrets in Key Vault: $KEY_VAULT_NAME"
echo "[INFO] ============================================================"
echo ""

ALL_SUCCEEDED=true

set_keyvault_secret "$KEY_VAULT_NAME" "ReadMailboxForPastNSeconds" "$READ_MAILBOX_FOR_PAST_N_SECONDS" || ALL_SUCCEEDED=false
set_keyvault_secret "$KEY_VAULT_NAME" "MailboxPollingSchedule" "$MAILBOX_POLLING_SCHEDULE" || ALL_SUCCEEDED=false
set_keyvault_secret "$KEY_VAULT_NAME" "UserEmailAddress" "$USER_EMAIL_ADDRESS" || ALL_SUCCEEDED=false
set_keyvault_secret "$KEY_VAULT_NAME" "PollingMailboxName" "$POLLING_MAILBOX_NAME" || ALL_SUCCEEDED=false

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
if [ "$ALL_SUCCEEDED" = true ]; then
    echo "[INFO] All Key Vault secrets set successfully."
else
    echo "[WARN] One or more secrets failed to set. Review the output above."
    exit 1
fi

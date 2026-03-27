#!/bin/bash
# =============================================================================
# Rotate Graph API Client Secret
#
# Removes all existing client credentials from the Entra ID app registration,
# creates a new client secret, and stores it in Key Vault. Designed to be run
# periodically before the current secret expires.
#
# Usage:
#   chmod +x rotate-graph-api-secret.sh
#   ./rotate-graph-api-secret.sh <suffix> [expiry_years]
#   ./rotate-graph-api-secret.sh 999
#   ./rotate-graph-api-secret.sh 999 1
# =============================================================================

set -euo pipefail

# =============================================================================
# REQUIRED ARGUMENT: Suffix
# =============================================================================
if [ -z "${1:-}" ]; then
    echo "Usage: $0 <suffix> [expiry_years]"
    echo "  <suffix>        Required. The same suffix used when running deploy-infrastructure.sh."
    echo "  [expiry_years]  Optional. Number of years until the new secret expires (1-5). Default: 2."
    echo ""
    echo "Example: $0 999"
    echo "         $0 999 1"
    exit 1
fi
SUFFIX="$1"
EXPIRY_YEARS="${2:-2}"

# Validate expiry years
if ! [[ "$EXPIRY_YEARS" =~ ^[1-5]$ ]]; then
    echo -e "\033[0;31m[ERROR] expiry_years must be between 1 and 5. Got: $EXPIRY_YEARS\033[0m"
    exit 1
fi

# =============================================================================
# CONFIGURATION (must match deploy-infrastructure.sh)
# =============================================================================
PROJECT_NAME="${PROJECT_NAME:-eia}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
KEY_VAULT_NAME="${KEY_VAULT_NAME:-kv-${PROJECT_NAME}-${ENVIRONMENT}-${SUFFIX}}"
GRAPH_APP_NAME="${GRAPH_APP_NAME:-${PROJECT_NAME}-graph-api-${ENVIRONMENT}}"

# =============================================================================
# BANNER
# =============================================================================
echo ""
echo -e "\033[0;36m============================================\033[0m"
echo -e "\033[0;36m  Rotate Graph API Client Secret\033[0m"
echo -e "\033[0;36m============================================\033[0m"
echo ""
echo "App registration : $GRAPH_APP_NAME"
echo "Key Vault        : $KEY_VAULT_NAME"
echo "Expiry           : $EXPIRY_YEARS year(s)"
echo ""

# =============================================================================
# VERIFY AZURE CLI LOGIN
# =============================================================================
echo "Verifying Azure CLI session..."
ACCOUNT_NAME=$(az account show --query name -o tsv 2>/dev/null || echo "")
ACCOUNT_USER=$(az account show --query user.name -o tsv 2>/dev/null || echo "")
if [ -z "$ACCOUNT_NAME" ]; then
    echo -e "\033[0;31m[ERROR] Not logged in to Azure CLI. Run 'az login' first.\033[0m"
    exit 1
fi
echo "Logged in as: $ACCOUNT_USER (Subscription: $ACCOUNT_NAME)"

# =============================================================================
# LOOK UP APP REGISTRATION
# =============================================================================
echo ""
echo "Looking up app registration: $GRAPH_APP_NAME ..."
GRAPH_CLIENT_ID=$(az ad app list --display-name "$GRAPH_APP_NAME" --query "[0].appId" -o tsv 2>/dev/null || echo "")
if [ -z "$GRAPH_CLIENT_ID" ]; then
    echo -e "\033[0;31m[ERROR] App registration '$GRAPH_APP_NAME' not found. Run deploy-infrastructure.sh first.\033[0m"
    exit 1
fi
echo -e "\033[0;32mFound app registration: $GRAPH_CLIENT_ID\033[0m"

# =============================================================================
# VERIFY KEY VAULT ACCESS
# =============================================================================
echo ""
echo "Verifying Key Vault access: $KEY_VAULT_NAME ..."
KV_CHECK=$(az keyvault show --name "$KEY_VAULT_NAME" --query name -o tsv 2>/dev/null || echo "")
if [ -z "$KV_CHECK" ]; then
    echo -e "\033[0;31m[ERROR] Key Vault '$KEY_VAULT_NAME' not found or not accessible.\033[0m"
    exit 1
fi
echo -e "\033[0;32mKey Vault accessible\033[0m"

# =============================================================================
# SHOW CURRENT CREDENTIALS
# =============================================================================
echo ""
echo "Checking existing credentials..."
CREDS_JSON=$(az ad app credential list --id "$GRAPH_CLIENT_ID" -o json 2>/dev/null || echo "[]")
CRED_COUNT=$(echo "$CREDS_JSON" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

if [ "$CRED_COUNT" -gt 0 ]; then
    echo "  Found $CRED_COUNT existing credential(s):"
    echo "$CREDS_JSON" | python3 -c "
import sys, json
creds = json.load(sys.stdin)
for c in creds:
    end = c.get('endDateTime', 'unknown')
    print(f'    - KeyId: {c[\"keyId\"]}  Expires: {end}')
" 2>/dev/null || echo "  (could not parse credential details)"
else
    echo -e "\033[0;33m  No existing credentials found\033[0m"
fi

# =============================================================================
# CONFIRM ROTATION
# =============================================================================
echo ""
echo -e "\033[0;33m[WARNING] This will:\033[0m"
echo -e "\033[0;33m  1. Remove ALL existing client secrets from the app registration\033[0m"
echo -e "\033[0;33m  2. Create a new client secret (valid for $EXPIRY_YEARS year(s))\033[0m"
echo -e "\033[0;33m  3. Update the 'GraphClientSecret' secret in Key Vault\033[0m"
echo ""
echo -e "\033[0;33mAny application using the current secret will need to pick up the\033[0m"
echo -e "\033[0;33mnew value from Key Vault after rotation completes.\033[0m"
echo ""

read -r -p "Proceed with secret rotation? (y/N) " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]([Ee][Ss])?$ ]]; then
    echo ""
    echo -e "\033[0;33m[ABORTED] No changes were made.\033[0m"
    exit 0
fi

# =============================================================================
# STEP 1: REMOVE OLD CREDENTIALS
# =============================================================================
echo ""
echo -e "\033[0;36m[Step 1/3] Removing existing credentials...\033[0m"

if [ "$CRED_COUNT" -gt 0 ]; then
    KEY_IDS=$(echo "$CREDS_JSON" | python3 -c "
import sys, json
creds = json.load(sys.stdin)
for c in creds:
    print(c['keyId'])
" 2>/dev/null || echo "")

    for KEY_ID in $KEY_IDS; do
        echo "  Removing credential: $KEY_ID"
        if ! az ad app credential delete --id "$GRAPH_CLIENT_ID" --key-id "$KEY_ID" 2>/dev/null; then
            echo -e "\033[0;31m  [ERROR] Failed to remove credential $KEY_ID\033[0m"
            exit 1
        fi
    done
    echo -e "\033[0;32m  All existing credentials removed\033[0m"
else
    echo "  No credentials to remove"
fi

# =============================================================================
# STEP 2: CREATE NEW SECRET
# =============================================================================
echo ""
echo -e "\033[0;36m[Step 2/3] Creating new client secret (expires in $EXPIRY_YEARS year(s))...\033[0m"

NEW_SECRET=$(az ad app credential reset --id "$GRAPH_CLIENT_ID" \
    --display-name "extract-insight-action-secret" \
    --years "$EXPIRY_YEARS" \
    --query password -o tsv 2>/dev/null || echo "")

if [ -z "$NEW_SECRET" ]; then
    echo -e "\033[0;31m[ERROR] Failed to create new client secret.\033[0m"
    exit 1
fi

echo -e "\033[0;32m  New client secret created successfully\033[0m"

# =============================================================================
# STEP 3: UPDATE KEY VAULT
# =============================================================================
echo ""
echo -e "\033[0;36m[Step 3/3] Updating Key Vault secret 'GraphClientSecret'...\033[0m"

if ! az keyvault secret set --vault-name "$KEY_VAULT_NAME" \
    --name "GraphClientSecret" \
    --value "$NEW_SECRET" \
    --output none 2>/dev/null; then
    echo -e "\033[0;31m[ERROR] Failed to update Key Vault secret.\033[0m"
    echo ""
    echo -e "\033[0;31m[CRITICAL] The new secret was created in Entra ID but NOT saved to Key Vault.\033[0m"
    echo -e "\033[0;31mYou must manually store the secret in Key Vault:\033[0m"
    echo -e "\033[0;33m  az keyvault secret set --vault-name $KEY_VAULT_NAME --name GraphClientSecret --value '<secret>'\033[0m"
    exit 1
fi

echo -e "\033[0;32m  Key Vault secret updated successfully\033[0m"

# =============================================================================
# VERIFY
# =============================================================================
echo ""
echo "Verifying rotation..."

KV_UPDATED=$(az keyvault secret show --vault-name "$KEY_VAULT_NAME" \
    --name "GraphClientSecret" --query "attributes.updated" -o tsv 2>/dev/null || echo "")
if [ -n "$KV_UPDATED" ]; then
    echo "  Key Vault secret last updated: $KV_UPDATED"
fi

CRED_EXPIRY=$(az ad app credential list --id "$GRAPH_CLIENT_ID" \
    --query "[0].endDateTime" -o tsv 2>/dev/null || echo "")
if [ -n "$CRED_EXPIRY" ]; then
    echo "  Entra ID credential expires:   $CRED_EXPIRY"
fi

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
echo -e "\033[0;32m[SUCCESS] Graph API client secret rotation complete\033[0m"
echo ""
echo "  App registration : $GRAPH_APP_NAME ($GRAPH_CLIENT_ID)"
echo "  Key Vault        : $KEY_VAULT_NAME"
echo "  Secret name      : GraphClientSecret"
echo ""
echo -e "\033[0;36m[INFO] Applications using Key Vault references will pick up the new\033[0m"
echo -e "\033[0;36m       secret automatically. If any service caches the secret value,\033[0m"
echo -e "\033[0;36m       restart it to force a refresh.\033[0m"
echo ""

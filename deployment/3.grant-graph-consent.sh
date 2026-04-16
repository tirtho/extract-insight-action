#!/bin/bash
# =============================================================================
# Grant Admin Consent for Graph API Permissions
#
# Grants admin consent for the Graph API application permissions configured
# by deploy-infrastructure.sh. Requires Global Administrator or Privileged
# Role Administrator role in the Azure AD tenant.
#
# Usage:
#   chmod +x grant-graph-consent.sh
#   ./grant-graph-consent.sh <suffix>
#   ./grant-graph-consent.sh 999
# =============================================================================

set -euo pipefail

# =============================================================================
# REQUIRED ARGUMENT: Suffix
# =============================================================================
if [ -z "${1:-}" ]; then
    echo "Usage: $0 <suffix>"
    echo "  <suffix>  Required. The same suffix used when running deploy-infrastructure.sh."
    echo ""
    echo "Example: $0 999"
    exit 1
fi
SUFFIX="$1"

# =============================================================================
# CONFIGURATION (must match deploy-infrastructure.sh)
# =============================================================================
PROJECT_NAME="${PROJECT_NAME:-eia}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
GRAPH_APP_NAME="${GRAPH_APP_NAME:-${PROJECT_NAME}-graph-api-${ENVIRONMENT}}"

# =============================================================================
# PRE-FLIGHT: Confirm tenant admin role
# =============================================================================
echo ""
echo -e "\033[0;36m============================================\033[0m"
echo -e "\033[0;36m  Grant Admin Consent for Graph API\033[0m"
echo -e "\033[0;36m============================================\033[0m"
echo ""
echo "This script grants admin consent for the Graph API permissions"
echo "configured on app registration: $GRAPH_APP_NAME"
echo ""
echo -e "\033[0;33m[IMPORTANT] This operation requires one of the following Azure AD roles:\033[0m"
echo -e "\033[0;33m  - Global Administrator\033[0m"
echo -e "\033[0;33m  - Privileged Role Administrator\033[0m"
echo ""

read -r -p "Do you have one of these tenant admin roles? (y/N) " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]([Ee][Ss])?$ ]]; then
    echo ""
    echo -e "\033[0;33m[ABORTED] Please ask a tenant admin to run this script, or grant consent manually:\033[0m"
    echo -e "\033[0;36m  Azure Portal > App registrations > $GRAPH_APP_NAME > API permissions > Grant admin consent\033[0m"
    exit 0
fi

# =============================================================================
# Verify Azure CLI login
# =============================================================================
echo ""
echo "Verifying Azure CLI session..."
ACCOUNT_NAME=$(az account show --query name -o tsv 2>/dev/null || echo "")
ACCOUNT_USER=$(az account show --query user.name -o tsv 2>/dev/null || echo "")
if [ -z "$ACCOUNT_NAME" ]; then
    echo -e "\033[0;31m[ERROR] Not logged in to Azure CLI. Run 'az login' first.\033[0m"
    exit 1
fi
echo "Logged in as: $ACCOUNT_USER (Subscription: $ACCOUNT_NAME)"

# =============================================================================
# Look up the app registration
# =============================================================================
echo ""
echo "Looking up app registration: $GRAPH_APP_NAME ..."
GRAPH_CLIENT_ID=$(az ad app list --display-name "$GRAPH_APP_NAME" --query "[0].appId" -o tsv 2>/dev/null || echo "")
if [ -z "$GRAPH_CLIENT_ID" ]; then
    echo -e "\033[0;31m[ERROR] App registration '$GRAPH_APP_NAME' not found. Run deploy-infrastructure.sh first.\033[0m"
    exit 1
fi
echo "Found app registration: $GRAPH_CLIENT_ID"

# =============================================================================
# Ensure service principal exists (required for consent)
# =============================================================================
echo ""
echo "Ensuring service principal exists..."
APP_SP_ID=$(az ad sp show --id "$GRAPH_CLIENT_ID" --query id -o tsv 2>/dev/null || echo "")
if [ -z "$APP_SP_ID" ]; then
    echo "Creating service principal for app registration..."
    APP_SP_ID=$(az ad sp create --id "$GRAPH_CLIENT_ID" --query id -o tsv 2>&1)
    if [ -z "$APP_SP_ID" ] || [ $? -ne 0 ]; then
        echo -e "\033[0;31m[ERROR] Failed to create service principal: $APP_SP_ID\033[0m"
        exit 1
    fi
    echo "Service principal created: $APP_SP_ID"
else
    echo "Service principal already exists: $APP_SP_ID"
fi

# =============================================================================
# Grant admin consent via Microsoft Graph REST API
# =============================================================================
echo ""
echo "Granting admin consent for Graph API permissions..."

# Get the Microsoft Graph service principal ID in this tenant
GRAPH_SP_ID=$(az ad sp show --id "00000003-0000-0000-c000-000000000000" --query id -o tsv 2>/dev/null || echo "")
if [ -z "$GRAPH_SP_ID" ]; then
    echo -e "\033[0;31m[ERROR] Could not find Microsoft Graph service principal in this tenant.\033[0m"
    exit 1
fi

# Read the required permissions from the app registration
PERMISSION_IDS=$(az ad app show --id "$GRAPH_CLIENT_ID" \
    --query "requiredResourceAccess[?resourceAppId=='00000003-0000-0000-c000-000000000000'].resourceAccess[].id" \
    -o tsv 2>/dev/null)

ALL_SUCCEEDED=true
for ROLE_ID in $PERMISSION_IDS; do
    BODY_FILE=$(mktemp)
    cat > "$BODY_FILE" <<EOF
{"principalId":"$APP_SP_ID","resourceId":"$GRAPH_SP_ID","appRoleId":"$ROLE_ID"}
EOF
    RESULT=$(az rest --method POST \
        --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$APP_SP_ID/appRoleAssignments" \
        --body "@$BODY_FILE" \
        --headers "Content-Type=application/json" \
        -o none 2>&1)
    EXIT_CODE=$?
    rm -f "$BODY_FILE"

    if [ $EXIT_CODE -eq 0 ]; then
        echo -e "\033[0;32m  Granted role: $ROLE_ID\033[0m"
    else
        # Check if already granted
        if echo "$RESULT" | grep -qi "already exists"; then
            echo "  Role already granted: $ROLE_ID"
        else
            echo -e "\033[0;31m  [ERROR] Failed to grant role $ROLE_ID: $RESULT\033[0m"
            ALL_SUCCEEDED=false
        fi
    fi
done

if [ "$ALL_SUCCEEDED" = true ]; then
    echo ""
    echo -e "\033[0;32m[SUCCESS] Admin consent granted for Graph API permissions on '$GRAPH_APP_NAME'\033[0m"
    echo ""
else
    echo ""
    echo -e "\033[0;31m[ERROR] Some permissions failed to grant. See errors above.\033[0m"
    echo ""
    echo -e "\033[0;33mPossible causes:\033[0m"
    echo -e "\033[0;33m  - Your account does not have Global Administrator or Privileged Role Administrator role\033[0m"
    echo -e "\033[0;33m  - The app registration permissions have not been configured correctly\033[0m"
    echo ""
    echo -e "\033[0;36mManual alternative:\033[0m"
    echo -e "\033[0;36m  Azure Portal > App registrations > $GRAPH_APP_NAME > API permissions > Grant admin consent\033[0m"
    exit 1
fi

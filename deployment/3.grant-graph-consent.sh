#!/usr/bin/env bash
# =============================================================================
# Grants admin consent for Graph API permissions on the app registration.
# Mirrors deployment/3.grant-graph-consent.ps1
#
# Usage:
#   ./3.grant-graph-consent.sh <suffix>
# =============================================================================
set -euo pipefail

if [[ $# -lt 1 || -z "${1:-}" ]]; then
    echo "[ERROR] Suffix is required." >&2
    echo "Usage: $0 <suffix>" >&2
    exit 1
fi
SUFFIX="$1"

PROJECT_NAME="${PROJECT_NAME:-eia}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
GRAPH_APP_NAME="${GRAPH_APP_NAME:-${PROJECT_NAME}-graph-api-${ENVIRONMENT}}"

echo ""
echo "============================================"
echo "  Grant Admin Consent for Graph API"
echo "============================================"
echo ""
echo "This script grants admin consent for the Graph API permissions"
echo "configured on app registration: $GRAPH_APP_NAME"
echo ""
echo "[IMPORTANT] This operation requires one of the following Azure AD roles:"
echo "  - Global Administrator"
echo "  - Privileged Role Administrator"
echo ""
read -r -p "Do you have one of these tenant admin roles? (y/N): " confirmation
case "$confirmation" in
    y|Y|yes|Yes|YES) ;;
    *)
        echo ""
        echo "[ABORTED] Please ask a tenant admin to run this script, or grant consent manually:"
        echo "  Azure Portal > App registrations > $GRAPH_APP_NAME > API permissions > Grant admin consent"
        exit 0
        ;;
esac

echo ""
echo "Verifying Azure CLI session..."
if ! account_json=$(az account show -o json 2>/dev/null); then
    echo "[ERROR] Not logged in to Azure CLI. Run 'az login' first." >&2
    exit 1
fi
acct_user=$(echo "$account_json" | az --query 'user.name' --output tsv 2>/dev/null || echo "$account_json" | grep -oE '"name"\s*:\s*"[^"]*"' | head -2 | tail -1 | sed -E 's/.*"name"\s*:\s*"([^"]*)".*/\1/')
acct_name=$(az account show --query name -o tsv)
acct_user=$(az account show --query user.name -o tsv)
echo "Logged in as: $acct_user (Subscription: $acct_name)"

# -----------------------------------------------------------------------------
# Look up the app registration
# -----------------------------------------------------------------------------
echo ""
echo "Looking up app registration: $GRAPH_APP_NAME ..."
GRAPH_CLIENT_ID=$(az ad app list --display-name "$GRAPH_APP_NAME" --query '[0].appId' -o tsv 2>/tmp/graph-consent-err) || true
if [[ -z "$GRAPH_CLIENT_ID" || "$GRAPH_CLIENT_ID" == "null" ]]; then
    err=$(cat /tmp/graph-consent-err 2>/dev/null || true)
    rm -f /tmp/graph-consent-err
    echo "[ERROR] App registration '$GRAPH_APP_NAME' not found in current tenant." >&2
    if [[ -n "$err" ]]; then echo "  $err" >&2; fi
    if echo "$err" | grep -qE 'Continuous access evaluation|InteractionRequired|TokenCreatedWithOutdatedPolicies|AADSTS'; then
        echo "[HINT] Your Azure CLI token needs to be refreshed. Run 'az login' and retry." >&2
    fi
    echo "[HINT] Other 'graph-api' apps visible to you in this tenant:" >&2
    az ad app list --filter "contains(displayName,'graph-api')" --query '[].{name:displayName, appId:appId}' -o table || true
    echo "[HINT] If your app uses a different name, set GRAPH_APP_NAME and re-run, or run 2.deploy-infrastructure.sh first." >&2
    exit 1
fi
rm -f /tmp/graph-consent-err
echo "Found app registration: $GRAPH_CLIENT_ID"

# -----------------------------------------------------------------------------
# Ensure service principal exists
# -----------------------------------------------------------------------------
echo ""
echo "Ensuring service principal exists..."
APP_SP_ID=$(az ad sp show --id "$GRAPH_CLIENT_ID" --query id -o tsv 2>/dev/null || true)
if [[ -z "$APP_SP_ID" ]]; then
    echo "Creating service principal for app registration..."
    APP_SP_ID=$(az ad sp create --id "$GRAPH_CLIENT_ID" --query id -o tsv) || {
        echo "[ERROR] Failed to create service principal" >&2
        exit 1
    }
    echo "Service principal created: $APP_SP_ID"
else
    echo "Service principal already exists: $APP_SP_ID"
fi

# -----------------------------------------------------------------------------
# Grant admin consent
# -----------------------------------------------------------------------------
echo ""
echo "Granting admin consent for Graph API permissions..."

GRAPH_SP_ID=$(az ad sp show --id 00000003-0000-0000-c000-000000000000 --query id -o tsv 2>/dev/null || true)
if [[ -z "$GRAPH_SP_ID" ]]; then
    echo "[ERROR] Could not find Microsoft Graph service principal in this tenant." >&2
    exit 1
fi

# Read required permissions (Graph appRole ids) from app registration
ROLE_IDS=$(az ad app show --id "$GRAPH_CLIENT_ID" \
    --query "requiredResourceAccess[?resourceAppId=='00000003-0000-0000-c000-000000000000'].resourceAccess[].id" \
    -o tsv)

ALL_OK=1
while IFS= read -r ROLE_ID; do
    [[ -z "$ROLE_ID" ]] && continue
    BODY=$(printf '{"principalId":"%s","resourceId":"%s","appRoleId":"%s"}' "$APP_SP_ID" "$GRAPH_SP_ID" "$ROLE_ID")
    BODY_FILE=$(mktemp)
    printf '%s' "$BODY" > "$BODY_FILE"
    if out=$(az rest --method POST \
            --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$APP_SP_ID/appRoleAssignments" \
            --body "@$BODY_FILE" \
            --headers Content-Type=application/json \
            --resource https://graph.microsoft.com \
            -o json 2>&1); then
        echo "  Granted role: $ROLE_ID"
    else
        if echo "$out" | grep -qE 'already exists|Permission.*already'; then
            echo "  Role already granted: $ROLE_ID"
        else
            echo "  [ERROR] Failed to grant role $ROLE_ID: $out" >&2
            ALL_OK=0
        fi
    fi
    rm -f "$BODY_FILE"
done <<< "$ROLE_IDS"

if [[ $ALL_OK -eq 1 ]]; then
    echo ""
    echo "[SUCCESS] Admin consent granted for Graph API permissions on '$GRAPH_APP_NAME'"
    echo ""
else
    echo ""
    echo "[ERROR] Some permissions failed to grant. See errors above." >&2
    echo ""
    echo "Possible causes:"
    echo "  - Your account does not have Global Administrator or Privileged Role Administrator role"
    echo "  - The app registration permissions have not been configured correctly"
    echo ""
    echo "Manual alternative:"
    echo "  Azure Portal > App registrations > $GRAPH_APP_NAME > API permissions > Grant admin consent"
    exit 1
fi

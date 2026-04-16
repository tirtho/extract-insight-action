#!/bin/bash
# =============================================================================
# Dev Environment Setup Script for extract-insight-action
#
# Configures the dev environment for local development and testing:
#   - Enables public network access on Cosmos DB, Storage, and Key Vault
#     (restricted to laptop IP + Azure services only)
#   - Grants the logged-in user read/write/admin RBAC roles
#
# Run this after deploy-infrastructure.sh has completed successfully.
#
# Usage:
#   chmod +x operation-dev.sh
#   ./operation-dev.sh <suffix>
#   ./operation-dev.sh 999
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
# HELPER FUNCTIONS
# =============================================================================
log_info()    { echo -e "\033[0;36m[INFO]\033[0m $1"; }
log_success() { echo -e "\033[0;32m[SUCCESS]\033[0m $1"; }
log_warning() { echo -e "\033[1;33m[WARNING]\033[0m $1"; }
log_error()   { echo -e "\033[0;31m[ERROR]\033[0m $1"; }
log_ok()      { echo -e "\033[0;37m  [OK]\033[0m $1"; }

# Run az CLI silently; captures exit code and stdout
run_az_silent() {
    local output
    output=$(az "$@" 2>/dev/null) && echo "$output" || return $?
}

# Ensure an ARM role assignment exists. Returns 0 if already existed, 1 if newly created.
ensure_role_assignment() {
    local assignee="$1" role="$2" scope="$3"
    local existing
    existing=$(az role assignment list --assignee "$assignee" --role "$role" --scope "$scope" --query "[0].id" -o tsv 2>/dev/null || echo "")
    if [ -n "$existing" ]; then
        return 0  # already exists
    fi
    az role assignment create --assignee "$assignee" --role "$role" --scope "$scope" --output none 2>/dev/null || true
    return 1  # newly created
}

# Ensure a Cosmos DB data-plane role assignment exists.
# Returns 0 if already existed, 1 if newly created.
ensure_cosmos_role_assignment() {
    local account_name="$1" resource_group="$2" role_def_id="$3" principal_id="$4" scope="$5"
    local existing
    existing=$(az cosmosdb sql role assignment list \
        --account-name "$account_name" --resource-group "$resource_group" \
        --query "[?principalId=='$principal_id' && contains(roleDefinitionId, '$role_def_id')] | [0].id" \
        --output tsv 2>/dev/null || echo "")
    if [ -n "$existing" ]; then
        return 0  # already exists
    fi
    az cosmosdb sql role assignment create \
        --account-name "$account_name" --resource-group "$resource_group" \
        --role-definition-id "$role_def_id" \
        --principal-id "$principal_id" --scope "$scope" \
        --output none 2>/dev/null || true
    return 1  # newly created
}

# Normalize a comma-separated IP list for comparison (sort + dedupe + trim)
normalize_ip_list() {
    local ip_csv="$1"
    if [ -z "$ip_csv" ]; then
        echo ""
        return
    fi
    echo "$ip_csv" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' | sort -u | paste -sd ',' -
}

# Normalize bypass string for comparison (sort components)
normalize_bypass() {
    local bypass="$1"
    if [ -z "$bypass" ]; then
        echo ""
        return
    fi
    echo "$bypass" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' | sort | paste -sd ',' -
}

# =============================================================================
# CONFIGURATION (must match deploy-infrastructure.sh)
# =============================================================================
PROJECT_NAME="${PROJECT_NAME:-eia}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
PROJ_CLEAN="${PROJECT_NAME//-/}"
RESOURCE_GROUP_NAME="${RESOURCE_GROUP_NAME:-rg-${PROJECT_NAME}-${ENVIRONMENT}-${SUFFIX}}"
STORAGE_ACCOUNT_NAME="${STORAGE_ACCOUNT_NAME:-st${PROJ_CLEAN}${ENVIRONMENT}${SUFFIX}}"
COSMOS_DB_ACCOUNT_NAME="${COSMOS_DB_ACCOUNT_NAME:-cosmos-${PROJECT_NAME}-${ENVIRONMENT}-${SUFFIX}}"
CONTENT_UNDERSTANDING_NAME="${CONTENT_UNDERSTANDING_NAME:-cu-${PROJECT_NAME}-${ENVIRONMENT}-${SUFFIX}}"
AI_FOUNDRY_NAME="${AI_FOUNDRY_NAME:-oai-${PROJECT_NAME}-${ENVIRONMENT}-${SUFFIX}}"
KEY_VAULT_NAME="${KEY_VAULT_NAME:-kv-${PROJECT_NAME}-${ENVIRONMENT}-${SUFFIX}}"

# =============================================================================
# BANNER
# =============================================================================
echo ""
echo -e "\033[0;36m============================================================\033[0m"
echo -e "\033[0;36m  Dev Environment Setup: $PROJECT_NAME ($ENVIRONMENT)\033[0m"
echo -e "\033[0;36m  Resource Group: $RESOURCE_GROUP_NAME\033[0m"
echo -e "\033[0;36m============================================================\033[0m"
echo ""

# =============================================================================
# PREREQUISITES
# =============================================================================
log_info "Checking prerequisites..."

if ! command -v jq &> /dev/null; then
    log_error "jq is not installed. Install it with: sudo apt-get install jq (or brew install jq)"
    exit 1
fi

ACCT_STATE=$(az account show --query state -o tsv 2>/dev/null || echo "")
if [ "$ACCT_STATE" != "Enabled" ]; then
    log_error "Not logged in to Azure CLI. Run 'az login' first."
    exit 1
fi

CURRENT_USER_ID=$(az ad signed-in-user show --query id -o tsv 2>/dev/null || echo "")
if [ -z "$CURRENT_USER_ID" ]; then
    # Check for CAE token expiry
    CAE_CHECK=$(az ad signed-in-user show 2>&1 || echo "")
    if echo "$CAE_CHECK" | grep -qi "Continuous access evaluation\|InteractionRequired"; then
        log_error "Azure CLI token expired (CAE challenge). Run:"
        echo "  az account clear; az login"
    else
        log_error "Could not determine current user. Run 'az login' first."
    fi
    exit 1
fi
CURRENT_USER_NAME=$(az ad signed-in-user show --query userPrincipalName -o tsv 2>/dev/null || echo "")
echo -e "\033[0;32m[OK]\033[0m Logged in as: $CURRENT_USER_NAME ($CURRENT_USER_ID)"

# Verify resources exist
STORAGE_EXISTS=$(az storage account show --name "$STORAGE_ACCOUNT_NAME" --resource-group "$RESOURCE_GROUP_NAME" --query name -o tsv 2>/dev/null || echo "")
COSMOS_EXISTS=$(az cosmosdb show --name "$COSMOS_DB_ACCOUNT_NAME" --resource-group "$RESOURCE_GROUP_NAME" --query name -o tsv 2>/dev/null || echo "")
KV_EXISTS=$(az keyvault show --name "$KEY_VAULT_NAME" --resource-group "$RESOURCE_GROUP_NAME" --query name -o tsv 2>/dev/null || echo "")

if [ -z "$STORAGE_EXISTS" ]; then
    log_error "Storage account '$STORAGE_ACCOUNT_NAME' not found in resource group '$RESOURCE_GROUP_NAME'."
    echo "  Run deploy-infrastructure.sh $SUFFIX first."
    exit 1
fi
if [ -z "$COSMOS_EXISTS" ]; then
    log_error "Cosmos DB account '$COSMOS_DB_ACCOUNT_NAME' not found in resource group '$RESOURCE_GROUP_NAME'."
    echo "  Run deploy-infrastructure.sh $SUFFIX first."
    exit 1
fi
if [ -z "$KV_EXISTS" ]; then
    log_error "Key Vault '$KEY_VAULT_NAME' not found in resource group '$RESOURCE_GROUP_NAME'."
    echo "  Run deploy-infrastructure.sh $SUFFIX first."
    exit 1
fi
echo -e "\033[0;32m[OK]\033[0m Resources verified"

# =============================================================================
# STEP 1: Configure Network Access (laptop IP + Azure services only)
# =============================================================================
echo ""
echo ">>> Step 1: Configure Network Access"

# Detect laptop public IP
log_info "Detecting your public IP address..."
MY_PUBLIC_IP=$(curl -s --max-time 10 https://api.ipify.org 2>/dev/null || echo "")
if [ -z "$MY_PUBLIC_IP" ]; then
    log_error "Could not detect public IP. Check internet connectivity."
    exit 1
fi
echo -e "\033[0;32m[OK]\033[0m Your public IP: $MY_PUBLIC_IP"

NETWORK_CHANGES=0

# --- Gather current state (quick reads, sequential) ---
DESIRED_COSMOS_IP_FILTER="$MY_PUBLIC_IP,104.42.195.92,40.76.54.131,52.176.6.30,52.169.50.45,52.187.184.26,0.0.0.0"

log_info "Checking Cosmos DB network rules: $COSMOS_DB_ACCOUNT_NAME"
COSMOS_STATE=$(az cosmosdb show --name "$COSMOS_DB_ACCOUNT_NAME" \
    --resource-group "$RESOURCE_GROUP_NAME" \
    --query '{publicNetworkAccess:publicNetworkAccess, ipRules:ipRules[].ipAddressOrRange}' -o json 2>/dev/null || echo '{}')
COSMOS_PUBLIC_ACCESS=$(echo "$COSMOS_STATE" | jq -r '.publicNetworkAccess // ""')
CURRENT_COSMOS_IPS=$(echo "$COSMOS_STATE" | jq -r '(.ipRules // []) | join(",")' 2>/dev/null || echo "")
CURRENT_COSMOS_IPS_NORM=$(normalize_ip_list "$CURRENT_COSMOS_IPS")
DESIRED_COSMOS_IPS_NORM=$(normalize_ip_list "$DESIRED_COSMOS_IP_FILTER")
COSMOS_NEEDS_UPDATE=false
if [ "$COSMOS_PUBLIC_ACCESS" != "Enabled" ] || [ "$CURRENT_COSMOS_IPS_NORM" != "$DESIRED_COSMOS_IPS_NORM" ]; then
    COSMOS_NEEDS_UPDATE=true
fi

log_info "Checking Storage Account network rules: $STORAGE_ACCOUNT_NAME"
STORAGE_STATE=$(az storage account show --name "$STORAGE_ACCOUNT_NAME" \
    --resource-group "$RESOURCE_GROUP_NAME" \
    --query '{publicNetworkAccess:publicNetworkAccess, defaultAction:networkRuleSet.defaultAction, bypass:networkRuleSet.bypass, ipRules:networkRuleSet.ipRules[].ipAddressOrRange}' \
    -o json 2>/dev/null || echo '{}')
STORAGE_PUBLIC_ACCESS=$(echo "$STORAGE_STATE" | jq -r '.publicNetworkAccess // ""')
STORAGE_DEFAULT_ACTION=$(echo "$STORAGE_STATE" | jq -r '.defaultAction // ""')
STORAGE_BYPASS=$(echo "$STORAGE_STATE" | jq -r '.bypass // ""')
STORAGE_IPS=$(echo "$STORAGE_STATE" | jq -r '(.ipRules // []) | join(",")' 2>/dev/null || echo "")
CURRENT_BYPASS_NORM=$(normalize_bypass "$STORAGE_BYPASS")
DESIRED_BYPASS_NORM=$(normalize_bypass "AzureServices,Logging,Metrics")
CURRENT_STORAGE_IPS_SORTED=$(echo "$STORAGE_IPS" | tr ',' '\n' | sort -u | paste -sd ',' - 2>/dev/null || echo "")
STORAGE_NEEDS_UPDATE=false
[ "$STORAGE_PUBLIC_ACCESS" != "Enabled" ] && STORAGE_NEEDS_UPDATE=true
[ "$STORAGE_DEFAULT_ACTION" != "Deny" ] && STORAGE_NEEDS_UPDATE=true
[ "$CURRENT_BYPASS_NORM" != "$DESIRED_BYPASS_NORM" ] && STORAGE_NEEDS_UPDATE=true
[ "$CURRENT_STORAGE_IPS_SORTED" != "$MY_PUBLIC_IP" ] && STORAGE_NEEDS_UPDATE=true

log_info "Checking Key Vault network rules: $KEY_VAULT_NAME"
KV_STATE=$(az keyvault show --name "$KEY_VAULT_NAME" \
    --resource-group "$RESOURCE_GROUP_NAME" \
    --query '{publicNetworkAccess:properties.publicNetworkAccess, defaultAction:properties.networkAcls.defaultAction, bypass:properties.networkAcls.bypass, ipRules:properties.networkAcls.ipRules[].value}' \
    -o json 2>/dev/null || echo '{}')
KV_PUBLIC_ACCESS=$(echo "$KV_STATE" | jq -r '.publicNetworkAccess // ""')
KV_DEFAULT_ACTION=$(echo "$KV_STATE" | jq -r '.defaultAction // ""')
KV_BYPASS=$(echo "$KV_STATE" | jq -r '.bypass // ""')
KV_IPS=$(echo "$KV_STATE" | jq -r '(.ipRules // []) | join(",")' 2>/dev/null || echo "")
CURRENT_KV_BYPASS_NORM=$(normalize_bypass "$KV_BYPASS")
DESIRED_KV_BYPASS_NORM=$(normalize_bypass "AzureServices")
CURRENT_KV_IPS_SORTED=$(echo "$KV_IPS" | tr ',' '\n' | sort -u | paste -sd ',' - 2>/dev/null || echo "")
DESIRED_KV_IP="$MY_PUBLIC_IP/32"
KV_NEEDS_UPDATE=false
[ "$KV_PUBLIC_ACCESS" != "Enabled" ] && KV_NEEDS_UPDATE=true
[ "$KV_DEFAULT_ACTION" != "Deny" ] && KV_NEEDS_UPDATE=true
[ "$CURRENT_KV_BYPASS_NORM" != "$DESIRED_KV_BYPASS_NORM" ] && KV_NEEDS_UPDATE=true
[ "$CURRENT_KV_IPS_SORTED" != "$DESIRED_KV_IP" ] && KV_NEEDS_UPDATE=true

# --- Launch updates in parallel (these are the slow operations) ---
PIDS=()
PID_NAMES=()
TMPDIR_NET=$(mktemp -d)

if [ "$COSMOS_NEEDS_UPDATE" = false ]; then
    log_ok "Cosmos DB network rules already configured correctly"
else
    log_info "  Updating Cosmos DB IP filter in background... (slowest, typically 2-5 min)"
    (
        az cosmosdb update --name "$COSMOS_DB_ACCOUNT_NAME" \
            --resource-group "$RESOURCE_GROUP_NAME" \
            --public-network-access Enabled \
            --ip-range-filter "$DESIRED_COSMOS_IP_FILTER" \
            --output none 2>"$TMPDIR_NET/cosmos.err" && touch "$TMPDIR_NET/cosmos.ok"
    ) &
    PIDS+=($!)
    PID_NAMES+=("CosmosDB-Network")
fi

if [ "$STORAGE_NEEDS_UPDATE" = false ]; then
    log_ok "Storage Account network rules already configured correctly"
else
    log_info "  Updating Storage Account network rules in background..."
    (
        if [ "$STORAGE_PUBLIC_ACCESS" != "Enabled" ] || [ "$STORAGE_DEFAULT_ACTION" != "Deny" ] || [ "$CURRENT_BYPASS_NORM" != "$DESIRED_BYPASS_NORM" ]; then
            az storage account update --name "$STORAGE_ACCOUNT_NAME" \
                --resource-group "$RESOURCE_GROUP_NAME" \
                --public-network-access Enabled \
                --default-action Deny \
                --bypass AzureServices Logging Metrics \
                --output none 2>/dev/null || { echo "default rules failed" > "$TMPDIR_NET/storage.err"; exit 1; }
        fi
        if [ "$CURRENT_STORAGE_IPS_SORTED" != "$MY_PUBLIC_IP" ]; then
            if [ -n "$STORAGE_IPS" ]; then
                for ip in $(echo "$STORAGE_IPS" | tr ',' '\n'); do
                    [ "$ip" != "$MY_PUBLIC_IP" ] && az storage account network-rule remove \
                        --account-name "$STORAGE_ACCOUNT_NAME" --resource-group "$RESOURCE_GROUP_NAME" \
                        --ip-address "$ip" --output none 2>/dev/null || true
                done
            fi
            HAS_MY_IP=false
            echo ",$STORAGE_IPS," | grep -q ",$MY_PUBLIC_IP," && HAS_MY_IP=true
            if [ "$HAS_MY_IP" = false ]; then
                az storage account network-rule add \
                    --account-name "$STORAGE_ACCOUNT_NAME" --resource-group "$RESOURCE_GROUP_NAME" \
                    --ip-address "$MY_PUBLIC_IP" --output none 2>/dev/null || { echo "IP add failed" > "$TMPDIR_NET/storage.err"; exit 1; }
            fi
        fi
        touch "$TMPDIR_NET/storage.ok"
    ) &
    PIDS+=($!)
    PID_NAMES+=("Storage-Network")
fi

if [ "$KV_NEEDS_UPDATE" = false ]; then
    log_ok "Key Vault network rules already configured correctly"
else
    log_info "  Updating Key Vault network rules in background..."
    (
        if [ "$KV_PUBLIC_ACCESS" != "Enabled" ] || [ "$KV_DEFAULT_ACTION" != "Deny" ] || [ "$CURRENT_KV_BYPASS_NORM" != "$DESIRED_KV_BYPASS_NORM" ]; then
            az keyvault update --name "$KEY_VAULT_NAME" \
                --resource-group "$RESOURCE_GROUP_NAME" \
                --public-network-access Enabled \
                --default-action Deny \
                --bypass AzureServices \
                --output none 2>/dev/null || { echo "default rules failed" > "$TMPDIR_NET/kv.err"; exit 1; }
        fi
        if [ "$CURRENT_KV_IPS_SORTED" != "$DESIRED_KV_IP" ]; then
            if [ -n "$KV_IPS" ]; then
                for ip in $(echo "$KV_IPS" | tr ',' '\n'); do
                    [ "$ip" != "$DESIRED_KV_IP" ] && az keyvault network-rule remove --name "$KEY_VAULT_NAME" \
                        --resource-group "$RESOURCE_GROUP_NAME" \
                        --ip-address "$ip" --output none 2>/dev/null || true
                done
            fi
            HAS_MY_KV_IP=false
            echo ",$KV_IPS," | grep -q ",$DESIRED_KV_IP," && HAS_MY_KV_IP=true
            if [ "$HAS_MY_KV_IP" = false ]; then
                az keyvault network-rule add --name "$KEY_VAULT_NAME" \
                    --resource-group "$RESOURCE_GROUP_NAME" \
                    --ip-address "$DESIRED_KV_IP" --output none 2>/dev/null || { echo "IP add failed" > "$TMPDIR_NET/kv.err"; exit 1; }
            fi
        fi
        touch "$TMPDIR_NET/kv.ok"
    ) &
    PIDS+=($!)
    PID_NAMES+=("KeyVault-Network")
fi

# --- Wait for all parallel jobs to complete ---
if [ ${#PIDS[@]} -gt 0 ]; then
    log_info "Waiting for ${#PIDS[@]} network update(s) to complete in parallel..."
    for i in "${!PIDS[@]}"; do
        pid=${PIDS[$i]}
        name=${PID_NAMES[$i]}
        if wait "$pid" 2>/dev/null; then
            log_success "  $name: done"
            NETWORK_CHANGES=$((NETWORK_CHANGES + 1))
        else
            log_error "  $name failed"
        fi
    done
    rm -rf "$TMPDIR_NET"
fi

# =============================================================================
# STEP 2: Grant Logged-In User Read/Write & Admin Access
# =============================================================================
echo ""
echo ">>> Step 2: Grant RBAC Roles to Current User"

# --- Gather resource IDs (quick reads) ---
STORAGE_ACCOUNT_ID=$(az storage account show --name "$STORAGE_ACCOUNT_NAME" --resource-group "$RESOURCE_GROUP_NAME" --query id -o tsv 2>/dev/null || echo "")
COSMOS_DB_ACCOUNT_ID=$(az cosmosdb show --name "$COSMOS_DB_ACCOUNT_NAME" --resource-group "$RESOURCE_GROUP_NAME" --query id -o tsv 2>/dev/null || echo "")
KEY_VAULT_ID=$(az keyvault show --name "$KEY_VAULT_NAME" --resource-group "$RESOURCE_GROUP_NAME" --query id -o tsv 2>/dev/null || echo "")
CONTENT_UNDERSTANDING_ID=$(az cognitiveservices account show --name "$CONTENT_UNDERSTANDING_NAME" --resource-group "$RESOURCE_GROUP_NAME" --query id -o tsv 2>/dev/null || echo "")
AI_FOUNDRY_ID=$(az cognitiveservices account show --name "$AI_FOUNDRY_NAME" --resource-group "$RESOURCE_GROUP_NAME" --query id -o tsv 2>/dev/null || echo "")

# Resolve Content Understanding managed identity
CU_IDENTITY=$(az cognitiveservices account identity show --name "$CONTENT_UNDERSTANDING_NAME" --resource-group "$RESOURCE_GROUP_NAME" --query principalId -o tsv 2>/dev/null || echo "")
if [ -z "$CU_IDENTITY" ]; then
    log_info "  Enabling managed identity for $CONTENT_UNDERSTANDING_NAME"
    az cognitiveservices account identity assign --name "$CONTENT_UNDERSTANDING_NAME" --resource-group "$RESOURCE_GROUP_NAME" --output none 2>/dev/null || true
    CU_IDENTITY=$(az cognitiveservices account identity show --name "$CONTENT_UNDERSTANDING_NAME" --resource-group "$RESOURCE_GROUP_NAME" --query principalId -o tsv 2>/dev/null || echo "")
fi

# --- Build assignment list and launch all in parallel ---
# Each background task writes result to a temp file: "exists" or "created" or "error"
TMPDIR_RBAC=$(mktemp -d)
RBAC_PIDS=()
RBAC_LABELS=()

# Helper: launch an ARM role assignment in background
launch_arm_role() {
    local assignee="$1" role="$2" scope="$3" label="$4" idx="$5"
    (
        existing=$(az role assignment list --assignee "$assignee" --role "$role" --scope "$scope" --query "[0].id" -o tsv 2>/dev/null || echo "")
        if [ -n "$existing" ]; then
            echo "exists" > "$TMPDIR_RBAC/$idx.result"
        else
            az role assignment create --assignee "$assignee" --role "$role" --scope "$scope" --output none 2>/dev/null || true
            echo "created" > "$TMPDIR_RBAC/$idx.result"
        fi
    ) &
    RBAC_PIDS+=($!)
    RBAC_LABELS+=("$label")
}

# Helper: launch a Cosmos data-plane role assignment in background
launch_cosmos_role() {
    local account="$1" rg="$2" role_id="$3" principal="$4" scope="$5" label="$6" idx="$7"
    (
        existing=$(az cosmosdb sql role assignment list --account-name "$account" --resource-group "$rg" \
            --query "[?principalId=='$principal' && contains(roleDefinitionId, '$role_id')] | [0].id" --output tsv 2>/dev/null || echo "")
        if [ -n "$existing" ]; then
            echo "exists" > "$TMPDIR_RBAC/$idx.result"
        else
            az cosmosdb sql role assignment create --account-name "$account" --resource-group "$rg" \
                --role-definition-id "$role_id" --principal-id "$principal" --scope "$scope" --output none 2>/dev/null || true
            echo "created" > "$TMPDIR_RBAC/$idx.result"
        fi
    ) &
    RBAC_PIDS+=($!)
    RBAC_LABELS+=("$label")
}

IDX=0

# Storage Account ARM roles
for role in "Storage Blob Data Contributor" "Storage Blob Data Reader" \
            "Storage Queue Data Contributor" "Storage Table Data Contributor" \
            "Storage Account Contributor" "Storage Blob Data Owner"; do
    launch_arm_role "$CURRENT_USER_ID" "$role" "$STORAGE_ACCOUNT_ID" "$role" "$IDX"
    IDX=$((IDX + 1))
done

# Cosmos DB ARM roles
for role in "Cosmos DB Account Reader Role" "DocumentDB Account Contributor"; do
    launch_arm_role "$CURRENT_USER_ID" "$role" "$COSMOS_DB_ACCOUNT_ID" "$role" "$IDX"
    IDX=$((IDX + 1))
done

# Cosmos DB data-plane roles
launch_cosmos_role "$COSMOS_DB_ACCOUNT_NAME" "$RESOURCE_GROUP_NAME" \
    "00000000-0000-0000-0000-000000000001" "$CURRENT_USER_ID" "$COSMOS_DB_ACCOUNT_ID" \
    "Cosmos DB Built-in Data Reader" "$IDX"
IDX=$((IDX + 1))
launch_cosmos_role "$COSMOS_DB_ACCOUNT_NAME" "$RESOURCE_GROUP_NAME" \
    "00000000-0000-0000-0000-000000000002" "$CURRENT_USER_ID" "$COSMOS_DB_ACCOUNT_ID" \
    "Cosmos DB Built-in Data Contributor" "$IDX"
IDX=$((IDX + 1))

# Key Vault roles
for role in "Key Vault Secrets User" "Key Vault Secrets Officer" \
            "Key Vault Certificates Officer" "Key Vault Crypto Officer"; do
    launch_arm_role "$CURRENT_USER_ID" "$role" "$KEY_VAULT_ID" "$role" "$IDX"
    IDX=$((IDX + 1))
done

# Content Understanding roles for current user (data-plane access: create/read/delete analyzers, analyze documents)
for role in "Cognitive Services User" "Cognitive Services Contributor"; do
    launch_arm_role "$CURRENT_USER_ID" "$role" "$CONTENT_UNDERSTANDING_ID" "$role (Content Understanding)" "$IDX"
    IDX=$((IDX + 1))
done

# AI Foundry / Azure OpenAI roles for current user (data-plane access: chat completions, embeddings, etc.)
for role in "Cognitive Services User" "Cognitive Services Contributor" \
            "Cognitive Services OpenAI User" "Cognitive Services OpenAI Contributor"; do
    launch_arm_role "$CURRENT_USER_ID" "$role" "$AI_FOUNDRY_ID" "$role (AI Foundry)" "$IDX"
    IDX=$((IDX + 1))
done

# Content Understanding -> Storage Blob Data Reader
if [ -n "$CU_IDENTITY" ]; then
    launch_arm_role "$CU_IDENTITY" "Storage Blob Data Reader" "$STORAGE_ACCOUNT_ID" \
        "Storage Blob Data Reader (Content Understanding)" "$IDX"
    IDX=$((IDX + 1))
else
    log_warning "Content Understanding '$CONTENT_UNDERSTANDING_NAME' identity not found. Skipping."
fi

log_info "Assigning $IDX RBAC roles in parallel..."

# --- Wait for all RBAC jobs ---
NEW_ASSIGNMENTS=0
for i in "${!RBAC_PIDS[@]}"; do
    wait "${RBAC_PIDS[$i]}" 2>/dev/null || true
    label="${RBAC_LABELS[$i]}"
    result=$(cat "$TMPDIR_RBAC/$i.result" 2>/dev/null || echo "error")
    if [ "$result" = "exists" ]; then
        log_ok "$label - already assigned"
    elif [ "$result" = "created" ]; then
        log_success "  $label - assigned"
        NEW_ASSIGNMENTS=$((NEW_ASSIGNMENTS + 1))
    else
        log_error "  $label - failed"
    fi
done
rm -rf "$TMPDIR_RBAC"

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
TOTAL_CHANGES=$((NETWORK_CHANGES + NEW_ASSIGNMENTS))
if [ "$TOTAL_CHANGES" -gt 0 ]; then
    log_success "Dev environment configured. $NETWORK_CHANGES network change(s), $NEW_ASSIGNMENTS new RBAC assignment(s)."
    if [ "$NEW_ASSIGNMENTS" -gt 0 ]; then
        log_info "RBAC propagation may take up to 5 minutes."
    fi
else
    log_success "Dev environment already configured. No changes needed."
fi
echo ""
echo "  Storage Account : $STORAGE_ACCOUNT_NAME (firewall: laptop IP + Azure services)"
echo "  Cosmos DB       : $COSMOS_DB_ACCOUNT_NAME (firewall: laptop IP + Azure services)"
echo "  Key Vault       : $KEY_VAULT_NAME (firewall: laptop IP + Azure services)"
echo "  Allowed IP      : $MY_PUBLIC_IP"
echo "  User            : $CURRENT_USER_NAME"
echo ""

# =============================================================================
# GENERATE env.bat
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_BAT_PATH="$SCRIPT_DIR/../env.bat"
printf '@echo off\r\nset KEY_VAULT_URL=https://%s.vault.azure.net\r\n' "$KEY_VAULT_NAME" > "$ENV_BAT_PATH"
echo -e "\033[0;32m[OK]\033[0m Created $ENV_BAT_PATH"

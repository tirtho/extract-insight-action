#!/usr/bin/env bash
# =============================================================================
# Dev environment setup: enables public network access on data plane resources,
# grants the logged-in user RBAC, ensures CU MI exists. Mirrors 4.operation-dev.ps1.
#
# Usage: ./4.operation-dev.sh <suffix>
# =============================================================================
set -uo pipefail

if [[ $# -lt 1 || -z "${1:-}" ]]; then
    echo "[ERROR] Suffix is required." >&2
    echo "Usage: $0 <suffix>" >&2
    exit 1
fi
SUFFIX="$1"

# -----------------------------------------------------------------------------
# Configuration (must match 2.deploy-infrastructure.sh)
# -----------------------------------------------------------------------------
PROJECT_NAME="${PROJECT_NAME:-eia}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
PROJ_CLEAN="${PROJECT_NAME//-/}"
ResourceGroupName="${RESOURCE_GROUP_NAME:-rg-${PROJECT_NAME}-${ENVIRONMENT}-${SUFFIX}}"
StorageAccountName="${STORAGE_ACCOUNT_NAME:-st${PROJ_CLEAN}${ENVIRONMENT}${SUFFIX}}"
CosmosDbAccountName="${COSMOS_DB_ACCOUNT_NAME:-cosmos-${PROJECT_NAME}-${ENVIRONMENT}-${SUFFIX}}"
ContentUnderstandingName="${CONTENT_UNDERSTANDING_NAME:-cu-${PROJECT_NAME}-${ENVIRONMENT}-${SUFFIX}}"
AiFoundryName="${AI_FOUNDRY_NAME:-oai-${PROJECT_NAME}-${ENVIRONMENT}-${SUFFIX}}"
KeyVaultName="${KEY_VAULT_NAME:-kv-${PROJECT_NAME}-${ENVIRONMENT}-${SUFFIX}}"
ServiceBusNamespace="${SERVICE_BUS_NAMESPACE:-sb-${PROJECT_NAME}-${ENVIRONMENT}-${SUFFIX}}"

echo ""
echo "============================================================"
echo "  Dev Environment Setup: $PROJECT_NAME ($ENVIRONMENT)"
echo "  Resource Group: $ResourceGroupName"
echo "============================================================"
echo ""

# -----------------------------------------------------------------------------
# Prerequisites
# -----------------------------------------------------------------------------
echo "[INFO] Checking prerequisites..."
if ! state=$(az account show --query state -o tsv 2>/dev/null) || [[ "$state" != "Enabled" ]]; then
    echo "[ERROR] Not logged in to Azure CLI. Run 'az login' first." >&2
    exit 1
fi
CurrentUserId=$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)
if [[ -z "$CurrentUserId" ]]; then
    echo "[ERROR] Could not determine current user. Run 'az login' first." >&2
    exit 1
fi
CurrentUserName=$(az ad signed-in-user show --query userPrincipalName -o tsv 2>/dev/null || true)
echo "[OK] Logged in as: $CurrentUserName ($CurrentUserId)"

storageExists=$(az storage account show --name "$StorageAccountName" --resource-group "$ResourceGroupName" --query name -o tsv 2>/dev/null || true)
cosmosExists=$(az cosmosdb show --name "$CosmosDbAccountName" --resource-group "$ResourceGroupName" --query name -o tsv 2>/dev/null || true)
kvExists=$(az keyvault show --name "$KeyVaultName" --resource-group "$ResourceGroupName" --query name -o tsv 2>/dev/null || true)
if [[ -z "$storageExists" ]]; then echo "[ERROR] Storage account '$StorageAccountName' not found. Run 2.deploy-infrastructure.sh first." >&2; exit 1; fi
if [[ -z "$cosmosExists" ]];  then echo "[ERROR] Cosmos DB '$CosmosDbAccountName' not found. Run 2.deploy-infrastructure.sh first." >&2; exit 1; fi
if [[ -z "$kvExists" ]];      then echo "[ERROR] Key Vault '$KeyVaultName' not found. Run 2.deploy-infrastructure.sh first." >&2; exit 1; fi
echo "[OK] Resources verified"

# -----------------------------------------------------------------------------
# Step 1: Configure Network Access
# -----------------------------------------------------------------------------
echo ""
echo ">>> Step 1: Configure Network Access"

echo "[INFO] Detecting your public IP address..."
MyPublicIp=$(curl -fsS --max-time 10 https://api.ipify.org?format=text 2>/dev/null || true)
MyPublicIp="${MyPublicIp//[[:space:]]/}"
if [[ -z "$MyPublicIp" ]]; then
    echo "[ERROR] Could not detect public IP. Check internet connectivity." >&2
    exit 1
fi
echo "[OK] Your public IP: $MyPublicIp"

normalize_csv() {
    # sort + dedupe + trim
    local IFS=','
    local arr=($1)
    local out
    out=$(printf '%s\n' "${arr[@]}" | awk '{gsub(/^[[:space:]]+|[[:space:]]+$/,""); print}' | sort -u | tr '\n' ',' | sed 's/,$//')
    echo "$out"
}

DesiredCosmosIpFilter="$MyPublicIp,104.42.195.92,40.76.54.131,52.176.6.30,52.169.50.45,52.187.184.26,0.0.0.0"

echo "[INFO] Checking Cosmos DB network rules: $CosmosDbAccountName"
cosmosPna=$(az cosmosdb show --name "$CosmosDbAccountName" --resource-group "$ResourceGroupName" --query publicNetworkAccess -o tsv 2>/dev/null || true)
cosmosIps=$(az cosmosdb show --name "$CosmosDbAccountName" --resource-group "$ResourceGroupName" --query 'ipRules[].ipAddressOrRange' -o tsv 2>/dev/null | tr '\n' ',' | sed 's/,$//')
currentCosmosIps=$(normalize_csv "$cosmosIps")
desiredCosmosIps=$(normalize_csv "$DesiredCosmosIpFilter")
cosmosNeedsUpdate=1
if [[ "$cosmosPna" == "Enabled" && "$currentCosmosIps" == "$desiredCosmosIps" ]]; then cosmosNeedsUpdate=0; fi

echo "[INFO] Checking Storage Account network rules: $StorageAccountName"
storagePna=$(az storage account show --name "$StorageAccountName" --resource-group "$ResourceGroupName" --query publicNetworkAccess -o tsv 2>/dev/null || true)
storageDA=$(az storage account show --name "$StorageAccountName" --resource-group "$ResourceGroupName" --query 'networkRuleSet.defaultAction' -o tsv 2>/dev/null || true)
storageNeedsUpdate=1
if [[ "$storagePna" == "Enabled" && "$storageDA" == "Allow" ]]; then storageNeedsUpdate=0; fi

echo "[INFO] Checking Key Vault network rules: $KeyVaultName"
kvPna=$(az keyvault show --name "$KeyVaultName" --resource-group "$ResourceGroupName" --query 'properties.publicNetworkAccess' -o tsv 2>/dev/null || true)
kvDA=$(az keyvault show --name "$KeyVaultName" --resource-group "$ResourceGroupName" --query 'properties.networkAcls.defaultAction' -o tsv 2>/dev/null || true)
kvBypass=$(az keyvault show --name "$KeyVaultName" --resource-group "$ResourceGroupName" --query 'properties.networkAcls.bypass' -o tsv 2>/dev/null || true)
kvNeedsUpdate=1
if [[ "$kvPna" == "Enabled" && "$kvDA" == "Allow" && "$kvBypass" == "AzureServices" ]]; then kvNeedsUpdate=0; fi

networkChanges=0
declare -a NET_PIDS=()
declare -a NET_NAMES=()
declare -a NET_LOGS=()

run_net_update() {
    local name="$1"; shift
    local logfile
    logfile=$(mktemp)
    ( "$@" ) >"$logfile" 2>&1 &
    NET_PIDS+=($!)
    NET_NAMES+=("$name")
    NET_LOGS+=("$logfile")
}

if [[ $cosmosNeedsUpdate -eq 0 ]]; then
    echo "  [OK] Cosmos DB network rules already configured correctly"
else
    echo "  [INFO] Updating Cosmos DB IP filter in background... (slowest, typically 2-5 min)"
    run_net_update 'CosmosDB-Network' \
        az cosmosdb update --name "$CosmosDbAccountName" --resource-group "$ResourceGroupName" \
            --public-network-access Enabled --ip-range-filter "$DesiredCosmosIpFilter" --output none
fi

if [[ $storageNeedsUpdate -eq 0 ]]; then
    echo "  [OK] Storage Account network rules already configured correctly"
else
    echo "  [INFO] Updating Storage Account network rules in background..."
    run_net_update 'Storage-Network' \
        az storage account update --name "$StorageAccountName" --resource-group "$ResourceGroupName" \
            --public-network-access Enabled --default-action Allow --output none
fi

if [[ $kvNeedsUpdate -eq 0 ]]; then
    echo "  [OK] Key Vault network rules already configured correctly"
else
    echo "  [INFO] Updating Key Vault network rules in background..."
    run_net_update 'KeyVault-Network' \
        az keyvault update --name "$KeyVaultName" --resource-group "$ResourceGroupName" \
            --public-network-access Enabled --default-action Allow --bypass AzureServices --output none
fi

if (( ${#NET_PIDS[@]} > 0 )); then
    echo "[INFO] Waiting for ${#NET_PIDS[@]} network update(s) to complete in parallel..."
    for i in "${!NET_PIDS[@]}"; do
        if wait "${NET_PIDS[$i]}"; then
            echo "  [SUCCESS] ${NET_NAMES[$i]}: done"
            ((networkChanges++)) || true
        else
            echo "  [ERROR] ${NET_NAMES[$i]} failed" >&2
            cat "${NET_LOGS[$i]}" >&2 || true
        fi
        rm -f "${NET_LOGS[$i]}"
    done
fi

# -----------------------------------------------------------------------------
# Step 2: Grant RBAC Roles to Current User
# -----------------------------------------------------------------------------
echo ""
echo ">>> Step 2: Grant RBAC Roles to Current User"

StorageAccountId=$(az storage account show --name "$StorageAccountName" --resource-group "$ResourceGroupName" --query id -o tsv 2>/dev/null || true)
CosmosDbAccountId=$(az cosmosdb show --name "$CosmosDbAccountName" --resource-group "$ResourceGroupName" --query id -o tsv 2>/dev/null || true)
KeyVaultId=$(az keyvault show --name "$KeyVaultName" --resource-group "$ResourceGroupName" --query id -o tsv 2>/dev/null || true)
ContentUnderstandingId=$(az cognitiveservices account show --name "$ContentUnderstandingName" --resource-group "$ResourceGroupName" --query id -o tsv 2>/dev/null || true)
AiFoundryId=$(az cognitiveservices account show --name "$AiFoundryName" --resource-group "$ResourceGroupName" --query id -o tsv 2>/dev/null || true)
ServiceBusId=$(az servicebus namespace show --name "$ServiceBusNamespace" --resource-group "$ResourceGroupName" --query id -o tsv 2>/dev/null || true)

CuIdentity=$(az cognitiveservices account identity show --name "$ContentUnderstandingName" --resource-group "$ResourceGroupName" --query principalId -o tsv 2>/dev/null || true)
if [[ -z "$CuIdentity" ]]; then
    echo "  [INFO] Enabling managed identity for $ContentUnderstandingName"
    az cognitiveservices account identity assign --name "$ContentUnderstandingName" --resource-group "$ResourceGroupName" --output none 2>/dev/null || true
    CuIdentity=$(az cognitiveservices account identity show --name "$ContentUnderstandingName" --resource-group "$ResourceGroupName" --query principalId -o tsv 2>/dev/null || true)
fi

# Build list of role assignments. Each line: TYPE|FIELDS
# arm: arm|Assignee|Role|Scope|Label
# cosmos: cosmos|Account|RG|RoleDefId|PrincipalId|Scope|Label
ASSIGNMENTS=()

for r in 'Storage Blob Data Contributor' 'Storage Blob Data Reader' 'Storage Queue Data Contributor' \
         'Storage Table Data Contributor' 'Storage Account Contributor' 'Storage Blob Data Owner' \
         'Storage Blob Delegator'; do
    ASSIGNMENTS+=("arm|$CurrentUserId|$r|$StorageAccountId|$r")
done

for r in 'Cosmos DB Account Reader Role' 'DocumentDB Account Contributor'; do
    ASSIGNMENTS+=("arm|$CurrentUserId|$r|$CosmosDbAccountId|$r")
done

ASSIGNMENTS+=("cosmos|$CosmosDbAccountName|$ResourceGroupName|00000000-0000-0000-0000-000000000001|$CurrentUserId|$CosmosDbAccountId|Cosmos DB Built-in Data Reader")
ASSIGNMENTS+=("cosmos|$CosmosDbAccountName|$ResourceGroupName|00000000-0000-0000-0000-000000000002|$CurrentUserId|$CosmosDbAccountId|Cosmos DB Built-in Data Contributor")

for r in 'Key Vault Secrets User' 'Key Vault Secrets Officer' 'Key Vault Certificates Officer' 'Key Vault Crypto Officer'; do
    ASSIGNMENTS+=("arm|$CurrentUserId|$r|$KeyVaultId|$r")
done

for r in 'Cognitive Services User' 'Cognitive Services Contributor'; do
    ASSIGNMENTS+=("arm|$CurrentUserId|$r|$ContentUnderstandingId|$r (Content Understanding)")
done

for r in 'Cognitive Services User' 'Cognitive Services Contributor' 'Cognitive Services OpenAI User' 'Cognitive Services OpenAI Contributor'; do
    ASSIGNMENTS+=("arm|$CurrentUserId|$r|$AiFoundryId|$r (AI Foundry)")
done

if [[ -n "$CuIdentity" ]]; then
    ASSIGNMENTS+=("arm|$CuIdentity|Storage Blob Data Reader|$StorageAccountId|Storage Blob Data Reader (Content Understanding)")
else
    echo "  [WARNING] Content Understanding identity not found. Skipping CU storage role."
fi

if [[ -n "$ServiceBusId" ]]; then
    for r in 'Azure Service Bus Data Sender' 'Azure Service Bus Data Receiver'; do
        ASSIGNMENTS+=("arm|$CurrentUserId|$r|$ServiceBusId|$r (Service Bus)")
    done
else
    echo "  [WARNING] Service Bus namespace '$ServiceBusNamespace' not found. Skipping Service Bus roles."
fi

echo "[INFO] Assigning ${#ASSIGNMENTS[@]} RBAC roles in parallel..."

declare -a RBAC_PIDS=()
declare -a RBAC_LABELS=()
declare -a RBAC_LOGS=()

for line in "${ASSIGNMENTS[@]}"; do
    IFS='|' read -r TYPE F1 F2 F3 F4 F5 F6 <<< "$line"
    logfile=$(mktemp)
    if [[ "$TYPE" == "arm" ]]; then
        # F1=Assignee F2=Role F3=Scope F4=Label
        label="$F4"
        (
            existing=$(az role assignment list --assignee "$F1" --role "$F2" --scope "$F3" --query '[0].id' -o tsv 2>/dev/null || true)
            if [[ -n "$existing" ]]; then
                echo "exists" > "$logfile"
                exit 0
            fi
            if az role assignment create --assignee "$F1" --role "$F2" --scope "$F3" --output none 2>>"$logfile"; then
                echo "created" >> "$logfile"
                exit 0
            else
                exit 1
            fi
        ) &
    else
        # cosmos|$F1=Acct|$F2=RG|$F3=RoleDefId|$F4=PrincipalId|$F5=Scope|$F6=Label
        label="$F6"
        (
            existing=$(az cosmosdb sql role assignment list --account-name "$F1" --resource-group "$F2" \
                --query "[?principalId=='$F4' && contains(roleDefinitionId, '$F3')] | [0].id" --output tsv 2>/dev/null || true)
            if [[ -n "$existing" ]]; then
                echo "exists" > "$logfile"
                exit 0
            fi
            if az cosmosdb sql role assignment create --account-name "$F1" --resource-group "$F2" \
                --role-definition-id "$F3" --principal-id "$F4" --scope "$F5" --output none 2>>"$logfile"; then
                echo "created" >> "$logfile"
                exit 0
            else
                exit 1
            fi
        ) &
    fi
    RBAC_PIDS+=($!)
    RBAC_LABELS+=("$label")
    RBAC_LOGS+=("$logfile")
done

newAssignments=0
for i in "${!RBAC_PIDS[@]}"; do
    if wait "${RBAC_PIDS[$i]}"; then
        result=$(tail -1 "${RBAC_LOGS[$i]}" 2>/dev/null || true)
        if [[ "$result" == "exists" ]]; then
            echo "  [OK] ${RBAC_LABELS[$i]} - already assigned"
        else
            echo "  [SUCCESS] ${RBAC_LABELS[$i]} - assigned"
            ((newAssignments++)) || true
        fi
    else
        echo "  [ERROR] ${RBAC_LABELS[$i]} failed" >&2
        cat "${RBAC_LOGS[$i]}" >&2 || true
    fi
    rm -f "${RBAC_LOGS[$i]}"
done

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo ""
totalChanges=$((networkChanges + newAssignments))
if (( totalChanges > 0 )); then
    echo "[SUCCESS] Dev environment configured. $networkChanges network change(s), $newAssignments new RBAC assignment(s)."
    if (( newAssignments > 0 )); then
        echo "[INFO] RBAC propagation may take up to 5 minutes."
    fi
else
    echo "[SUCCESS] Dev environment already configured. No changes needed."
fi
echo ""
echo "  Storage Account : $StorageAccountName (firewall: laptop IP + Azure services)"
echo "  Cosmos DB       : $CosmosDbAccountName (firewall: laptop IP + Azure services)"
echo "  Key Vault       : $KeyVaultName (firewall: laptop IP + Azure services)"
echo "  Allowed IP      : $MyPublicIp"
echo "  User            : $CurrentUserName"
echo ""

# -----------------------------------------------------------------------------
# Generate env.bat in repo root
# -----------------------------------------------------------------------------
SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
REPO_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"
ENV_BAT="$REPO_ROOT/env.bat"
{
    printf '@echo off\r\n'
    printf 'set KEY_VAULT_URL=https://%s.vault.azure.net\r\n' "$KeyVaultName"
} > "$ENV_BAT"
echo "[OK] Created $ENV_BAT"

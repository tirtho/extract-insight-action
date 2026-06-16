#!/usr/bin/env bash
# =============================================================================
# Hardens the EIA Azure infrastructure for production.
# Mirrors 6.operation-prod.ps1.
#
# Locks the platform down to private networking:
#   1. Creates a single VNet with three subnets (private endpoints,
#      App Service integration, Function integration).
#   2. Creates the minimum set of Private DNS zones + Private Endpoints so
#      every component (Function Apps, Web App, Foundry Agents) can reach the
#      backing services over the VNet only.
#   3. Adds regional VNet integration to the Web App and all Function Apps,
#      routes their outbound traffic through the VNet, and disables public
#      inbound access on the Function Apps (outbound still works so they can
#      poll the M365 mailbox via Graph).
#   4. Disables public network access on Key Vault, Cosmos DB, AI Foundry and
#      Content Understanding (Service Bus only if Premium). Storage is set to
#      deny-by-default with a resource-instance rule that trusts only the
#      Content Understanding account, so CU (a PaaS outside the VNet) can still
#      read attachment blobs by URL via its managed identity.
#   5. Optionally (prompted) punches a temporary hole for the operator's laptop
#      public IP + grants the signed-in user data-plane RBAC. Answer "no" and
#      the script removes that access and fully locks the resources down.
#   6. Refreshes the Key Vault references in the Web App / Function App settings
#      so the platform re-resolves them over the private endpoint.
#
# Idempotent - every step checks current state and skips work that is already
# in the desired configuration. Run after 1.deploy-infrastructure.sh.
#
# NOTE: The Web App keeps its public inbound endpoint (it serves the UI); only
# its OUTBOUND path is moved onto the VNet so it can still reach the now-private
# backing services.
#
# Requires: bash 4+, az CLI, curl.
#
# Usage:
#   ./6.operation-prod.sh <suffix>
#       [--environment ENV]         (default prod)
#       [--skip-steps LIST]         comma/space list of step numbers or aliases:
#                                   1/Vnet,2/Dns,3/PrivateEndpoints,
#                                   4/VnetIntegration,5/LockPublic,
#                                   6/TestAccess,7/KVRefresh
#       [--rollback]                undo ALL hardening: delete VNet/subnets/
#                                   private endpoints/DNS zones, restore public
#                                   network access, remove VNet integration.
#                                   Prompts for confirmation; ignores --skip-steps.
# =============================================================================
set -uo pipefail

# -----------------------------------------------------------------------------
# Parse args
# -----------------------------------------------------------------------------
SUFFIX=""
ENVIRONMENT="${ENVIRONMENT:-}"
SKIP_STEPS_RAW=""
ROLLBACK=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --environment) ENVIRONMENT="$2";    shift 2 ;;
        --skip-steps)  SKIP_STEPS_RAW="$2"; shift 2 ;;
        --rollback)    ROLLBACK=1;          shift ;;
        -h|--help)
            sed -n '2,42p' "$0"
            exit 0
            ;;
        *)
            if [[ -z "$SUFFIX" ]]; then
                SUFFIX="$1"
            else
                echo "[ERROR] Unknown argument: $1" >&2
                exit 1
            fi
            shift
            ;;
    esac
done

command -v az   >/dev/null 2>&1 || { echo "[ERROR] Azure CLI is not installed." >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "[ERROR] 'curl' is required." >&2; exit 1; }

# -----------------------------------------------------------------------------
# Inputs (prompt for any not supplied)
# -----------------------------------------------------------------------------
read -r -p "Enter location [default: centralus, example: centralus]: " LOCATION_INPUT
LOCATION="$(echo "${LOCATION_INPUT:-centralus}" | tr '[:upper:]' '[:lower:]' | xargs)"

if [[ -z "${ENVIRONMENT// }" ]]; then
    read -r -p "Enter environment [default: prod, example: prod]: " ENV_INPUT
    ENVIRONMENT="$(echo "${ENV_INPUT:-prod}" | tr '[:upper:]' '[:lower:]' | xargs)"
else
    ENVIRONMENT="$(echo "$ENVIRONMENT" | tr '[:upper:]' '[:lower:]' | xargs)"
fi

if [[ -z "${SUFFIX// }" ]]; then
    read -r -p "Enter suffix [default: 1, example: 1]: " SUFFIX_INPUT
    SUFFIX="$(echo "${SUFFIX_INPUT:-1}" | xargs)"
else
    SUFFIX="$(echo "$SUFFIX" | xargs)"
fi

PROJECT_NAME_FOR_LOG="${PROJECT_NAME:-eia}"
echo "[INFO] Deployment key: ${PROJECT_NAME_FOR_LOG}-${ENVIRONMENT}-${SUFFIX} (location: ${LOCATION})"

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
# Returns the trimmed stdout of an az query, or '' on failure.
az_value() {
    az "$@" 2>/dev/null | tr -d '\r' | xargs || true
}

# Creates a private endpoint with retry + backoff. Cognitive Services accounts
# (AI Foundry, Content Understanding) intermittently return transient errors
# (InvalidResponseFromPrivateLinkService, RequestConflict "provisioning state is
# not terminal") when PEs are created back-to-back. A failed attempt can leave
# the PE in a 'Failed' state, so we delete any non-'Succeeded' remnant before
# each (re)try. Returns 0 on success, 1 on exhausted retries.
create_pe_with_retry() {
    local pe_name="$1" pe_rid="$2" pe_group="$3"
    local max_attempts=5 delay=20 attempt state
    for ((attempt=1; attempt<=max_attempts; attempt++)); do
        state="$(az_value network private-endpoint show --name "$pe_name" --resource-group "$ResourceGroupName" --query provisioningState -o tsv)"
        if [[ "$state" == "Succeeded" ]]; then
            return 0
        elif [[ -n "$state" ]]; then
            echo "    [INFO] Removing '$pe_name' (state=$state) before retry"
            az network private-endpoint delete --name "$pe_name" --resource-group "$ResourceGroupName" --output none 2>/dev/null || true
        fi

        if az network private-endpoint create --name "$pe_name" \
            --resource-group "$ResourceGroupName" --vnet-name "$VnetName" --subnet "$SubnetPe" \
            --private-connection-resource-id "$pe_rid" --group-id "$pe_group" \
            --connection-name "${pe_name}-conn" --location "$LOCATION" --output none 2>/dev/null; then
            return 0
        fi

        if [[ $attempt -lt $max_attempts ]]; then
            echo "    [WARN] Create of '$pe_name' failed (attempt $attempt/$max_attempts); retrying in ${delay}s"
            sleep "$delay"
        else
            echo "  [ERROR] Failed to create '$pe_name' after $max_attempts attempts" >&2
        fi
    done
    return 1
}

# Waits until every private endpoint reports a provisioned + approved connection
# and the Key Vault private DNS zone has a resolvable A-record. Gates the KV
# reference refresh so the platform resolves over the private path.
wait_private_endpoints_ready() {
    local resource_group="$1" kv_zone="$2"; shift 2
    local pe_names=("$@")
    local max_attempts=20 delay=15

    if [[ ${#pe_names[@]} -eq 0 ]]; then
        echo "  [INFO] No private endpoints to wait for."
        return 0
    fi

    local attempt
    for ((attempt=1; attempt<=max_attempts; attempt++)); do
        local pending=()
        local name prov conn
        for name in "${pe_names[@]}"; do
            prov="$(az_value network private-endpoint show --name "$name" --resource-group "$resource_group" --query provisioningState -o tsv)"
            conn="$(az_value network private-endpoint show --name "$name" --resource-group "$resource_group" --query 'privateLinkServiceConnections[0].privateLinkServiceConnectionState.status' -o tsv)"
            if [[ "$prov" != "Succeeded" || "$conn" != "Approved" ]]; then
                pending+=("$name (provisioning=$prov, connection=$conn)")
            fi
        done

        local kv_record
        kv_record="$(az_value network private-dns record-set a list --zone-name "$kv_zone" --resource-group "$resource_group" --query '[0].aRecords[0].ipv4Address' -o tsv)"
        if [[ -z "$kv_record" ]]; then
            pending+=("Key Vault DNS A-record not yet populated in $kv_zone")
        fi

        if [[ ${#pending[@]} -eq 0 ]]; then
            echo "  [OK] All private endpoints provisioned, approved, and DNS-resolvable"
            return 0
        fi

        echo "  [INFO] Waiting for private endpoints to be ready (attempt $attempt/$max_attempts)"
        local p
        for p in "${pending[@]}"; do echo "    - $p"; done

        [[ $attempt -lt $max_attempts ]] && sleep "$delay"
    done

    echo "  [WARNING] Private endpoints not fully ready after $max_attempts attempts; proceeding anyway."
    return 0
}

# Forces App Service / Functions to re-resolve Key Vault references in app
# settings. Needed after KV public access is disabled. Retries until resolved.
invoke_config_reference_refresh() {
    local resource_id="$1" display_name="$2"
    local max_attempts=6 delay=10
    local attempt
    for ((attempt=1; attempt<=max_attempts; attempt++)); do
        local out rc=0
        out="$(az rest --method POST \
            --uri "https://management.azure.com${resource_id}/config/configreferences/appsettings/refresh?api-version=2022-03-01" \
            -o json 2>/dev/null)" || rc=$?

        if [[ $rc -ne 0 ]]; then
            echo "  [WARNING] Key Vault reference refresh failed for $display_name (attempt $attempt/$max_attempts)"
        else
            local unresolved
            unresolved="$(echo "$out" | jq -r '[.value[]? | select(.properties.status != "Resolved")] | length' 2>/dev/null || echo "0")"
            if [[ "$unresolved" == "0" ]]; then
                echo "  [SUCCESS] Key Vault references refreshed for $display_name"
                return 0
            fi
            echo "  [INFO] $display_name still has unresolved Key Vault references (attempt $attempt/$max_attempts)"
        fi

        [[ $attempt -lt $max_attempts ]] && sleep "$delay"
    done

    echo "  [WARNING] Key Vault references not fully resolved for $display_name after $max_attempts attempts"
    return 0
}

# -----------------------------------------------------------------------------
# Configuration (must match 1.deploy-infrastructure.sh)
# -----------------------------------------------------------------------------
PROJECT_NAME="${PROJECT_NAME:-eia}"
PROJ_CLEAN="${PROJECT_NAME//-/}"
ResourceGroupName="rg-${PROJECT_NAME}-${ENVIRONMENT}-${SUFFIX}"
StorageAccountName="st${PROJ_CLEAN}${ENVIRONMENT}${SUFFIX}"
CosmosDbAccountName="cosmos-${PROJECT_NAME}-${ENVIRONMENT}-${SUFFIX}"
ContentUnderstandingName="cu-${PROJECT_NAME}-${ENVIRONMENT}-${SUFFIX}"
AiFoundryName="oai-${PROJECT_NAME}-${ENVIRONMENT}-${SUFFIX}"
KeyVaultName="kv-${PROJECT_NAME}-${ENVIRONMENT}-${SUFFIX}"
ServiceBusNamespace="sb-${PROJECT_NAME}-${ENVIRONMENT}-${SUFFIX}"
FuncMailboxName="func-mailbox-${PROJECT_NAME}-${ENVIRONMENT}-${SUFFIX}"
FuncQueueDbName="func-queuedb-${PROJECT_NAME}-${ENVIRONMENT}-${SUFFIX}"
FuncCuQueueDbName="func-cuqueuedb-${PROJECT_NAME}-${ENVIRONMENT}-${SUFFIX}"
WebAppName="app-${PROJECT_NAME}-${ENVIRONMENT}-${SUFFIX}"

# --- Networking layout (single VNet, three subnets) ---
VnetName="vnet-${PROJECT_NAME}-${ENVIRONMENT}-${SUFFIX}"
VnetAddressSpace="10.0.0.0/16"
SubnetPe="snet-privateendpoints"
SubnetPeCidr="10.0.1.0/24"
SubnetAppService="snet-appservice"
SubnetAppServiceCidr="10.0.2.0/24"
SubnetFunctions="snet-functions"
SubnetFunctionsCidr="10.0.3.0/24"

FUNCTION_APPS=("$FuncMailboxName" "$FuncQueueDbName" "$FuncCuQueueDbName")

# --- Parse skip-steps into flags ---
skip_step_1=0; skip_step_2=0; skip_step_3=0; skip_step_4=0
skip_step_5=0; skip_step_6=0; skip_step_7=0
if [[ -n "$SKIP_STEPS_RAW" ]]; then
    IFS=', ' read -r -a _skips <<< "$SKIP_STEPS_RAW"
    for s in "${_skips[@]}"; do
        case "$s" in
            1|Vnet)             skip_step_1=1 ;;
            2|Dns)              skip_step_2=1 ;;
            3|PrivateEndpoints) skip_step_3=1 ;;
            4|VnetIntegration)  skip_step_4=1 ;;
            5|LockPublic)       skip_step_5=1 ;;
            6|TestAccess)       skip_step_6=1 ;;
            7|KVRefresh)        skip_step_7=1 ;;
        esac
    done
fi

CHANGES=0

# -----------------------------------------------------------------------------
# Banner
# -----------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  Production Hardening: $PROJECT_NAME ($ENVIRONMENT)"
echo "  Resource Group: $ResourceGroupName"
echo "============================================================"
echo ""

# -----------------------------------------------------------------------------
# Prerequisites
# -----------------------------------------------------------------------------
echo "[INFO] Checking prerequisites..."

acct_state="$(az_value account show --query state -o tsv)"
if [[ "$acct_state" != "Enabled" ]]; then
    echo "[ERROR] Not logged in to Azure CLI. Run 'az login' first." >&2
    exit 1
fi

CurrentUserId="$(az_value ad signed-in-user show --query id -o tsv)"
if [[ -z "$CurrentUserId" ]]; then
    echo "[ERROR] Could not determine current user. Run 'az login' first." >&2
    exit 1
fi
CurrentUserName="$(az_value ad signed-in-user show --query userPrincipalName -o tsv)"
echo "[OK] Logged in as: $CurrentUserName ($CurrentUserId)"

# Verify the backing resources exist (created by 1.deploy-infrastructure.sh)
StorageAccountId="$(az_value storage account show --name "$StorageAccountName" --resource-group "$ResourceGroupName" --query id -o tsv)"
CosmosDbAccountId="$(az_value cosmosdb show --name "$CosmosDbAccountName" --resource-group "$ResourceGroupName" --query id -o tsv)"
KeyVaultId="$(az_value keyvault show --name "$KeyVaultName" --resource-group "$ResourceGroupName" --query id -o tsv)"
ContentUnderstandingId="$(az_value cognitiveservices account show --name "$ContentUnderstandingName" --resource-group "$ResourceGroupName" --query id -o tsv)"
AiFoundryId="$(az_value cognitiveservices account show --name "$AiFoundryName" --resource-group "$ResourceGroupName" --query id -o tsv)"
ServiceBusId="$(az_value servicebus namespace show --name "$ServiceBusNamespace" --resource-group "$ResourceGroupName" --query id -o tsv)"
TenantId="$(az_value account show --query tenantId -o tsv)"

for pair in "$StorageAccountName:$StorageAccountId" "$CosmosDbAccountName:$CosmosDbAccountId" "$KeyVaultName:$KeyVaultId"; do
    pname="${pair%%:*}"; pid="${pair#*:}"
    if [[ -z "$pid" ]]; then
        echo "[ERROR] Required resource '$pname' not found in '$ResourceGroupName'." >&2
        echo "  Run 1.deploy-infrastructure.sh $SUFFIX first." >&2
        exit 1
    fi
done
echo "[OK] Core resources verified"

# Service Bus Premium is required for private endpoints / public-access lockdown.
ServiceBusSku=""
if [[ -n "$ServiceBusId" ]]; then
    ServiceBusSku="$(az_value servicebus namespace show --name "$ServiceBusNamespace" --resource-group "$ResourceGroupName" --query sku.name -o tsv)"
fi
ServiceBusSupportsPrivate=0
[[ "$ServiceBusSku" == "Premium" ]] && ServiceBusSupportsPrivate=1
if [[ -n "$ServiceBusId" && $ServiceBusSupportsPrivate -eq 0 ]]; then
    echo "[WARNING] Service Bus '$ServiceBusNamespace' is SKU '$ServiceBusSku'."
    echo "          Private endpoints and public-access lockdown require the Premium SKU."
    echo "          Service Bus hardening will be SKIPPED; it stays RBAC/SAS-secured on its public endpoint."
    echo "          To fully harden it, upgrade first:"
    echo "            az servicebus namespace update -n $ServiceBusNamespace -g $ResourceGroupName --sku Premium"
fi

# =============================================================================
# ROLLBACK: Undo all hardening (delete VNet/PEs/DNS, restore public access)
# =============================================================================
# Reverses the hardening in the opposite order it was applied: first re-open the
# public endpoints and detach VNet integration, then delete the private
# endpoints, DNS zones/links, and finally the VNet. RBAC role assignments are
# intentionally left in place.
if [[ $ROLLBACK -eq 1 ]]; then
    echo ""
    echo "============================================================"
    echo "  ROLLBACK: Undo production hardening for $ResourceGroupName"
    echo "============================================================"
    echo ""
    echo "This will DELETE the VNet '$VnetName', all its subnets, every"
    echo "private endpoint and private DNS zone, and RE-ENABLE public"
    echo "network access on Storage, Cosmos DB, Key Vault, AI Foundry,"
    echo "Content Understanding and (if Premium) Service Bus."
    echo ""

    read -r -p "Type 'rollback' to proceed (anything else cancels): " CONFIRM
    CONFIRM="$(echo "$CONFIRM" | tr '[:upper:]' '[:lower:]' | xargs)"
    if [[ "$CONFIRM" != "rollback" ]]; then
        echo "[INFO] Rollback cancelled. No changes made."
        exit 0
    fi

    # Deterministic names of everything hardening created (mirrors Steps 1-3).
    RB_PE_NAMES=(
        "pe-blob-${ENVIRONMENT}-${SUFFIX}"
        "pe-queue-${ENVIRONMENT}-${SUFFIX}"
        "pe-table-${ENVIRONMENT}-${SUFFIX}"
        "pe-cosmos-${ENVIRONMENT}-${SUFFIX}"
        "pe-kv-${ENVIRONMENT}-${SUFFIX}"
    )
    [[ -n "$AiFoundryId" ]]          && RB_PE_NAMES+=("pe-foundry-${ENVIRONMENT}-${SUFFIX}")
    [[ -n "$ContentUnderstandingId" ]] && RB_PE_NAMES+=("pe-cu-${ENVIRONMENT}-${SUFFIX}")
    [[ -n "$ServiceBusId" && $ServiceBusSupportsPrivate -eq 1 ]] && RB_PE_NAMES+=("pe-sb-${ENVIRONMENT}-${SUFFIX}")

    RB_DNS_ZONES=(
        'privatelink.blob.core.windows.net'
        'privatelink.queue.core.windows.net'
        'privatelink.table.core.windows.net'
        'privatelink.documents.azure.com'
        'privatelink.vaultcore.azure.net'
        'privatelink.cognitiveservices.azure.com'
        'privatelink.openai.azure.com'
        'privatelink.services.ai.azure.com'
    )
    [[ -n "$ServiceBusId" && $ServiceBusSupportsPrivate -eq 1 ]] && RB_DNS_ZONES+=('privatelink.servicebus.windows.net')

    # --- R1: Re-enable public network access on backing resources ------------
    echo ""
    echo ">>> Rollback 1: Re-enable Public Network Access"

    if [[ -n "$ContentUnderstandingId" && -n "$TenantId" ]]; then
        az storage account network-rule remove --account-name "$StorageAccountName" --resource-group "$ResourceGroupName" \
            --resource-id "$ContentUnderstandingId" --tenant-id "$TenantId" --output none 2>/dev/null || true
    fi
    az storage account update --name "$StorageAccountName" --resource-group "$ResourceGroupName" \
        --public-network-access Enabled --default-action Allow --output none 2>/dev/null || true
    echo "  [SUCCESS] Storage '$StorageAccountName' public access restored (default Allow)"

    az cosmosdb update --name "$CosmosDbAccountName" --resource-group "$ResourceGroupName" \
        --public-network-access Enabled --ip-range-filter "" --output none 2>/dev/null || true
    echo "  [SUCCESS] Cosmos DB '$CosmosDbAccountName' public access restored"

    az keyvault update --name "$KeyVaultName" --resource-group "$ResourceGroupName" \
        --public-network-access Enabled --default-action Allow --output none 2>/dev/null || true
    echo "  [SUCCESS] Key Vault '$KeyVaultName' public access restored (default Allow)"

    if [[ -n "$AiFoundryId" ]]; then
        az resource update --ids "$AiFoundryId" --set properties.publicNetworkAccess=Enabled properties.networkAcls.defaultAction=Allow --output none 2>/dev/null || true
        echo "  [SUCCESS] AI Foundry '$AiFoundryName' public access restored"
    fi
    if [[ -n "$ContentUnderstandingId" ]]; then
        az resource update --ids "$ContentUnderstandingId" --set properties.publicNetworkAccess=Enabled properties.networkAcls.defaultAction=Allow --output none 2>/dev/null || true
        echo "  [SUCCESS] Content Understanding '$ContentUnderstandingName' public access restored"
    fi
    if [[ -n "$ServiceBusId" && $ServiceBusSupportsPrivate -eq 1 ]]; then
        az servicebus namespace update --name "$ServiceBusNamespace" --resource-group "$ResourceGroupName" --public-network-access Enabled --output none 2>/dev/null || true
        echo "  [SUCCESS] Service Bus '$ServiceBusNamespace' public access restored"
    fi

    # --- R2: Restore Function inbound + remove VNet integration ---------------
    echo ""
    echo ">>> Rollback 2: Restore App Inbound + Remove VNet Integration"

    for fa in "${FUNCTION_APPS[@]}"; do
        fa_exists="$(az_value functionapp show --name "$fa" --resource-group "$ResourceGroupName" --query name -o tsv)"
        [[ -z "$fa_exists" ]] && continue
        az functionapp update --name "$fa" --resource-group "$ResourceGroupName" --set publicNetworkAccess=Enabled --output none 2>/dev/null || true
        az functionapp config set --name "$fa" --resource-group "$ResourceGroupName" --vnet-route-all-enabled false --output none 2>/dev/null || true
        az functionapp vnet-integration remove --name "$fa" --resource-group "$ResourceGroupName" --output none 2>/dev/null || true
        echo "  [SUCCESS] Function App '$fa' public inbound restored, VNet integration removed"
    done

    web_app_exists="$(az_value webapp show --name "$WebAppName" --resource-group "$ResourceGroupName" --query name -o tsv)"
    if [[ -n "$web_app_exists" ]]; then
        az webapp config set --name "$WebAppName" --resource-group "$ResourceGroupName" --vnet-route-all-enabled false --output none 2>/dev/null || true
        az webapp vnet-integration remove --name "$WebAppName" --resource-group "$ResourceGroupName" --output none 2>/dev/null || true
        echo "  [SUCCESS] Web App '$WebAppName' VNet integration removed"
    fi

    # --- R3: Delete private endpoints (also removes their DNS zone groups) ----
    echo ""
    echo ">>> Rollback 3: Delete Private Endpoints"

    # Submit all PE deletes in parallel (--no-wait), then wait for them to clear.
    RB_PENDING_PE=()
    for pe_name in "${RB_PE_NAMES[@]}"; do
        exists="$(az_value network private-endpoint show --name "$pe_name" --resource-group "$ResourceGroupName" --query name -o tsv)"
        if [[ -n "$exists" ]]; then
            echo "  [INFO] Submitting delete of private endpoint '$pe_name'"
            az network private-endpoint delete --name "$pe_name" --resource-group "$ResourceGroupName" --no-wait --output none 2>/dev/null || true
            RB_PENDING_PE+=("$pe_name")
        else
            echo "  [OK] Private endpoint '$pe_name' not present"
        fi
    done
    for pe_name in "${RB_PENDING_PE[@]}"; do
        for ((attempt=1; attempt<=30; attempt++)); do
            still="$(az_value network private-endpoint show --name "$pe_name" --resource-group "$ResourceGroupName" --query name -o tsv)"
            [[ -z "$still" ]] && break
            sleep 5
        done
        echo "  [SUCCESS] Deleted private endpoint '$pe_name'"
    done

    # --- R4: Delete private DNS VNet links + zones ----------------------------
    echo ""
    echo ">>> Rollback 4: Delete Private DNS Zones + Links"

    link_name="link-$VnetName"

    # Determine which zones actually exist, so we only act on those.
    RB_EXISTING_ZONES=()
    for zone in "${RB_DNS_ZONES[@]}"; do
        zone_exists="$(az_value network private-dns zone show --name "$zone" --resource-group "$ResourceGroupName" --query name -o tsv)"
        if [[ -n "$zone_exists" ]]; then
            RB_EXISTING_ZONES+=("$zone")
        else
            echo "  [OK] DNS zone '$zone' not present"
        fi
    done

    # Phase 1: delete all VNet links in parallel (a zone can't be deleted while
    # it still has a link), then wait for them to clear.
    RB_PENDING_LINKS=()
    for zone in "${RB_EXISTING_ZONES[@]}"; do
        link_exists="$(az_value network private-dns link vnet show --name "$link_name" --zone-name "$zone" --resource-group "$ResourceGroupName" --query name -o tsv)"
        if [[ -n "$link_exists" ]]; then
            az network private-dns link vnet delete --name "$link_name" --zone-name "$zone" --resource-group "$ResourceGroupName" --yes --no-wait --output none 2>/dev/null || true
            RB_PENDING_LINKS+=("$zone")
        fi
    done
    for zone in "${RB_PENDING_LINKS[@]}"; do
        for ((attempt=1; attempt<=20; attempt++)); do
            still="$(az_value network private-dns link vnet show --name "$link_name" --zone-name "$zone" --resource-group "$ResourceGroupName" --query name -o tsv)"
            [[ -z "$still" ]] && break
            sleep 5
        done
    done

    # Phase 2: delete the now-unlinked zones in parallel, then wait.
    for zone in "${RB_EXISTING_ZONES[@]}"; do
        az network private-dns zone delete --name "$zone" --resource-group "$ResourceGroupName" --yes --no-wait --output none 2>/dev/null || true
    done
    for zone in "${RB_EXISTING_ZONES[@]}"; do
        for ((attempt=1; attempt<=20; attempt++)); do
            still="$(az_value network private-dns zone show --name "$zone" --resource-group "$ResourceGroupName" --query name -o tsv)"
            [[ -z "$still" ]] && break
            sleep 5
        done
        echo "  [SUCCESS] Deleted DNS zone '$zone' (and VNet link)"
    done

    # --- R5: Delete the VNet (removes all subnets) ---------------------------
    echo ""
    echo ">>> Rollback 5: Delete Virtual Network"

    vnet_exists="$(az_value network vnet show --name "$VnetName" --resource-group "$ResourceGroupName" --query name -o tsv)"
    if [[ -n "$vnet_exists" ]]; then
        az network vnet delete --name "$VnetName" --resource-group "$ResourceGroupName" --output none 2>/dev/null || true
        echo "  [SUCCESS] Deleted VNet '$VnetName' and its subnets"
    else
        echo "  [OK] VNet '$VnetName' not present"
    fi

    echo ""
    echo "[SUCCESS] Rollback complete. Platform restored to pre-hardening state."
    echo "  NOTE: RBAC role assignments were left untouched."
    echo ""
    exit 0
fi

# =============================================================================
# PRE-FLIGHT: Local testing access prompt + background RBAC grant
# =============================================================================
# Step 6 grants the signed-in user a large data-plane RBAC set, which is slow
# (many serial role-assignment calls) but completely independent of the VNet /
# private-endpoint / lockdown steps. So we ask the operator up front and, when
# granting, kick the role assignments off in a background subshell that runs
# while Steps 1-5 execute. The firewall-hole part still happens in Step 6 (it
# must follow Step 5's lockdown); here we only pre-start the RBAC work.
#
# Emits the role assignment set, one per line. Two encodings:
#   arm|<role>|<scope>
#   cosmos|<roleLabel>|<roleDefinitionId>|<accountName>|<resourceGroup>|<scope>
get_test_role_assignments() {
    local role
    for role in 'Storage Blob Data Contributor' 'Storage Blob Data Reader' \
                'Storage Queue Data Contributor' 'Storage Table Data Contributor' \
                'Storage Blob Data Owner' 'Storage Blob Delegator'; do
        echo "arm|${role}|${StorageAccountId}"
    done
    for role in 'Key Vault Secrets User' 'Key Vault Secrets Officer' 'Key Vault Certificates Officer' 'Key Vault Crypto Officer'; do
        echo "arm|${role}|${KeyVaultId}"
    done
    # Cosmos DB ARM (management-plane) roles: manage the account, read keys, etc.
    for role in 'Cosmos DB Account Reader Role' 'DocumentDB Account Contributor'; do
        echo "arm|${role}|${CosmosDbAccountId}"
    done
    # Cosmos DB DATA-plane roles: read/write items in containers. These live in a
    # SEPARATE RBAC system (az cosmosdb sql role assignment) - the ARM roles above
    # do NOT grant data access, so without these the user cannot read/write items.
    echo "cosmos|Cosmos DB Built-in Data Reader|00000000-0000-0000-0000-000000000001|${CosmosDbAccountName}|${ResourceGroupName}|${CosmosDbAccountId}"
    echo "cosmos|Cosmos DB Built-in Data Contributor|00000000-0000-0000-0000-000000000002|${CosmosDbAccountName}|${ResourceGroupName}|${CosmosDbAccountId}"
    if [[ -n "$AiFoundryId" ]]; then
        for role in 'Cognitive Services User' 'Cognitive Services OpenAI User' 'Azure AI Developer'; do
            echo "arm|${role}|${AiFoundryId}"
        done
    fi
    if [[ -n "$ContentUnderstandingId" ]]; then
        echo "arm|Cognitive Services User|${ContentUnderstandingId}"
    fi
}

grant_access=0
MyPublicIp=""
ROLE_ASSIGNMENTS=()
RBAC_BG_PID=""
RBAC_BG_LOG=""
if [[ $skip_step_6 -eq 0 ]]; then
    echo ""
    echo ">>> Local Testing Access (asked up front)"
    echo "  This temporarily allows your laptop's public IP through the firewalls"
    echo "  and grants your signed-in user data-plane RBAC. Answer 'no' to remove"
    echo "  that access and keep the resources fully private."
    echo ""

    answer=""
    while [[ ! "$answer" =~ ^(yes|y|no|n)$ ]]; do
        read -r -p "Allow local testing access for $CurrentUserName ? (yes/no): " answer
        answer="$(echo "$answer" | tr '[:upper:]' '[:lower:]' | xargs)"
    done
    [[ "$answer" == "yes" || "$answer" == "y" ]] && grant_access=1

    MyPublicIp="$(curl -fsS --max-time 10 'https://api.ipify.org?format=text' 2>/dev/null | xargs || true)"
    if [[ -z "$MyPublicIp" ]]; then
        echo "  [WARNING] Could not detect public IP; firewall hole will be skipped."
    fi

    mapfile -t ROLE_ASSIGNMENTS < <(get_test_role_assignments)

    # When granting, start the (independent) RBAC creates in a background
    # subshell so they overlap with Steps 1-5. Output is captured to a temp log
    # and replayed when collected in Step 6.
    if [[ $grant_access -eq 1 ]]; then
        RBAC_BG_LOG="$(mktemp)"
        (
            created=0
            for entry in "${ROLE_ASSIGNMENTS[@]}"; do
                IFS='|' read -r atype f1 f2 f3 f4 f5 <<< "$entry"
                if [[ "$atype" == "cosmos" ]]; then
                    # f1=label f2=roleDefId f3=account f4=rg f5=scope
                    existing="$(az cosmosdb sql role assignment list --account-name "$f3" --resource-group "$f4" --query "[?principalId=='$CurrentUserId' && contains(roleDefinitionId, '$f2')] | [0].id" -o tsv 2>/dev/null)"
                    if [[ -n "$existing" ]]; then
                        echo "  [OK] $f1 already assigned"
                    else
                        az cosmosdb sql role assignment create --account-name "$f3" --resource-group "$f4" --role-definition-id "$f2" --principal-id "$CurrentUserId" --scope "$f5" --output none 2>/dev/null || true
                        echo "  [SUCCESS] Granted $f1"
                        created=$((created + 1))
                    fi
                    continue
                fi
                # arm: f1=role f2=scope
                role="$f1"; scope="$f2"
                [[ -z "$scope" ]] && continue
                existing="$(az role assignment list --assignee "$CurrentUserId" --role "$role" --scope "$scope" --query '[0].id' -o tsv 2>/dev/null)"
                if [[ -n "$existing" ]]; then
                    echo "  [OK] $role already assigned"
                else
                    az role assignment create --assignee "$CurrentUserId" --role "$role" --scope "$scope" --output none 2>/dev/null || true
                    echo "  [SUCCESS] Granted $role"
                    created=$((created + 1))
                fi
            done
            echo "GRANTED_COUNT=$created"
        ) > "$RBAC_BG_LOG" 2>&1 &
        RBAC_BG_PID=$!
        echo "  [INFO] Granting RBAC in the background while platform steps run..."
    fi
fi

# =============================================================================
# STEP 1: Virtual Network + Subnets
# =============================================================================
if [[ $skip_step_1 -eq 1 ]]; then
    echo ""
    echo ">>> Step 1: Virtual Network + Subnets"
    echo "  [SKIPPED] Step 1 skipped by --skip-steps"
else
    echo ""
    echo ">>> Step 1: Virtual Network + Subnets"

    existing_vnet="$(az_value network vnet show --name "$VnetName" --resource-group "$ResourceGroupName" --query name -o tsv)"
    if [[ -n "$existing_vnet" ]]; then
        echo "  [OK] VNet '$VnetName' already exists"
    else
        echo "  [INFO] Creating VNet '$VnetName' ($VnetAddressSpace)"
        az network vnet create --name "$VnetName" --resource-group "$ResourceGroupName" \
            --location "$LOCATION" --address-prefixes "$VnetAddressSpace" --output none 2>/dev/null || true
        ((CHANGES++)) || true
    fi

    # Subnet: private endpoints (network policies disabled so PEs can be created)
    existing_pe_subnet="$(az_value network vnet subnet show --name "$SubnetPe" --vnet-name "$VnetName" --resource-group "$ResourceGroupName" --query name -o tsv)"
    if [[ -n "$existing_pe_subnet" ]]; then
        echo "  [OK] Subnet '$SubnetPe' already exists"
    else
        echo "  [INFO] Creating subnet '$SubnetPe' ($SubnetPeCidr)"
        az network vnet subnet create --name "$SubnetPe" --vnet-name "$VnetName" \
            --resource-group "$ResourceGroupName" --address-prefixes "$SubnetPeCidr" \
            --private-endpoint-network-policies Disabled --output none 2>/dev/null || true
        ((CHANGES++)) || true
    fi

    # Subnet: App Service regional VNet integration (delegated to Microsoft.Web/serverFarms)
    existing_app_subnet="$(az_value network vnet subnet show --name "$SubnetAppService" --vnet-name "$VnetName" --resource-group "$ResourceGroupName" --query name -o tsv)"
    if [[ -n "$existing_app_subnet" ]]; then
        echo "  [OK] Subnet '$SubnetAppService' already exists"
    else
        echo "  [INFO] Creating subnet '$SubnetAppService' ($SubnetAppServiceCidr, delegated Microsoft.Web/serverFarms)"
        az network vnet subnet create --name "$SubnetAppService" --vnet-name "$VnetName" \
            --resource-group "$ResourceGroupName" --address-prefixes "$SubnetAppServiceCidr" \
            --delegations Microsoft.Web/serverFarms --output none 2>/dev/null || true
        ((CHANGES++)) || true
    fi

    # Subnet: Flex Consumption Functions VNet integration (delegated to Microsoft.App/environments)
    existing_func_subnet="$(az_value network vnet subnet show --name "$SubnetFunctions" --vnet-name "$VnetName" --resource-group "$ResourceGroupName" --query name -o tsv)"
    if [[ -n "$existing_func_subnet" ]]; then
        echo "  [OK] Subnet '$SubnetFunctions' already exists"
    else
        echo "  [INFO] Creating subnet '$SubnetFunctions' ($SubnetFunctionsCidr, delegated Microsoft.App/environments)"
        az network vnet subnet create --name "$SubnetFunctions" --vnet-name "$VnetName" \
            --resource-group "$ResourceGroupName" --address-prefixes "$SubnetFunctionsCidr" \
            --delegations Microsoft.App/environments --output none 2>/dev/null || true
        ((CHANGES++)) || true
    fi
fi

PeSubnetId="$(az_value network vnet subnet show --name "$SubnetPe" --vnet-name "$VnetName" --resource-group "$ResourceGroupName" --query id -o tsv)"

# =============================================================================
# STEP 2: Private DNS Zones + VNet links
# =============================================================================
DNS_ZONES=(
    'privatelink.blob.core.windows.net'
    'privatelink.queue.core.windows.net'
    'privatelink.table.core.windows.net'
    'privatelink.documents.azure.com'
    'privatelink.vaultcore.azure.net'
    'privatelink.cognitiveservices.azure.com'
    'privatelink.openai.azure.com'
    'privatelink.services.ai.azure.com'
)
[[ $ServiceBusSupportsPrivate -eq 1 ]] && DNS_ZONES+=('privatelink.servicebus.windows.net')

if [[ $skip_step_2 -eq 1 ]]; then
    echo ""
    echo ">>> Step 2: Private DNS Zones + VNet links"
    echo "  [SKIPPED] Step 2 skipped by --skip-steps"
else
    echo ""
    echo ">>> Step 2: Private DNS Zones + VNet links"

    link_name="link-$VnetName"

    # --- Phase 1: ensure all DNS zones exist (fast control-plane metadata) ----
    for zone in "${DNS_ZONES[@]}"; do
        existing_zone="$(az_value network private-dns zone show --name "$zone" --resource-group "$ResourceGroupName" --query name -o tsv)"
        if [[ -n "$existing_zone" ]]; then
            echo "  [OK] DNS zone '$zone' already exists"
        else
            echo "  [INFO] Creating DNS zone '$zone'"
            az network private-dns zone create --name "$zone" --resource-group "$ResourceGroupName" --output none 2>/dev/null || true
            ((CHANGES++)) || true
        fi
    done

    # --- Phase 2: submit all missing VNet links in parallel (--no-wait) --------
    # The links are independent and the slower part of this step, so fire them
    # all at once and wait for them together rather than blocking on each.
    PENDING_LINKS=()
    for zone in "${DNS_ZONES[@]}"; do
        existing_link="$(az_value network private-dns link vnet show --name "$link_name" --zone-name "$zone" --resource-group "$ResourceGroupName" --query name -o tsv)"
        if [[ -n "$existing_link" ]]; then
            echo "  [OK] VNet link for '$zone' already exists"
        else
            echo "  [INFO] Submitting VNet link for '$zone'"
            az network private-dns link vnet create --name "$link_name" --zone-name "$zone" \
                --resource-group "$ResourceGroupName" --virtual-network "$VnetName" --registration-enabled false --no-wait --output none 2>/dev/null || true
            PENDING_LINKS+=("$zone")
        fi
    done

    # --- Phase 3: wait for the submitted links to reach a terminal state -------
    for zone in "${PENDING_LINKS[@]}"; do
        link_ok=0
        for ((attempt=1; attempt<=20; attempt++)); do
            state="$(az_value network private-dns link vnet show --name "$link_name" --zone-name "$zone" --resource-group "$ResourceGroupName" --query provisioningState -o tsv)"
            if [[ "$state" == "Succeeded" ]]; then link_ok=1; break; fi
            if [[ "$state" == "Failed" || -z "$state" ]]; then break; fi
            sleep 5
        done
        if [[ $link_ok -eq 1 ]]; then
            echo "  [SUCCESS] VNet link for '$zone' created"
            ((CHANGES++)) || true
        else
            echo "  [ERROR] VNet link for '$zone' did not provision" >&2
        fi
    done
fi

# =============================================================================
# STEP 3: Private Endpoints (+ DNS zone groups)
# =============================================================================
# Parallel arrays: name / resource-id / group-id / space-separated zones.
PE_NAMES=();  PE_RIDS=();  PE_GROUPS=();  PE_ZONES=()
add_pe() { PE_NAMES+=("$1"); PE_RIDS+=("$2"); PE_GROUPS+=("$3"); PE_ZONES+=("$4"); }

add_pe "pe-blob-${ENVIRONMENT}-${SUFFIX}"  "$StorageAccountId" "blob"  "privatelink.blob.core.windows.net"
add_pe "pe-queue-${ENVIRONMENT}-${SUFFIX}" "$StorageAccountId" "queue" "privatelink.queue.core.windows.net"
add_pe "pe-table-${ENVIRONMENT}-${SUFFIX}" "$StorageAccountId" "table" "privatelink.table.core.windows.net"
add_pe "pe-cosmos-${ENVIRONMENT}-${SUFFIX}" "$CosmosDbAccountId" "Sql" "privatelink.documents.azure.com"
add_pe "pe-kv-${ENVIRONMENT}-${SUFFIX}"    "$KeyVaultId"       "vault" "privatelink.vaultcore.azure.net"
if [[ -n "$AiFoundryId" ]]; then
    add_pe "pe-foundry-${ENVIRONMENT}-${SUFFIX}" "$AiFoundryId" "account" "privatelink.cognitiveservices.azure.com privatelink.openai.azure.com privatelink.services.ai.azure.com"
fi
if [[ -n "$ContentUnderstandingId" ]]; then
    add_pe "pe-cu-${ENVIRONMENT}-${SUFFIX}" "$ContentUnderstandingId" "account" "privatelink.cognitiveservices.azure.com privatelink.openai.azure.com"
fi
if [[ -n "$ServiceBusId" && $ServiceBusSupportsPrivate -eq 1 ]]; then
    add_pe "pe-sb-${ENVIRONMENT}-${SUFFIX}" "$ServiceBusId" "namespace" "privatelink.servicebus.windows.net"
fi

# Names of PEs that have a backing resource id (for the readiness gate later).
ACTIVE_PE_NAMES=()
for i in "${!PE_NAMES[@]}"; do
    [[ -n "${PE_RIDS[$i]}" ]] && ACTIVE_PE_NAMES+=("${PE_NAMES[$i]}")
done

if [[ $skip_step_3 -eq 1 ]]; then
    echo ""
    echo ">>> Step 3: Private Endpoints"
    echo "  [SKIPPED] Step 3 skipped by --skip-steps"
elif [[ -z "$PeSubnetId" ]]; then
    echo ""
    echo ">>> Step 3: Private Endpoints"
    echo "  [ERROR] Private-endpoint subnet not found. Run Step 1 first." >&2
else
    echo ""
    echo ">>> Step 3: Private Endpoints"

    # --- Phase 1: submit all missing PE creates in parallel (--no-wait) -------
    # The private endpoints are independent, so we fire every create at once and
    # let Azure provision them concurrently instead of blocking on each. Any that
    # fail transiently (common on Cognitive Services accounts) are recreated
    # serially with backoff in Phase 2.
    PENDING_PE_IDX=()
    for i in "${!PE_NAMES[@]}"; do
        pe_name="${PE_NAMES[$i]}"; pe_rid="${PE_RIDS[$i]}"; pe_group="${PE_GROUPS[$i]}"
        [[ -z "$pe_rid" ]] && continue

        # Treat only a 'Succeeded' PE as already-present; a 'Failed' remnant from a
        # prior transient error is deleted and resubmitted rather than skipped.
        pe_state="$(az_value network private-endpoint show --name "$pe_name" --resource-group "$ResourceGroupName" --query provisioningState -o tsv)"
        if [[ "$pe_state" == "Succeeded" ]]; then
            echo "  [OK] Private endpoint '$pe_name' already exists"
            continue
        fi
        if [[ -n "$pe_state" ]]; then
            echo "    [INFO] Removing '$pe_name' (state=$pe_state) before resubmit"
            az network private-endpoint delete --name "$pe_name" --resource-group "$ResourceGroupName" --output none 2>/dev/null || true
        fi

        echo "  [INFO] Submitting private endpoint '$pe_name' (group: $pe_group)"
        az network private-endpoint create --name "$pe_name" \
            --resource-group "$ResourceGroupName" --vnet-name "$VnetName" --subnet "$SubnetPe" \
            --private-connection-resource-id "$pe_rid" --group-id "$pe_group" \
            --connection-name "${pe_name}-conn" --location "$LOCATION" --no-wait --output none 2>/dev/null || true
        PENDING_PE_IDX+=("$i")
    done

    # --- Phase 2: wait for the submitted PEs to reach a terminal state --------
    # Because all creates were submitted up front, the total wait is roughly the
    # slowest single PE rather than the sum of all of them.
    for i in "${PENDING_PE_IDX[@]}"; do
        pe_name="${PE_NAMES[$i]}"; pe_rid="${PE_RIDS[$i]}"; pe_group="${PE_GROUPS[$i]}"
        pe_ok=0
        for ((attempt=1; attempt<=30; attempt++)); do
            state="$(az_value network private-endpoint show --name "$pe_name" --resource-group "$ResourceGroupName" --query provisioningState -o tsv)"
            if [[ "$state" == "Succeeded" ]]; then pe_ok=1; break; fi
            if [[ "$state" == "Failed" || -z "$state" ]]; then
                echo "  [WARN] '$pe_name' state='$state'; recreating with retry"
                if create_pe_with_retry "$pe_name" "$pe_rid" "$pe_group"; then pe_ok=1; fi
                break
            fi
            sleep 10
        done
        if [[ $pe_ok -eq 1 ]]; then
            echo "  [SUCCESS] Private endpoint '$pe_name' provisioned"
            ((CHANGES++)) || true
        else
            echo "  [ERROR] Private endpoint '$pe_name' did not provision" >&2
        fi
    done

    # --- Phase 3: DNS zone groups for every provisioned PE (idempotent) -------
    for i in "${!PE_NAMES[@]}"; do
        pe_name="${PE_NAMES[$i]}"; pe_rid="${PE_RIDS[$i]}"
        read -r -a zones <<< "${PE_ZONES[$i]}"
        [[ -z "$pe_rid" ]] && continue

        pe_state="$(az_value network private-endpoint show --name "$pe_name" --resource-group "$ResourceGroupName" --query provisioningState -o tsv)"
        if [[ "$pe_state" != "Succeeded" ]]; then
            echo "  [SKIP] DNS zone group for '$pe_name' (PE not provisioned)"
            continue
        fi

        # DNS zone group (idempotent): one group per PE, one config entry per zone.
        group_name="${pe_name}-zg"
        existing_zg="$(az_value network private-endpoint dns-zone-group list --endpoint-name "$pe_name" --resource-group "$ResourceGroupName" --query '[0].name' -o tsv)"
        if [[ -n "$existing_zg" ]]; then
            echo "  [OK] DNS zone group for '$pe_name' already exists"
        else
            first_zone="${zones[0]}"
            az network private-endpoint dns-zone-group create \
                --name "$group_name" --endpoint-name "$pe_name" --resource-group "$ResourceGroupName" \
                --private-dns-zone "$first_zone" --zone-name "${first_zone//./-}" --output none 2>/dev/null || true
            for ((z=1; z<${#zones[@]}; z++)); do
                zn="${zones[$z]}"
                az network private-endpoint dns-zone-group add \
                    --name "$group_name" --endpoint-name "$pe_name" --resource-group "$ResourceGroupName" \
                    --private-dns-zone "$zn" --zone-name "${zn//./-}" --output none 2>/dev/null || true
            done
            echo "  [SUCCESS] DNS zone group for '$pe_name' created"
            ((CHANGES++)) || true
        fi
    done
fi

# =============================================================================
# STEP 4: VNet Integration (Web App + Function Apps) + Functions inbound lockdown
# =============================================================================
if [[ $skip_step_4 -eq 1 ]]; then
    echo ""
    echo ">>> Step 4: VNet Integration + Functions Lockdown"
    echo "  [SKIPPED] Step 4 skipped by --skip-steps"
else
    echo ""
    echo ">>> Step 4: VNet Integration + Functions Lockdown"

    AppSubnetId="$(az_value network vnet subnet show --name "$SubnetAppService" --vnet-name "$VnetName" --resource-group "$ResourceGroupName" --query id -o tsv)"
    FuncSubnetId="$(az_value network vnet subnet show --name "$SubnetFunctions" --vnet-name "$VnetName" --resource-group "$ResourceGroupName" --query id -o tsv)"

    # --- Web App: outbound VNet integration only (keep public inbound for the UI) ---
    web_app_exists="$(az_value webapp show --name "$WebAppName" --resource-group "$ResourceGroupName" --query name -o tsv)"
    if [[ -z "$web_app_exists" ]]; then
        echo "  [WARNING] Web App '$WebAppName' not found. Skipping."
    elif [[ -z "$AppSubnetId" ]]; then
        echo "  [WARNING] App Service subnet not found. Skipping Web App integration."
    else
        current_web_subnet="$(az_value webapp show --name "$WebAppName" --resource-group "$ResourceGroupName" --query virtualNetworkSubnetId -o tsv)"
        if [[ "$current_web_subnet" == "$AppSubnetId" ]]; then
            echo "  [OK] Web App '$WebAppName' already VNet-integrated"
        else
            echo "  [INFO] Adding VNet integration to Web App '$WebAppName'"
            az webapp vnet-integration add --name "$WebAppName" --resource-group "$ResourceGroupName" \
                --vnet "$VnetName" --subnet "$SubnetAppService" --output none 2>/dev/null || true
            ((CHANGES++)) || true
        fi
        route_all="$(az_value webapp config show --name "$WebAppName" --resource-group "$ResourceGroupName" --query vnetRouteAllEnabled -o tsv)"
        if [[ "$route_all" != "true" ]]; then
            az webapp config set --name "$WebAppName" --resource-group "$ResourceGroupName" --vnet-route-all-enabled true --output none 2>/dev/null || true
            echo "  [SUCCESS] Web App outbound routed through VNet"
            ((CHANGES++)) || true
        fi
    fi

    # --- Function Apps: outbound VNet integration + disable public inbound ---
    for fa in "${FUNCTION_APPS[@]}"; do
        fa_exists="$(az_value functionapp show --name "$fa" --resource-group "$ResourceGroupName" --query name -o tsv)"
        if [[ -z "$fa_exists" ]]; then
            echo "  [WARNING] Function App '$fa' not found. Skipping."
            continue
        fi
        if [[ -z "$FuncSubnetId" ]]; then
            echo "  [WARNING] Functions subnet not found. Skipping Function App integration."
            break
        fi

        current_fa_subnet="$(az_value functionapp show --name "$fa" --resource-group "$ResourceGroupName" --query virtualNetworkSubnetId -o tsv)"
        if [[ "$current_fa_subnet" == "$FuncSubnetId" ]]; then
            echo "  [OK] Function App '$fa' already VNet-integrated"
        else
            echo "  [INFO] Adding VNet integration to Function App '$fa'"
            az functionapp vnet-integration add --name "$fa" --resource-group "$ResourceGroupName" \
                --vnet "$VnetName" --subnet "$SubnetFunctions" --output none 2>/dev/null || true
            ((CHANGES++)) || true
        fi

        fa_route_all="$(az_value functionapp config show --name "$fa" --resource-group "$ResourceGroupName" --query vnetRouteAllEnabled -o tsv)"
        if [[ "$fa_route_all" != "true" ]]; then
            az functionapp config set --name "$fa" --resource-group "$ResourceGroupName" --vnet-route-all-enabled true --output none 2>/dev/null || true
            echo "  [SUCCESS] '$fa' outbound routed through VNet"
            ((CHANGES++)) || true
        fi

        fa_public="$(az_value functionapp show --name "$fa" --resource-group "$ResourceGroupName" --query publicNetworkAccess -o tsv)"
        if [[ "$fa_public" == "Disabled" ]]; then
            echo "  [OK] '$fa' public inbound already disabled"
        else
            az functionapp update --name "$fa" --resource-group "$ResourceGroupName" --set publicNetworkAccess=Disabled --output none 2>/dev/null || true
            echo "  [SUCCESS] '$fa' public inbound disabled"
            ((CHANGES++)) || true
        fi
    done
fi

# =============================================================================
# STEP 5: Disable public network access on backing resources
# =============================================================================
# NOTE: This is intentionally LAST among the platform steps - the private
# endpoints, DNS and VNet integration above must be in place first so the apps
# keep working once the public doors close. Step 6 can re-open a narrow hole.
if [[ $skip_step_5 -eq 1 ]]; then
    echo ""
    echo ">>> Step 5: Disable Public Network Access"
    echo "  [SKIPPED] Step 5 skipped by --skip-steps"
else
    echo ""
    echo ">>> Step 5: Disable Public Network Access"

    # Storage
    # NOTE (Option A - trusted services): Content Understanding is a multi-tenant
    # PaaS that lives OUTSIDE this VNet, so it cannot reach Storage over the
    # private endpoint, and a fully Disabled public endpoint would also nullify
    # the trusted-services bypass. Instead we keep the public endpoint Enabled but
    # DENY by default, turn on the AzureServices bypass, and add a
    # resource-instance rule that trusts ONLY the Content Understanding account.
    # CU then reads attachment blobs by URL using its managed identity (already
    # granted Storage Blob Data Reader by 1.deploy-infrastructure.sh). No public
    # IP can reach the data plane; the apps still use the private endpoints.
    st_default_action="$(az_value storage account show --name "$StorageAccountName" --resource-group "$ResourceGroupName" --query networkRuleSet.defaultAction -o tsv)"
    if [[ "$st_default_action" == "Deny" ]]; then
        echo "  [OK] Storage '$StorageAccountName' already locked to Deny (trusted services)"
    else
        az storage account update --name "$StorageAccountName" --resource-group "$ResourceGroupName" \
            --public-network-access Enabled --default-action Deny --bypass AzureServices --output none 2>/dev/null || true
        echo "  [SUCCESS] Storage '$StorageAccountName' locked to Deny (trusted-services bypass on)"
        ((CHANGES++)) || true
    fi
    # Resource-instance rule: trust the Content Understanding account so it can
    # fetch attachment blobs by URL through Storage's (deny-by-default) endpoint.
    if [[ -n "$ContentUnderstandingId" && -n "$TenantId" ]]; then
        cu_rule="$(az_value storage account show --name "$StorageAccountName" --resource-group "$ResourceGroupName" --query "networkRuleSet.resourceAccessRules[?resourceId=='$ContentUnderstandingId'] | [0].resourceId" -o tsv)"
        if [[ -n "$cu_rule" ]]; then
            echo "  [OK] Storage already trusts Content Understanding '$ContentUnderstandingName'"
        else
            az storage account network-rule add --account-name "$StorageAccountName" --resource-group "$ResourceGroupName" \
                --resource-id "$ContentUnderstandingId" --tenant-id "$TenantId" --output none 2>/dev/null || true
            echo "  [SUCCESS] Storage now trusts Content Understanding '$ContentUnderstandingName'"
            ((CHANGES++)) || true
        fi
    else
        echo "  [WARN] Skipped Content Understanding resource-instance rule (CU id or tenant id unavailable)"
    fi

    # Cosmos DB
    cosmos_public="$(az_value cosmosdb show --name "$CosmosDbAccountName" --resource-group "$ResourceGroupName" --query publicNetworkAccess -o tsv)"
    if [[ "$cosmos_public" == "Disabled" ]]; then
        echo "  [OK] Cosmos DB '$CosmosDbAccountName' public access already disabled"
    else
        az cosmosdb update --name "$CosmosDbAccountName" --resource-group "$ResourceGroupName" --public-network-access Disabled --output none 2>/dev/null || true
        echo "  [SUCCESS] Cosmos DB '$CosmosDbAccountName' public access disabled"
        ((CHANGES++)) || true
    fi

    # Key Vault
    kv_public="$(az_value keyvault show --name "$KeyVaultName" --resource-group "$ResourceGroupName" --query properties.publicNetworkAccess -o tsv)"
    if [[ "$kv_public" == "Disabled" ]]; then
        echo "  [OK] Key Vault '$KeyVaultName' public access already disabled"
    else
        az keyvault update --name "$KeyVaultName" --resource-group "$ResourceGroupName" \
            --public-network-access Disabled --default-action Deny --bypass AzureServices --output none 2>/dev/null || true
        echo "  [SUCCESS] Key Vault '$KeyVaultName' public access disabled"
        ((CHANGES++)) || true
    fi

    # AI Foundry (Cognitive Services / AIServices)
    if [[ -n "$AiFoundryId" ]]; then
        foundry_public="$(az_value resource show --ids "$AiFoundryId" --query properties.publicNetworkAccess -o tsv)"
        if [[ "$foundry_public" == "Disabled" ]]; then
            echo "  [OK] AI Foundry '$AiFoundryName' public access already disabled"
        else
            az resource update --ids "$AiFoundryId" --set properties.publicNetworkAccess=Disabled properties.networkAcls.defaultAction=Deny --output none 2>/dev/null || true
            echo "  [SUCCESS] AI Foundry '$AiFoundryName' public access disabled"
            ((CHANGES++)) || true
        fi
    fi

    # Content Understanding (Cognitive Services / AIServices)
    if [[ -n "$ContentUnderstandingId" ]]; then
        cu_public="$(az_value resource show --ids "$ContentUnderstandingId" --query properties.publicNetworkAccess -o tsv)"
        if [[ "$cu_public" == "Disabled" ]]; then
            echo "  [OK] Content Understanding '$ContentUnderstandingName' public access already disabled"
        else
            az resource update --ids "$ContentUnderstandingId" --set properties.publicNetworkAccess=Disabled properties.networkAcls.defaultAction=Deny --output none 2>/dev/null || true
            echo "  [SUCCESS] Content Understanding '$ContentUnderstandingName' public access disabled"
            ((CHANGES++)) || true
        fi
    fi

    # Service Bus (Premium only)
    if [[ -n "$ServiceBusId" && $ServiceBusSupportsPrivate -eq 1 ]]; then
        sb_public="$(az_value servicebus namespace show --name "$ServiceBusNamespace" --resource-group "$ResourceGroupName" --query publicNetworkAccess -o tsv)"
        if [[ "$sb_public" == "Disabled" ]]; then
            echo "  [OK] Service Bus '$ServiceBusNamespace' public access already disabled"
        else
            az servicebus namespace update --name "$ServiceBusNamespace" --resource-group "$ResourceGroupName" --public-network-access Disabled --output none 2>/dev/null || true
            echo "  [SUCCESS] Service Bus '$ServiceBusNamespace' public access disabled"
            ((CHANGES++)) || true
        fi
    elif [[ -n "$ServiceBusId" ]]; then
        echo "  [SKIP] Service Bus '$ServiceBusNamespace' is '$ServiceBusSku' - public lockdown requires Premium"
    fi
fi

# =============================================================================
# STEP 6: Local testing access - laptop IP firewall hole + collect RBAC grants
# =============================================================================
# The signed-in-user RBAC grant was decided and (when granting) kicked off in
# the background during pre-flight, so it overlapped with Steps 1-5. Here we
# open/close the laptop-IP firewall holes (which must follow Step 5's lockdown)
# and then collect the background RBAC subshell.
if [[ $skip_step_6 -eq 1 ]]; then
    echo ""
    echo ">>> Step 6: Local Testing Access"
    echo "  [SKIPPED] Step 6 skipped by --skip-steps"
else
    echo ""
    echo ">>> Step 6: Local Testing Access (TESTING ONLY)"

    if [[ $grant_access -eq 1 ]]; then
        echo "  [INFO] GRANTING local testing access (IP: $MyPublicIp)"

        # Re-enable public endpoints with default-Deny + allow only the laptop IP.
        if [[ -n "$MyPublicIp" ]]; then
            az storage account update --name "$StorageAccountName" --resource-group "$ResourceGroupName" \
                --public-network-access Enabled --default-action Deny --bypass AzureServices --output none 2>/dev/null || true
            az storage account network-rule add --account-name "$StorageAccountName" --resource-group "$ResourceGroupName" --ip-address "$MyPublicIp" --output none 2>/dev/null || true

            az keyvault update --name "$KeyVaultName" --resource-group "$ResourceGroupName" \
                --public-network-access Enabled --default-action Deny --bypass AzureServices --output none 2>/dev/null || true
            az keyvault network-rule add --name "$KeyVaultName" --resource-group "$ResourceGroupName" --ip-address "$MyPublicIp" --output none 2>/dev/null || true

            az cosmosdb update --name "$CosmosDbAccountName" --resource-group "$ResourceGroupName" \
                --public-network-access Enabled --ip-range-filter "$MyPublicIp" --output none 2>/dev/null || true

            echo "  [SUCCESS] Firewall hole opened for $MyPublicIp (Storage, Key Vault, Cosmos DB)"
            ((CHANGES++)) || true
        fi

        # Collect the RBAC grants kicked off in the background during pre-flight.
        if [[ -n "$RBAC_BG_PID" ]]; then
            echo "  [INFO] Waiting for background RBAC grants to finish..."
            wait "$RBAC_BG_PID" 2>/dev/null || true
            granted=0
            while IFS= read -r line; do
                if [[ "$line" =~ ^GRANTED_COUNT=([0-9]+)$ ]]; then
                    granted="${BASH_REMATCH[1]}"
                else
                    echo "$line"
                fi
            done < "$RBAC_BG_LOG"
            rm -f "$RBAC_BG_LOG"
            [[ $granted -gt 0 ]] && CHANGES=$((CHANGES + granted))
        fi
        echo "  [INFO] RBAC propagation may take up to 5 minutes."
    else
        echo "  [INFO] REMOVING local testing access and locking resources down"

        if [[ -n "$MyPublicIp" ]]; then
            az storage account network-rule remove --account-name "$StorageAccountName" --resource-group "$ResourceGroupName" --ip-address "$MyPublicIp" --output none 2>/dev/null || true
            az keyvault network-rule remove --name "$KeyVaultName" --resource-group "$ResourceGroupName" --ip-address "$MyPublicIp" --output none 2>/dev/null || true
        fi
        # Storage stays Enabled+Deny (Option A): the Content Understanding
        # resource-instance rule must keep working, so we only drop the laptop IP
        # and re-assert deny-by-default rather than disabling public access.
        az storage account update --name "$StorageAccountName" --resource-group "$ResourceGroupName" --public-network-access Enabled --default-action Deny --bypass AzureServices --output none 2>/dev/null || true
        az keyvault update --name "$KeyVaultName" --resource-group "$ResourceGroupName" --public-network-access Disabled --output none 2>/dev/null || true
        az cosmosdb update --name "$CosmosDbAccountName" --resource-group "$ResourceGroupName" --public-network-access Disabled --ip-range-filter "" --output none 2>/dev/null || true
        echo "  [SUCCESS] Public firewall holes closed (Storage stays deny-by-default for trusted CU; Key Vault, Cosmos DB disabled)"

        removed=0
        for entry in "${ROLE_ASSIGNMENTS[@]}"; do
            IFS='|' read -r atype f1 f2 f3 f4 f5 <<< "$entry"
            if [[ "$atype" == "cosmos" ]]; then
                # f1=label f2=roleDefId f3=account f4=rg f5=scope
                existing="$(az_value cosmosdb sql role assignment list --account-name "$f3" --resource-group "$f4" --query "[?principalId=='$CurrentUserId' && contains(roleDefinitionId, '$f2')] | [0].id" -o tsv)"
                if [[ -n "$existing" ]]; then
                    az cosmosdb sql role assignment delete --account-name "$f3" --resource-group "$f4" --role-assignment-id "$existing" --yes --output none 2>/dev/null || true
                    echo "  [SUCCESS] Removed $f1"
                    ((removed++)) || true
                else
                    echo "  [OK] $f1 not assigned"
                fi
                continue
            fi
            # arm: f1=role f2=scope
            role="$f1"; scope="$f2"
            [[ -z "$scope" ]] && continue
            existing="$(az_value role assignment list --assignee "$CurrentUserId" --role "$role" --scope "$scope" --query '[0].id' -o tsv)"
            if [[ -n "$existing" ]]; then
                az role assignment delete --assignee "$CurrentUserId" --role "$role" --scope "$scope" --output none 2>/dev/null || true
                echo "  [SUCCESS] Removed $role"
                ((removed++)) || true
            else
                echo "  [OK] $role not assigned"
            fi
        done
        [[ $removed -gt 0 ]] && CHANGES=$((CHANGES + removed))
    fi
fi

# =============================================================================
# STEP 7: Refresh Key Vault App Setting References
# =============================================================================
# After Key Vault public access is disabled, the App Service / Functions
# platform must re-resolve its @Microsoft.KeyVault(...) app settings over the
# private endpoint. This kicks off that refresh and waits until they resolve.
if [[ $skip_step_7 -eq 1 ]]; then
    echo ""
    echo ">>> Step 7: Refresh Key Vault App Setting References"
    echo "  [SKIPPED] Step 7 skipped by --skip-steps"
else
    echo ""
    echo ">>> Step 7: Refresh Key Vault App Setting References"

    if [[ $skip_step_3 -eq 0 ]]; then
        wait_private_endpoints_ready "$ResourceGroupName" "privatelink.vaultcore.azure.net" "${ACTIVE_PE_NAMES[@]}"
    else
        echo "  [INFO] Step 3 was skipped; not waiting on private endpoints."
    fi

    SERVICES_WITH_KV_REFS=(
        "functionapp|$FuncMailboxName"
        "functionapp|$FuncQueueDbName"
        "functionapp|$FuncCuQueueDbName"
        "webapp|$WebAppName"
    )

    for svc in "${SERVICES_WITH_KV_REFS[@]}"; do
        svc_type="${svc%%|*}"; svc_name="${svc#*|}"
        resource_id="$(az_value "$svc_type" show --name "$svc_name" --resource-group "$ResourceGroupName" --query id -o tsv)"
        if [[ -z "$resource_id" ]]; then
            echo "  [WARNING] Could not find $svc_type '$svc_name'; skipping Key Vault reference refresh"
            continue
        fi
        invoke_config_reference_refresh "$resource_id" "$svc_name"
    done
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
if [[ $CHANGES -gt 0 ]]; then
    echo "[SUCCESS] Production hardening applied. $CHANGES change(s) made."
else
    echo "[SUCCESS] Production hardening already in place. No changes needed."
fi
echo ""
echo "  VNet            : $VnetName ($VnetAddressSpace)"
echo "    - $SubnetPe ($SubnetPeCidr) : private endpoints"
echo "    - $SubnetAppService ($SubnetAppServiceCidr) : Web App integration"
echo "    - $SubnetFunctions ($SubnetFunctionsCidr) : Function App integration"
echo "  Private (PE)    : Storage(blob/queue/table), Cosmos DB, Key Vault, AI Foundry, Content Understanding"
if [[ -n "$ServiceBusId" && $ServiceBusSupportsPrivate -eq 1 ]]; then
    echo "                    Service Bus (Premium)"
elif [[ -n "$ServiceBusId" ]]; then
    echo "  Service Bus     : $ServiceBusNamespace ($ServiceBusSku) - NOT privatized (needs Premium)"
fi
echo "  Functions       : VNet-integrated, public inbound disabled, outbound to Graph allowed"
echo "  Web App         : VNet-integrated outbound; public UI inbound retained"
echo "  KV references   : refreshed on Web App + Function Apps"
echo ""

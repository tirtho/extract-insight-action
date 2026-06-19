#!/usr/bin/env bash
# =============================================================================
# Azure Infrastructure Deployment Script for extract-insight-action (bash)
# Mirrors 1.deploy-infrastructure.ps1 — idempotent; can be re-run safely.
#
# Requires: bash 4+, az CLI, jq, curl, Java 21 (JAVA_HOME).
#
# Usage:
#   ./1.deploy-infrastructure.sh <suffix>
# =============================================================================
set -uo pipefail

if [[ $# -lt 1 || -z "${1:-}" ]]; then
    echo "[ERROR] Suffix is required." >&2
    echo "Usage: $0 <suffix>" >&2
    exit 1
fi
SUFFIX="$1"

command -v jq >/dev/null 2>&1 || { echo "[ERROR] 'jq' is required." >&2; exit 1; }
command -v az >/dev/null 2>&1 || { echo "[ERROR] Azure CLI is not installed." >&2; exit 1; }

SCRIPT_DIR="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
REPO_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"

# =============================================================================
# Load selected config file (optional; prompts for values if absent)
# =============================================================================
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

if [[ -f "$CONFIG_FILE" ]]; then
    LOADED=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        if [[ "$line" =~ ^([^=]+)=(.*)$ ]]; then
            n="${BASH_REMATCH[1]// /}"
            v="${BASH_REMATCH[2]}"
            v="${v#\"}"; v="${v%\"}"
            export "$n=$v"
            ((LOADED++)) || true
        fi
    done < "$CONFIG_FILE"
    echo "[INFO] Loaded $LOADED environment variable(s) from $CONFIG_FILE_NAME"
else
    echo "[WARNING] Config file '$CONFIG_FILE_NAME' not found at $CONFIG_FILE - prompting for required values"
    declare -a GEN_LINES=()
    prompt_var() {
        local name="$1" default="$2" example="$3" required="$4"
        local current="${!name:-}"
        if [[ -n "$current" ]]; then
            echo "  $name already set in environment, keeping: $current"
            GEN_LINES+=("$name=\"$current\"")
            return
        fi
        local hint
        if [[ -n "$default" ]]; then
            hint="default: $default, example: $example"
        else
            hint="example: $example"
        fi
        while true; do
            read -r -p "Enter $name [$hint]: " entered
            [[ -z "$entered" ]] && entered="$default"
            if [[ -z "$entered" && "$required" == "yes" ]]; then
                echo "  [ERROR] $name is required"
            else
                break
            fi
        done
        export "$name=$entered"
        GEN_LINES+=("$name=\"$entered\"")
    }
    prompt_var PROJECT_NAME "eia"                                   "eia"                                        "no"
    prompt_var ENVIRONMENT  "dev"                                   "dev"                                        "no"
    prompt_var LOCATION     "centralus"                             "centralus"                                  "no"
    prompt_var USER_EMAIL_ADDRESS "" "user@contoso.onmicrosoft.com" "yes"
    prompt_var SUBSCRIPTION_ID    "" "00000000-0000-0000-0000-000000000000" "yes"
    printf '%s\n' "${GEN_LINES[@]}" > "$CONFIG_FILE" && echo "[INFO] Saved entered values to $CONFIG_FILE" || \
        echo "[WARNING] Could not write $CONFIG_FILE"
    echo "[INFO] Loaded ${#GEN_LINES[@]} environment variable(s) from interactive prompts"
fi

# Derived env vars (SUFFIX / KEY_VAULT_NAME / AZURE_KEY_VAULT_URL) + write env.bat
_PN="${PROJECT_NAME:-eia}"; _EN="${ENVIRONMENT:-dev}"
export KEY_VAULT_NAME="kv-${_PN}-${_EN}-${SUFFIX}"
export AZURE_KEY_VAULT_URL="https://${KEY_VAULT_NAME}.vault.azure.net"
export SUFFIX
{
    printf '@echo off\r\n'
    printf 'set AZURE_KEY_VAULT_URL=%s\r\n' "$AZURE_KEY_VAULT_URL"
} > "$REPO_ROOT/env.bat" && echo "[INFO] Wrote $REPO_ROOT/env.bat" || \
    echo "[WARNING] Could not write $REPO_ROOT/env.bat"

# =============================================================================
# Configuration (mirrors .ps1 naming conventions)
# =============================================================================
ProjectName="${PROJECT_NAME:-eia}"
Environment="${ENVIRONMENT:-dev}"
Location="${LOCATION:-centralus}"

SubscriptionId="${SUBSCRIPTION_ID:-$(az account show --query id -o tsv 2>/dev/null || true)}"
TenantId="${TENANT_ID:-$(az account show --query tenantId -o tsv 2>/dev/null || true)}"

ProjClean="${ProjectName//-/}"
StorageClean="${SUFFIX//-/}"
ResourceGroupName="${RESOURCE_GROUP_NAME:-rg-${ProjectName}-${Environment}-${SUFFIX}}"
KeyVaultName="${KEY_VAULT_NAME}"
ServiceBusNamespace="${SERVICE_BUS_NAMESPACE:-sb-${ProjectName}-${Environment}-${SUFFIX}}"
StorageAccountName="${STORAGE_ACCOUNT_NAME:-st${ProjClean}${Environment}${StorageClean}}"
FuncMailboxName="${FUNCTION_APP_MAILBOX_NAME:-func-mailbox-${ProjectName}-${Environment}-${SUFFIX}}"
FuncQueueDbName="${FUNCTION_APP_QUEUE_DB_NAME:-func-queuedb-${ProjectName}-${Environment}-${SUFFIX}}"
FuncCuQueueDbName="${FUNCTION_APP_CU_QUEUE_DB_NAME:-func-cuqueuedb-${ProjectName}-${Environment}-${SUFFIX}}"
ServiceBusTopicName="${SERVICE_BUS_TOPIC_NAME:-email-processing}"
ServiceBusSubName="${SERVICE_BUS_SUBSCRIPTION_NAME:-email-processor}"
GraphAppName="${GRAPH_APP_NAME:-${ProjectName}-graph-api-${Environment}}"
GraphClientId="${GRAPH_CLIENT_ID:-}"
GraphClientSecret="${GRAPH_CLIENT_SECRET:-}"
WebAppAuthAppName="${WEBAPP_AUTH_APP_NAME:-${ProjectName}-webapp-auth-${Environment}}"
WebAppClientId="${WEBAPP_CLIENT_ID:-}"
WebAppClientSecret="${WEBAPP_CLIENT_SECRET:-}"
AppInsightsName="${APP_INSIGHTS_NAME:-ai-${ProjectName}-${Environment}}"
CosmosDbAccountName="${COSMOS_DB_ACCOUNT_NAME:-cosmos-${ProjectName}-${Environment}-${SUFFIX}}"
StorageQueueName="${STORAGE_QUEUE_NAME:-cu-analyze-ops-${ProjectName}-${Environment}-${SUFFIX}}"
StorageQueuePollingSchedule="${STORAGE_QUEUE_POLLING_SCHEDULE:-0 */1 * * * *}"
UserEmailAddress="${USER_EMAIL_ADDRESS:-}"
PollingMailboxName="${POLLING_MAILBOX_NAME:-Inbox}"
ReadMailboxForPastNSeconds="${READ_MAILBOX_FOR_PAST_N_SECONDS:-3600}"
CosmosDbDatabaseName="DocAIDatabase"
CosmosDbContainerName="EmailExtracts"
AppServicePlanName="${APP_SERVICE_PLAN_NAME:-plan-${ProjectName}-${Environment}}"
WebAppName="${WEB_APP_NAME:-app-${ProjectName}-${Environment}-${SUFFIX}}"
ContentUnderstandingName="${CONTENT_UNDERSTANDING_NAME:-cu-${ProjectName}-${Environment}-${SUFFIX}}"
AiFoundryName="${AI_FOUNDRY_NAME:-oai-${ProjectName}-${Environment}-${SUFFIX}}"
AiFoundryProjectName="${AI_FOUNDRY_PROJECT_NAME:-proj-${ProjectName}-${Environment}-${SUFFIX}}"
AiFoundryProjectApiVersion="2025-04-01-preview"
AiFoundryApiVersion="2024-12-01-preview"
AiFoundrySkuName="GlobalStandard"
AiFoundrySkuCapacity="50"
DeployModelsCsvPath="$SCRIPT_DIR/deploy-models.csv"

# Primary model (updated from CSV row 0 at runtime)
AiFoundryDeploymentName="gpt-5.1-chat"
AiFoundryModelName="gpt-5.1-chat"
AiFoundryModelVersion="2025-11-13"

# CU models
CuCompletionDeploymentName="gpt-4.1"
CuCompletionModelName="gpt-4.1"
CuCompletionModelVersion="2025-04-14"
CuCompletionSkuCapacity="50"
CuEmbeddingDeploymentName="text-embedding-3-large"
CuEmbeddingModelName="text-embedding-3-large"
CuEmbeddingModelVersion="1"
CuEmbeddingSkuCapacity="50"

StorageBlobEndpoint=""
StorageContainerName=""

# =============================================================================
# VALIDATE JAVA 21
# =============================================================================
if [[ -z "${JAVA_HOME:-}" ]]; then
    echo "[ERROR] JAVA_HOME is not set. Please set JAVA_HOME to a JDK 21 installation." >&2
    exit 1
fi
JAVA_VER=$("$JAVA_HOME/bin/java" -version 2>&1 | head -1 | grep -oE '"[0-9]+' | tr -d '"')
if [[ "$JAVA_VER" != "21" ]]; then
    echo "[ERROR] This project requires Java 21 but JAVA_HOME points to Java $JAVA_VER." >&2
    echo "        JAVA_HOME: $JAVA_HOME" >&2
    exit 1
fi
echo "[INFO] Java 21 confirmed from JAVA_HOME"

if [[ -z "$UserEmailAddress" ]]; then
    echo "[ERROR] USER_EMAIL_ADDRESS is not set." >&2
    exit 1
fi
echo "[INFO] USER_EMAIL_ADDRESS = $UserEmailAddress"

# =============================================================================
# ERROR TRACKING
# =============================================================================
DEPLOYMENT_ERRORS=()

# =============================================================================
# HELPERS
# =============================================================================

# Run az CLI silently; sets LAST_EXIT / LAST_OUT / LAST_ERR
# NOTE: do NOT use '|| true' here — we need the real exit code.
az_silent() {
    local _tmp_err
    _tmp_err=$(mktemp)
    LAST_OUT=$(az "$@" 2>"$_tmp_err")
    LAST_EXIT=$?
    LAST_ERR=$(cat "$_tmp_err" 2>/dev/null || true)
    rm -f "$_tmp_err"
}

# Idempotent resource check: returns 0 if resource exists
test_az_resource() {
    local out
    out=$(az "$@" 2>/dev/null || true)
    [[ -n "$out" ]]
}

# Returns 0 if role already assigned, 1 if newly created, 2 on error
ensure_role_assignment() {
    local assignee="$1" role="$2" scope="$3" principal_type="${4:-}"
    if [[ -z "$scope" ]]; then
        echo "[ERROR] ensure_role_assignment: Scope is empty for role '$role' on assignee '$assignee'" >&2
        DEPLOYMENT_ERRORS+=("RBAC: '$role' for '$assignee' - empty scope")
        return 2
    fi
    local existing
    existing=$(az role assignment list --assignee "$assignee" --role "$role" --scope "$scope" \
        --query '[0].id' -o tsv 2>/dev/null || true)
    if [[ -n "$existing" ]]; then return 0; fi
    local -a create_args=(role assignment create --role "$role" --scope "$scope" --output none)
    if [[ -n "$principal_type" ]]; then
        # Use --assignee-object-id to bypass graph.microsoft.com lookup (avoids network timeout)
        create_args+=(--assignee-object-id "$assignee" --assignee-principal-type "$principal_type")
    else
        create_args+=(--assignee "$assignee")
    fi
    if ! az "${create_args[@]}" 2>/tmp/ra_err.$$; then
        echo "[ERROR] Failed to assign role '$role' to '$assignee' on scope '$scope'" >&2
        cat /tmp/ra_err.$$ >&2 || true
        rm -f /tmp/ra_err.$$
        DEPLOYMENT_ERRORS+=("RBAC: '$role' for '$assignee'")
        return 2
    fi
    rm -f /tmp/ra_err.$$
    return 1
}

# Returns 0 if already assigned, 1 if newly created
ensure_cosmos_role_assignment() {
    local account="$1" rg="$2" role_def="$3" principal="$4" scope="$5"
    local existing
    existing=$(az cosmosdb sql role assignment list --account-name "$account" --resource-group "$rg" \
        --query "[?principalId=='$principal'] | [0].id" --output tsv 2>/dev/null || true)
    if [[ -n "$existing" ]]; then return 0; fi
    az cosmosdb sql role assignment create --account-name "$account" --resource-group "$rg" \
        --role-definition-id "$role_def" --principal-id "$principal" --scope "$scope" \
        --output none 2>/dev/null || true
    return 1
}

# Creates a custom role definition if it does not already exist.
# Usage: ensure_custom_role_definition <role_name> <description> <data_actions_json_array> <assignable_scope>
ensure_custom_role_definition() {
    local role_name="$1" description="$2" data_actions_json="$3" assignable_scope="$4"
    local existing
    existing=$(az role definition list --name "$role_name" --query '[0].name' -o tsv 2>/dev/null || true)
    if [[ -n "$existing" ]]; then
        echo "[OK] Custom role '$role_name' already exists"
        return 0
    fi
    echo "[INFO] Creating custom role '$role_name'"
    local tmp_file
    tmp_file=$(mktemp /tmp/custom-role-XXXXXX.json)
    cat > "$tmp_file" <<EOF
{
  "Name": "$role_name",
  "Description": "$description",
  "Actions": [],
  "DataActions": $data_actions_json,
  "AssignableScopes": ["$assignable_scope"]
}
EOF
    if ! az role definition create --role-definition "@$tmp_file" --output none 2>/tmp/crd_err.$$; then
        echo "[ERROR] Failed to create custom role '$role_name'" >&2
        cat /tmp/crd_err.$$ >&2 || true
        rm -f /tmp/crd_err.$$ "$tmp_file"
        DEPLOYMENT_ERRORS+=("Custom role: '$role_name'")
        return 1
    fi
    rm -f /tmp/crd_err.$$ "$tmp_file"
    echo "[SUCCESS] Custom role '$role_name' created"
}

# Merge + PUT function app settings via ARM REST API (mirrors Set-FunctionAppSettings)
set_function_app_settings() {
    local func_name="$1" rg="$2"
    shift 2
    # remaining args: KEY=VALUE pairs
    local func_id
    func_id=$(az functionapp show --name "$func_name" --resource-group "$rg" --query id -o tsv 2>/dev/null || true)
    if [[ -z "$func_id" ]]; then
        echo "[ERROR] Function app $func_name not found" >&2
        DEPLOYMENT_ERRORS+=("Function app settings: $func_name")
        return 1
    fi
    # Get existing settings
    local existing_json
    existing_json=$(az rest --method POST --url "${func_id}/config/appsettings/list?api-version=2023-01-01" \
        -o json 2>/dev/null || echo '{}')
    local merged_json
    merged_json=$(echo "$existing_json" | jq -r '.properties // {}' 2>/dev/null || echo '{}')
    # Apply new settings
    for kv in "$@"; do
        local k="${kv%%=*}" v="${kv#*=}"
        merged_json=$(echo "$merged_json" | jq --arg k "$k" --arg v "$v" '. + {($k): $v}')
    done
    local body
    body=$(jq -n --argjson p "$merged_json" '{properties: $p}')
    local body_file
    body_file=$(mktemp)
    echo "$body" > "$body_file"
    az_silent rest --method PUT \
        --url "${func_id}/config/appsettings?api-version=2023-01-01" \
        --body "@$body_file" --output none
    rm -f "$body_file"
    if [[ $LAST_EXIT -ne 0 ]]; then
        echo "[ERROR] Failed to configure settings for $func_name" >&2
        [[ -n "$LAST_ERR" ]] && echo "  $LAST_ERR" >&2
        DEPLOYMENT_ERRORS+=("Function app settings: $func_name")
        return 1
    fi
    return 0
}

# =============================================================================
# SERVICE LOCATION HELPER
# Reads supported-service-locations.csv
# =============================================================================
declare -A _SVC_LOC_CACHE=()

get_service_location() {
    local svc="$1" default_loc="$2" always_prompt="${3:-}"
    local svc_lo="${svc,,}"

    # Return cached
    [[ -n "${_SVC_LOC_CACHE[$svc_lo]+x}" ]] && { echo "${_SVC_LOC_CACHE[$svc_lo]}"; return; }

    local csv="$SCRIPT_DIR/supported-service-locations.csv"
    if [[ ! -f "$csv" ]]; then
        _SVC_LOC_CACHE[$svc_lo]="$default_loc"
        echo "$default_loc"; return
    fi

    local found_line=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue
        local row_svc="${line%%,*}"
        if [[ "${row_svc,,}" == "$svc_lo" ]]; then found_line="$line"; break; fi
    done < "$csv"

    if [[ -z "$found_line" ]]; then
        _SVC_LOC_CACHE[$svc_lo]="$default_loc"
        echo "$default_loc"; return
    fi

    # Parse supported locations (all fields after the first)
    IFS=',' read -ra parts <<< "$found_line"
    local locs=()
    for ((i=1; i<${#parts[@]}; i++)); do
        local l="${parts[$i]// /}"
        [[ -n "$l" ]] && locs+=("${l,,}")
    done

    if [[ "$always_prompt" == "always" ]]; then
        echo "" >&2
        echo "[INFO] Select a location for service '$svc':" >&2
        local default_idx=1
        for ((i=0; i<${#locs[@]}; i++)); do
            local marker=""
            [[ "${locs[$i]}" == "${default_loc,,}" ]] && marker=" (default)" && default_idx=$((i+1))
            printf "  [%d] %s%s\n" $((i+1)) "${locs[$i]}" "$marker" >&2
        done
        local chosen_idx=""
        while true; do
            read -r -p "Enter selection number [1-${#locs[@]}] (default: $default_idx): " chosen_idx
            [[ -z "$chosen_idx" ]] && chosen_idx="$default_idx"
            if [[ "$chosen_idx" =~ ^[0-9]+$ ]] && (( chosen_idx>=1 && chosen_idx<=${#locs[@]} )); then
                break
            fi
            echo "[ERROR] Invalid selection. Enter a number between 1 and ${#locs[@]}." >&2
        done
        local chosen="${locs[$((chosen_idx-1))]}"
        echo "[INFO] Using location '$chosen' for $svc" >&2
        _SVC_LOC_CACHE[$svc_lo]="$chosen"
        echo "$chosen"; return
    fi

    # Check if default is supported
    for l in "${locs[@]}"; do
        if [[ "$l" == "${default_loc,,}" ]]; then
            _SVC_LOC_CACHE[$svc_lo]="$default_loc"
            echo "$default_loc"; return
        fi
    done

    # Not in supported list - prompt
    echo "" >&2
    echo "[WARNING] Location '$default_loc' is not supported for service '$svc'." >&2
    echo "[INFO] Supported locations: ${locs[*]}" >&2
    local uinput=""
    while true; do
        read -r -p "Enter a supported location for '$svc': " uinput
        uinput="${uinput,,}"; uinput="${uinput// /}"
        for l in "${locs[@]}"; do
            if [[ "$l" == "$uinput" ]]; then
                echo "[INFO] Using location '$uinput' for $svc" >&2
                _SVC_LOC_CACHE[$svc_lo]="$uinput"
                echo "$uinput"; return
            fi
        done
        echo "[ERROR] '$uinput' is not in the supported list. Please try again." >&2
    done
}

# =============================================================================
# FOUNDRY MODEL CATALOG + SIMILARITY HELPERS
# =============================================================================
declare -A _FOUNDRY_CATALOG=()  # location -> "fetched" flag

get_foundry_catalog_json() {
    local loc="$1"
    if [[ -z "${_FOUNDRY_CATALOG[$loc]+x}" ]]; then
        local raw
        raw=$(az cognitiveservices model list --location "$loc" -o json 2>/dev/null || echo '[]')
        # Filter OpenAI format, prefer AIServices kind
        local filtered
        filtered=$(echo "$raw" | jq '[.[] | select(.model.format=="OpenAI" and .kind=="AIServices")]' 2>/dev/null || echo '[]')
        if [[ "$(echo "$filtered" | jq 'length')" == "0" ]]; then
            filtered=$(echo "$raw" | jq '[.[] | select(.model.format=="OpenAI")]' 2>/dev/null || echo '[]')
        fi
        _FOUNDRY_CATALOG[$loc]="$filtered"
    fi
    echo "${_FOUNDRY_CATALOG[$loc]}"
}

# Bash longest-common-substring similarity (0-100 integer score to avoid floats)
lcs_score() {
    local a="${1,,}" b="${2,,}"
    [[ -z "$a" || -z "$b" ]] && echo 0 && return
    [[ "$a" == "$b" ]] && echo 100 && return
    # substring containment
    if [[ "$a" == *"$b"* || "$b" == *"$a"* ]]; then
        local mn mx
        mn=$(( ${#a} < ${#b} ? ${#a} : ${#b} ))
        mx=$(( ${#a} > ${#b} ? ${#a} : ${#b} ))
        echo $(( 85 + 15 * mn / mx ))
        return
    fi
    # Dynamic programming LCS
    local la=${#a} lb=${#b}
    local -a prev curr
    prev=(); for ((j=0; j<=lb; j++)); do prev[$j]=0; done
    local best=0
    for ((i=1; i<=la; i++)); do
        curr=(); for ((j=0; j<=lb; j++)); do curr[$j]=0; done
        for ((j=1; j<=lb; j++)); do
            if [[ "${a:$((i-1)):1}" == "${b:$((j-1)):1}" ]]; then
                curr[$j]=$(( prev[$((j-1))] + 1 ))
                (( curr[$j] > best )) && best=${curr[$j]}
            fi
        done
        prev=("${curr[@]}")
    done
    local mx=$(( la > lb ? la : lb ))
    echo $(( best * 100 / mx ))
}

show_model_suggestions() {
    local loc="$1" requested="$2" requested_sku="${3:-}" top="${4:-5}"
    local catalog
    catalog=$(get_foundry_catalog_json "$loc")
    local catalog_len
    catalog_len=$(echo "$catalog" | jq 'length')
    (( catalog_len == 0 )) && return

    echo "" >&2
    echo "[INFO] Closest matches for '$requested' in $loc :" >&2

    # Build deduplicated scored list: name|version|skus|score
    declare -A SEEN_MV
    local entries=()
    while IFS=$'\t' read -r name version skus; do
        local key="${name}|${version}"
        [[ -n "${SEEN_MV[$key]+x}" ]] && continue
        SEEN_MV["$key"]=1
        local score
        score=$(lcs_score "$requested" "$name")
        entries+=("$score|$name|$version|$skus")
    done < <(echo "$catalog" | jq -r '.[] | [.model.name, .model.version, (.model.skus | map(.name) | sort | join(","))] | @tsv')

    # Sort descending by score, print top N
    local printed=0
    while IFS='|' read -r score name version skus; do
        (( printed >= top )) && break
        printf "  - %-30s version=%-15s skus=%s\n" "$name" "$version" "$skus" >&2
        ((printed++)) || true
    done < <(printf '%s\n' "${entries[@]}" | sort -t'|' -k1 -rn)

    # If exact name match, show all versions/SKUs
    if [[ -n "$requested_sku" ]]; then
        local exact_matches
        exact_matches=$(echo "$catalog" | jq -r --arg n "$requested" \
            '[.[] | select(.model.name==$n)] | .[] | [.model.version, (.model.skus | map(.name) | join(","))] | @tsv')
        if [[ -n "$exact_matches" ]]; then
            echo "[INFO] Versions/SKUs available for exact name '$requested':" >&2
            while IFS=$'\t' read -r ver skus; do
                printf "  - version=%-15s skus=%s\n" "$ver" "$skus" >&2
            done <<< "$exact_matches"
        fi
    fi
}

invoke_foundry_model_deployment() {
    local account="$1" rg="$2" model_name="$3" sku_name="$4" model_version="$5" capacity="$6"
    local deploy_name="$model_name"
    local existing
    existing=$(az cognitiveservices account deployment show \
        --name "$account" --resource-group "$rg" --deployment-name "$deploy_name" \
        --query name -o tsv 2>/dev/null || true)
    if [[ -n "$existing" ]]; then
        echo "[WARNING] Model deployment $deploy_name already exists on $account, skipping"
        return 0
    fi
    az_silent cognitiveservices account deployment create \
        --name "$account" --resource-group "$rg" \
        --deployment-name "$deploy_name" \
        --model-name "$model_name" \
        --model-version "$model_version" \
        --model-format OpenAI \
        --sku-name "$sku_name" \
        --sku-capacity "$capacity" \
        --output table
    if [[ $LAST_EXIT -eq 0 ]]; then
        echo "[SUCCESS] Deployed $model_name ($sku_name, version $model_version) on $account"
        return 0
    fi
    echo "[ERROR] Failed to deploy $model_name ($sku_name, version $model_version) on $account" >&2
    [[ -n "$LAST_OUT" ]] && echo "$LAST_OUT" >&2
    return 1
}

# =============================================================================
# BANNER
# =============================================================================
echo ""
echo "[INFO] ============================================================"
echo "[INFO] Azure Infrastructure Deployment for $ProjectName"
echo "[INFO] Environment : $Environment"
echo "[INFO] Location    : $Location"
echo "[INFO] RG          : $ResourceGroupName"
echo "[INFO] ============================================================"
echo ""

# =============================================================================
# PREREQUISITES
# =============================================================================
echo "[INFO] Checking prerequisites..."
if ! state=$(az account show --query state -o tsv 2>/dev/null) || [[ "$state" != "Enabled" ]]; then
    echo "[ERROR] Not logged in to Azure CLI. Run 'az login' first." >&2; exit 1
fi
if [[ -n "$SubscriptionId" ]]; then
    az account set --subscription "$SubscriptionId" --output none 2>/dev/null || true
    echo "[SUCCESS] Subscription set to: $SubscriptionId"
fi

echo "[INFO] Installing/upgrading required Azure CLI extensions..."
az extension add --name application-insights --upgrade --yes 2>/dev/null || true
echo "[SUCCESS] Prerequisites OK"

echo "[INFO] Registering required Azure resource providers..."
PROVIDERS=(Microsoft.KeyVault Microsoft.ServiceBus Microsoft.Storage Microsoft.Web \
    Microsoft.Insights Microsoft.OperationalInsights Microsoft.DocumentDB \
    Microsoft.CognitiveServices)
PROVIDERS_TO_WAIT=()
for provider in "${PROVIDERS[@]}"; do
    state=$(az provider show --namespace "$provider" --query registrationState -o tsv 2>/dev/null || true)
    if [[ "$state" == "Registered" ]]; then
        echo "  [OK] $provider already registered"
    else
        echo "  [INFO] Registering $provider..."
        az provider register --namespace "$provider" --output none 2>/dev/null || true
        PROVIDERS_TO_WAIT+=("$provider")
    fi
done
if (( ${#PROVIDERS_TO_WAIT[@]} > 0 )); then
    echo "[INFO] Waiting for ${#PROVIDERS_TO_WAIT[@]} provider(s) to finish registering..."
    for provider in "${PROVIDERS_TO_WAIT[@]}"; do
        for ((i=1; i<=60; i++)); do
            state=$(az provider show --namespace "$provider" --query registrationState -o tsv 2>/dev/null || true)
            if [[ "$state" == "Registered" ]]; then
                echo "  [SUCCESS] $provider registered"; break
            fi
            sleep 5
        done
        [[ "$state" != "Registered" ]] && echo "  [WARNING] $provider still not registered after 5 minutes - continuing anyway"
    done
fi

# =============================================================================
# VALIDATE SERVICE LOCATIONS
# =============================================================================
echo ""
echo "[INFO] Validating service availability in location '$Location'..."
LocationResourceGroup=$(get_service_location "resourcegroup"       "$Location")
LocationStorage=$(get_service_location        "storageaccount"      "$Location")
LocationKeyVault=$(get_service_location       "keyvault"            "$Location")
LocationServiceBus=$(get_service_location     "servicebus"          "$Location")
LocationAppInsights=$(get_service_location    "applicationinsights" "$Location")
LocationCosmosDb=$(get_service_location       "cosmosdb"            "$Location")
LocationContentUnderstanding=$(get_service_location "contentunderstanding" "$Location")
LocationAiFoundry=$(get_service_location      "aifoundry"           "$Location" "always")
LocationAppService=$(get_service_location     "appservice"          "$Location")
LocationFunctionApp=$(get_service_location    "functionapp"         "$Location")
echo "[SUCCESS] Service location validation complete"

# =============================================================================
# STEP 1: Resource Group
# =============================================================================
echo ""
echo ">>> Step 1/12: Resource Group"
if test_az_resource group show --name "$ResourceGroupName" --query name -o tsv; then
    echo "[WARNING] Resource group $ResourceGroupName already exists, skipping"
else
    if az group create --name "$ResourceGroupName" --location "$LocationResourceGroup" \
            --tags "project=$ProjectName" "environment=$Environment" --output table; then
        echo "[SUCCESS] Resource group $ResourceGroupName created"
    else
        DEPLOYMENT_ERRORS+=("Creating resource group: $ResourceGroupName")
    fi
fi

# =============================================================================
# STEP 2: Storage Account
# =============================================================================
echo ""
echo ">>> Step 2/12: Storage Account"
if test_az_resource storage account show --name "$StorageAccountName" \
        --resource-group "$ResourceGroupName" --query name -o tsv; then
    echo "[WARNING] Storage account $StorageAccountName already exists, skipping"
else
    if az storage account create --name "$StorageAccountName" \
            --resource-group "$ResourceGroupName" --location "$LocationStorage" \
            --sku Standard_LRS --kind StorageV2 --access-tier Hot \
            --tags "project=$ProjectName" "environment=$Environment" --output table; then
        echo "[SUCCESS] Storage account $StorageAccountName created"
    else
        DEPLOYMENT_ERRORS+=("Creating storage account: $StorageAccountName")
    fi
fi

# Disable soft-delete for blobs, containers, file shares
echo "[INFO] Disabling soft-delete on storage account: $StorageAccountName"
az storage account blob-service-properties update --account-name "$StorageAccountName" \
    --resource-group "$ResourceGroupName" --enable-delete-retention false \
    --enable-container-delete-retention false --output none 2>/dev/null || \
    DEPLOYMENT_ERRORS+=("Disabling blob and container soft-delete")
az storage account file-service-properties update --account-name "$StorageAccountName" \
    --resource-group "$ResourceGroupName" --enable-delete-retention false --output none 2>/dev/null || \
    DEPLOYMENT_ERRORS+=("Disabling file share soft-delete")
echo "[SUCCESS] Soft-delete disabled on storage account"

# Derive container name from USER_EMAIL_ADDRESS
StorageBlobEndpoint=$(az storage account show --name "$StorageAccountName" \
    --resource-group "$ResourceGroupName" --query primaryEndpoints.blob -o tsv 2>/dev/null || true)
if [[ -z "$UserEmailAddress" ]]; then
    echo "[WARNING] USER_EMAIL_ADDRESS not set – skipping storage container creation"
else
    # Extract username part (before @), lowercase, replace invalid chars with hyphens
    local_part="${UserEmailAddress%%@*}"
    StorageContainerName=$(echo "${local_part,,}" | sed -E 's/[^a-z0-9-]/-/g; s/-+/-/g; s/^-|-$//g')
    echo "[INFO] Storage container name derived from email: $StorageContainerName"
    echo "[INFO] Storage blob endpoint: $StorageBlobEndpoint"
    existing_cnt=$(az storage container show --name "$StorageContainerName" \
        --account-name "$StorageAccountName" --auth-mode login --query name -o tsv 2>/dev/null || true)
    if [[ -n "$existing_cnt" ]]; then
        echo "[WARNING] Storage container '$StorageContainerName' already exists, skipping"
    else
        if az storage container create --name "$StorageContainerName" \
                --account-name "$StorageAccountName" --auth-mode login --output none 2>/dev/null; then
            echo "[SUCCESS] Storage container '$StorageContainerName' created"
        else
            DEPLOYMENT_ERRORS+=("Creating storage container: $StorageContainerName")
        fi
    fi
fi

# Create storage queue
echo "[INFO] Creating storage queue: $StorageQueueName"
existing_q=$(az storage queue show --name "$StorageQueueName" \
    --account-name "$StorageAccountName" --auth-mode login --query name -o tsv 2>/dev/null || true)
if [[ -n "$existing_q" ]]; then
    echo "[WARNING] Storage queue '$StorageQueueName' already exists, skipping"
else
    if az storage queue create --name "$StorageQueueName" \
            --account-name "$StorageAccountName" --auth-mode login --output none 2>/dev/null; then
        echo "[SUCCESS] Storage queue '$StorageQueueName' created"
    else
        DEPLOYMENT_ERRORS+=("Creating storage queue: $StorageQueueName")
    fi
fi

# =============================================================================
# STEP 3: Key Vault
# =============================================================================
echo ""
echo ">>> Step 3/12: Key Vault"
if test_az_resource keyvault show --name "$KeyVaultName" --query name -o tsv; then
    echo "[WARNING] Key Vault $KeyVaultName already exists, skipping creation"
else
    if az keyvault create --name "$KeyVaultName" --resource-group "$ResourceGroupName" \
            --location "$LocationKeyVault" --sku standard \
            --enable-rbac-authorization true --retention-days 7 \
            --tags "project=$ProjectName" "environment=$Environment" --output table; then
        echo "[SUCCESS] Key Vault $KeyVaultName created"
    else
        DEPLOYMENT_ERRORS+=("Creating Key Vault: $KeyVaultName")
    fi
fi

echo "[INFO] Setting Key Vault soft-delete retention to minimum (7 days), public network access enabled"
az keyvault update --name "$KeyVaultName" --resource-group "$ResourceGroupName" \
    --retention-days 7 --public-network-access Enabled --output none 2>/dev/null || true

# Grant current user Key Vault Administrator via RBAC
CurrentUserId=$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)
KeyVaultId=$(az keyvault show --name "$KeyVaultName" --resource-group "$ResourceGroupName" \
    --query id -o tsv 2>/dev/null || true)
if [[ -n "$CurrentUserId" && -n "$KeyVaultId" ]]; then
    ensure_role_assignment "$CurrentUserId" "Key Vault Administrator" "$KeyVaultId" "User"
    rc=$?
    if [[ $rc -eq 0 ]]; then
        echo "[OK] Key Vault Administrator role already assigned to current user"
    elif [[ $rc -eq 1 ]]; then
        echo "[SUCCESS] Key Vault Administrator role assigned to current user"
        echo "[INFO] Waiting 60 seconds for RBAC propagation..."
        sleep 60
    fi
fi

# =============================================================================
# STEP 4: Graph API Registration
# =============================================================================
echo ""
echo ">>> Step 4/12: Graph API Registration"
ExistingAppId=$(az ad app list --display-name "$GraphAppName" --query '[0].appId' -o tsv 2>/dev/null || true)
if [[ -n "$ExistingAppId" ]]; then
    echo "[OK] App registration $GraphAppName already exists with ID: $ExistingAppId"
    GraphClientId="$ExistingAppId"
else
    graph_perms='[{"resourceAppId":"00000003-0000-0000-c000-000000000000","resourceAccess":[{"id":"810c84a8-4a9e-49e6-bf7d-12d183f40d01","type":"Role"},{"id":"40f97065-369a-49f4-947c-6a255697ae91","type":"Role"}]}]'
    az ad app create --display-name "$GraphAppName" --sign-in-audience AzureADMyOrg \
        --required-resource-accesses "$graph_perms" --output none 2>/dev/null || true
    # Azure AD replicates the new object asynchronously; poll until it appears.
    for ((i=1; i<=12; i++)); do
        GraphClientId=$(az ad app list --display-name "$GraphAppName" --query '[0].appId' -o tsv 2>/dev/null || true)
        [[ -n "$GraphClientId" ]] && break
        echo "[INFO] Waiting for app registration to propagate (attempt $i/12)..."
        sleep 10
    done
    if [[ -n "$GraphClientId" ]]; then
        echo "[SUCCESS] App registration created with ID: $GraphClientId"
    else
        echo "[ERROR] App registration $GraphAppName created but ID could not be retrieved after 2 minutes" >&2
        DEPLOYMENT_ERRORS+=("Graph API app registration: $GraphAppName")
    fi
fi

if [[ -z "$GraphClientSecret" && -n "$GraphClientId" ]]; then
    existing_creds=$(az ad app credential list --id "$GraphClientId" --query '[0].keyId' -o tsv 2>/dev/null || true)
    if [[ -n "$existing_creds" ]]; then
        kv_secret=$(az keyvault secret show --vault-name "$KeyVaultName" \
            --name GraphClientSecret --query value -o tsv 2>/dev/null || true)
        if [[ -n "$kv_secret" ]]; then
            echo "[OK] Client secret already exists for $GraphAppName and is stored in Key Vault"
            GraphClientSecret="$kv_secret"
        else
            echo "[WARNING] Client secret exists in Entra ID but missing from Key Vault. Rotating..."
            GraphClientSecret=$(az ad app credential reset --id "$GraphClientId" \
                --display-name extract-insight-action-secret --years 2 --query password -o tsv 2>/dev/null || true)
            [[ -n "$GraphClientSecret" ]] && echo "[SUCCESS] Client secret rotated and will be stored in Key Vault" || \
                { echo "[ERROR] Failed to rotate client secret for $GraphAppName" >&2; DEPLOYMENT_ERRORS+=("Graph API client secret rotation"); }
        fi
    else
        GraphClientSecret=$(az ad app credential reset --id "$GraphClientId" \
            --display-name extract-insight-action-secret --years 2 --query password -o tsv 2>/dev/null || true)
        [[ -n "$GraphClientSecret" ]] && echo "[SUCCESS] Client secret created for Graph API" || \
            { echo "[ERROR] Failed to create client secret for $GraphAppName" >&2; DEPLOYMENT_ERRORS+=("Graph API client secret creation"); }
    fi
fi
[[ -z "$GraphClientSecret" ]] && \
    echo "[WARNING] GraphClientSecret is empty - the 'GraphClientSecret' KV secret will be skipped."

echo "[INFO] Run ./2.grant-graph-consent.sh $SUFFIX to grant admin consent (requires tenant admin role)"

# Web app Entra ID auth registration
webAppRedirectUri="https://${WebAppName}.azurewebsites.net/login/oauth2/code/azure"
localDevRedirectUri="http://localhost:8080/login/oauth2/code/azure"
existingWebAuthAppId=$(az ad app list --display-name "$WebAppAuthAppName" \
    --query '[0].appId' -o tsv 2>/dev/null || true)
if [[ -n "$existingWebAuthAppId" ]]; then
    echo "[OK] Web app auth registration $WebAppAuthAppName already exists with ID: $existingWebAuthAppId"
    WebAppClientId="$existingWebAuthAppId"
else
    az ad app create --display-name "$WebAppAuthAppName" --sign-in-audience AzureADMyOrg \
        --web-redirect-uris "$webAppRedirectUri" "$localDevRedirectUri" --output none 2>/dev/null || true
    # Azure AD replicates the new object asynchronously; poll until it appears.
    for ((i=1; i<=12; i++)); do
        WebAppClientId=$(az ad app list --display-name "$WebAppAuthAppName" \
            --query '[0].appId' -o tsv 2>/dev/null || true)
        [[ -n "$WebAppClientId" ]] && break
        echo "[INFO] Waiting for web app auth registration to propagate (attempt $i/12)..."
        sleep 10
    done
    if [[ -n "$WebAppClientId" ]]; then
        echo "[SUCCESS] Web app auth registration created with ID: $WebAppClientId"
    else
        echo "[ERROR] Failed to create web app auth registration: $WebAppAuthAppName" >&2
        DEPLOYMENT_ERRORS+=("Web app auth registration: $WebAppAuthAppName")
    fi
fi
[[ -n "$WebAppClientId" ]] && \
    az ad app update --id "$WebAppClientId" \
        --web-redirect-uris "$webAppRedirectUri" "$localDevRedirectUri" \
        --output none 2>/dev/null || true

if [[ -z "$WebAppClientSecret" && -n "$WebAppClientId" ]]; then
    existing_web_creds=$(az ad app credential list --id "$WebAppClientId" \
        --query '[0].keyId' -o tsv 2>/dev/null || true)
    if [[ -n "$existing_web_creds" ]]; then
        kv_web_secret=$(az keyvault secret show --vault-name "$KeyVaultName" \
            --name WebAppClientSecret --query value -o tsv 2>/dev/null || true)
        if [[ -n "$kv_web_secret" ]]; then
            echo "[OK] Client secret already exists for $WebAppAuthAppName and is stored in Key Vault"
            WebAppClientSecret="$kv_web_secret"
        else
            echo "[WARNING] Web app credential exists in Entra ID but missing from Key Vault. Rotating..."
            WebAppClientSecret=$(az ad app credential reset --id "$WebAppClientId" \
                --display-name insight-ui-auth-secret --years 2 --query password -o tsv 2>/dev/null || true)
            [[ -n "$WebAppClientSecret" ]] && echo "[SUCCESS] Web app client secret rotated and will be stored in Key Vault" || \
                { echo "[ERROR] Failed to rotate client secret for $WebAppAuthAppName" >&2; DEPLOYMENT_ERRORS+=("Web app auth client secret rotation"); }
        fi
    else
        WebAppClientSecret=$(az ad app credential reset --id "$WebAppClientId" \
            --display-name insight-ui-auth-secret --years 2 --query password -o tsv 2>/dev/null || true)
        [[ -n "$WebAppClientSecret" ]] && echo "[SUCCESS] Client secret created for web app auth registration" || \
            { echo "[ERROR] Failed to create client secret for $WebAppAuthAppName" >&2; DEPLOYMENT_ERRORS+=("Web app auth client secret creation"); }
    fi
fi
[[ -z "$WebAppClientId" ]] && echo "[WARNING] WebAppClientId is empty - the KV secret will be skipped."
[[ -z "$WebAppClientSecret" ]] && echo "[WARNING] WebAppClientSecret is empty - the KV secret will be skipped."

# =============================================================================
# STEP 5: Service Bus
# =============================================================================
echo ""
echo ">>> Step 5/12: Service Bus"
if test_az_resource servicebus namespace show --name "$ServiceBusNamespace" \
        --resource-group "$ResourceGroupName" --query name -o tsv; then
    echo "[WARNING] Service Bus namespace $ServiceBusNamespace already exists, skipping"
else
    if az servicebus namespace create --name "$ServiceBusNamespace" \
            --resource-group "$ResourceGroupName" --location "$LocationServiceBus" --sku Standard \
            --tags "project=$ProjectName" "environment=$Environment" --output table; then
        echo "[SUCCESS] Service Bus namespace $ServiceBusNamespace created"
    else
        DEPLOYMENT_ERRORS+=("Creating Service Bus namespace: $ServiceBusNamespace")
    fi
fi

if test_az_resource servicebus topic show --name "$ServiceBusTopicName" \
        --namespace-name "$ServiceBusNamespace" --resource-group "$ResourceGroupName" --query name -o tsv; then
    echo "[WARNING] Service Bus topic $ServiceBusTopicName already exists, skipping"
else
    if az servicebus topic create --name "$ServiceBusTopicName" \
            --namespace-name "$ServiceBusNamespace" --resource-group "$ResourceGroupName" \
            --max-size 1024 --default-message-time-to-live P14D \
            --enable-duplicate-detection true --duplicate-detection-history-time-window PT10M \
            --output table; then
        echo "[SUCCESS] Service Bus topic $ServiceBusTopicName created"
    else
        DEPLOYMENT_ERRORS+=("Creating Service Bus topic: $ServiceBusTopicName")
    fi
fi

if test_az_resource servicebus topic subscription show --name "$ServiceBusSubName" \
        --topic-name "$ServiceBusTopicName" --namespace-name "$ServiceBusNamespace" \
        --resource-group "$ResourceGroupName" --query name -o tsv; then
    echo "[WARNING] Service Bus subscription $ServiceBusSubName already exists, skipping"
else
    if az servicebus topic subscription create --name "$ServiceBusSubName" \
            --topic-name "$ServiceBusTopicName" --namespace-name "$ServiceBusNamespace" \
            --resource-group "$ResourceGroupName" \
            --max-delivery-count 10 --default-message-time-to-live P14D --output table; then
        echo "[SUCCESS] Service Bus subscription $ServiceBusSubName created"
    else
        DEPLOYMENT_ERRORS+=("Creating Service Bus subscription: $ServiceBusSubName")
    fi
fi

# =============================================================================
# STEP 6: Application Insights
# =============================================================================
echo ""
echo ">>> Step 6/12: Application Insights"
if test_az_resource monitor app-insights component show --app "$AppInsightsName" \
        --resource-group "$ResourceGroupName" --query name -o tsv; then
    echo "[WARNING] Application Insights $AppInsightsName already exists, skipping"
else
    if az monitor app-insights component create --app "$AppInsightsName" \
            --resource-group "$ResourceGroupName" --location "$LocationAppInsights" \
            --kind web --application-type web \
            --tags "project=$ProjectName" "environment=$Environment" --output table; then
        echo "[SUCCESS] Application Insights $AppInsightsName created"
    else
        DEPLOYMENT_ERRORS+=("Creating Application Insights: $AppInsightsName")
    fi
fi

# =============================================================================
# STEP 7: Azure Cosmos DB
# =============================================================================
echo ""
echo ">>> Step 7/12: Azure Cosmos DB (NoSQL)"
if test_az_resource cosmosdb show --name "$CosmosDbAccountName" \
        --resource-group "$ResourceGroupName" --query name -o tsv; then
    echo "[WARNING] Cosmos DB account $CosmosDbAccountName already exists, skipping account creation"
else
    if az cosmosdb create --name "$CosmosDbAccountName" --resource-group "$ResourceGroupName" \
            --locations "regionName=$LocationCosmosDb" "failoverPriority=0" "isZoneRedundant=false" \
            --kind GlobalDocumentDB --default-consistency-level Session \
            --tags "project=$ProjectName" "environment=$Environment" --output table; then
        echo "[SUCCESS] Cosmos DB account $CosmosDbAccountName created"
    else
        DEPLOYMENT_ERRORS+=("Creating Cosmos DB account: $CosmosDbAccountName")
    fi
fi

db_exists=$(az cosmosdb sql database show --account-name "$CosmosDbAccountName" \
    --resource-group "$ResourceGroupName" --name "$CosmosDbDatabaseName" --query name -o tsv 2>/dev/null || true)
if [[ -n "$db_exists" ]]; then
    echo "[WARNING] Database $CosmosDbDatabaseName already exists, skipping"
else
    az cosmosdb sql database create --account-name "$CosmosDbAccountName" \
        --resource-group "$ResourceGroupName" --name "$CosmosDbDatabaseName" --output table 2>/dev/null || \
        DEPLOYMENT_ERRORS+=("Creating database: $CosmosDbDatabaseName")
fi

container_exists=$(az cosmosdb sql container show --account-name "$CosmosDbAccountName" \
    --resource-group "$ResourceGroupName" --database-name "$CosmosDbDatabaseName" \
    --name "$CosmosDbContainerName" --query name -o tsv 2>/dev/null || true)
if [[ -n "$container_exists" ]]; then
    echo "[WARNING] Container $CosmosDbContainerName already exists, skipping"
else
    az cosmosdb sql container create --account-name "$CosmosDbAccountName" \
        --resource-group "$ResourceGroupName" --database-name "$CosmosDbDatabaseName" \
        --name "$CosmosDbContainerName" --partition-key-path /id --output table 2>/dev/null || \
        DEPLOYMENT_ERRORS+=("Creating container: $CosmosDbContainerName")
fi

# =============================================================================
# STEP 8: Azure Content Understanding
# =============================================================================
echo ""
echo ">>> Step 8/12: Azure Content Understanding"
if test_az_resource cognitiveservices account show --name "$ContentUnderstandingName" \
        --resource-group "$ResourceGroupName" --query name -o tsv; then
    echo "[WARNING] Content Understanding $ContentUnderstandingName already exists, skipping"
else
    if az cognitiveservices account create --name "$ContentUnderstandingName" \
            --resource-group "$ResourceGroupName" --location "$LocationContentUnderstanding" \
            --kind AIServices --sku S0 --custom-domain "$ContentUnderstandingName" \
            --tags "project=$ProjectName" "environment=$Environment" --output table --yes; then
        echo "[SUCCESS] Content Understanding $ContentUnderstandingName created"
        # The custom-domain DNS record takes time to become routable after account creation.
        # Data-plane calls to the endpoint will return 'Subdomain does not map to a resource'
        # until propagation completes. Wait before proceeding.
        echo "[INFO] Waiting 90 seconds for Content Understanding custom domain to propagate..."
        sleep 90
    else
        DEPLOYMENT_ERRORS+=("Creating Content Understanding: $ContentUnderstandingName")
    fi
fi

# =============================================================================
# STEP 9: Azure AI Foundry + LLM Model Deployment
# =============================================================================
echo ""
echo ">>> Step 9/12: Azure AI Foundry + LLM Model Deployment"
if test_az_resource cognitiveservices account show --name "$AiFoundryName" \
        --resource-group "$ResourceGroupName" --query name -o tsv; then
    echo "[WARNING] AI Foundry resource $AiFoundryName already exists, skipping creation"
else
    if az cognitiveservices account create --name "$AiFoundryName" \
            --resource-group "$ResourceGroupName" --location "$LocationAiFoundry" \
            --kind AIServices --sku S0 --custom-domain "$AiFoundryName" \
            --assign-identity \
            --tags "project=$ProjectName" "environment=$Environment" --output table --yes; then
        echo "[SUCCESS] AI Foundry resource $AiFoundryName created"
        # ARM needs time to fully initialise before accepting project child-resource PUTs.
        # provisioningState=Succeeded on the control plane does NOT mean the AI Foundry
        # backend service is ready — that initialises asynchronously and is not observable.
        echo "[INFO] Waiting 180 seconds for new AI Foundry account backend to initialise..."
        sleep 180
    else
        DEPLOYMENT_ERRORS+=("Creating AI Foundry resource: $AiFoundryName")
    fi
fi

AiFoundryAccountId=$(az cognitiveservices account show --name "$AiFoundryName" \
    --resource-group "$ResourceGroupName" --query id -o tsv 2>/dev/null || true)

if [[ -n "$AiFoundryAccountId" ]]; then
    apm_current=$(az resource show --ids "$AiFoundryAccountId" \
        --query 'properties.allowProjectManagement' -o tsv 2>/dev/null || true)
    apm_current="${apm_current,,}"
    if [[ "$apm_current" != "true" ]]; then
        if az resource update --ids "$AiFoundryAccountId" \
                --set properties.allowProjectManagement=true \
                --latest-include-preview --output none 2>/dev/null; then
            echo "[SUCCESS] Project management enabled on $AiFoundryName"
            echo "[INFO] Waiting 90 seconds for allowProjectManagement to propagate on fresh account..."
            sleep 90
        else
            DEPLOYMENT_ERRORS+=("Enabling project management on $AiFoundryName")
        fi
    else
        echo "[OK] Project management already enabled on $AiFoundryName"
    fi
else
    echo "[ERROR] Could not resolve AI Foundry account id; skipping project setup" >&2
fi

# Create AI Foundry project (child resource via az rest PUT)
#
# ARM project creation is an async LRO: the PUT returns HTTP 202 Accepted
# immediately, then ARM creates the resource in the background. Some az CLI
# versions treat a 202 response as a non-zero exit, even though the operation
# is in flight and will succeed shortly.
#
# Strategy:
#   1. Poll the account until provisioningState=Succeeded AND allowProjectManagement=true.
#   2. Issue the PUT (up to 5 retries with exponential backoff for genuine transients).
#   3. Regardless of PUT exit code, poll az resource show for up to 10 minutes.
#   4. As soon as the resource appears with provisioningState=Succeeded, declare success.
#   5. Only declare failure if the poll times out.

# Poll the AI Foundry account until ARM reports it is fully ready for child-resource operations.
# Returns 0 when ready, 1 on timeout.
_wait_for_account_ready() {
    local account_id="$1" max_seconds="${2:-600}" interval="${3:-15}"
    local waited=0
    echo "[INFO] Polling AI Foundry account readiness (provisioningState=Succeeded + allowProjectManagement=true)..."
    while [[ $waited -lt $max_seconds ]]; do
        local prov apm
        prov=$(az resource show --ids "$account_id" \
            --query 'properties.provisioningState' -o tsv 2>/dev/null || true)
        apm=$(az resource show --ids "$account_id" \
            --query 'properties.allowProjectManagement' -o tsv 2>/dev/null || true)
        prov="${prov,,}"; apm="${apm,,}"
        if [[ "$prov" == "succeeded" && "$apm" == "true" ]]; then
            echo "[OK] AI Foundry account ready (provisioningState=Succeeded, allowProjectManagement=true) after ${waited}s"
            return 0
        fi
        echo "[INFO] Account not ready yet (provisioningState=${prov:-(unknown)}, allowProjectManagement=${apm:-(unknown)}), waited ${waited}s / ${max_seconds}s..."
        sleep "$interval"
        waited=$(( waited + interval ))
    done
    echo "[ERROR] Timed out after ${max_seconds}s waiting for AI Foundry account to become ready" >&2
    return 1
}
_wait_for_project() {
    local resource_id="$1" api_ver="$2" max_seconds="${3:-600}" interval="${4:-15}"
    local waited=0
    while [[ $waited -lt $max_seconds ]]; do
        local prov_state
        prov_state=$(az resource show --ids "$resource_id" \
            --api-version "$api_ver" \
            --query 'properties.provisioningState' -o tsv 2>/dev/null || true)
        prov_state="${prov_state,,}"
        case "$prov_state" in
            succeeded)
                return 0 ;;
            canceled|deleting)
                echo "[ERROR] Project provisioningState = $prov_state" >&2
                return 2 ;;
            failed)
                # AI Foundry projects transiently report 'failed' during async LRO provisioning
                # before the backend settles; keep polling for the full window.
                echo "[INFO] Project provisioningState = 'failed' (may be transient), waited ${waited}s / ${max_seconds}s..."
                ;;
            creating|updating|accepted|running|provisioning|"")
                echo "[INFO] Project provisioningState = '${prov_state:-(not yet visible)}', waited ${waited}s / ${max_seconds}s..."
                ;;
            *)
                echo "[INFO] Project provisioningState = '$prov_state', waited ${waited}s / ${max_seconds}s..."
                ;;
        esac
        sleep "$interval"
        waited=$(( waited + interval ))
    done
    echo "[ERROR] Timed out after ${max_seconds}s waiting for project to reach Succeeded state" >&2
    return 1
}

if [[ -n "$AiFoundryAccountId" ]]; then
    # Wait until the account is fully ready before attempting any child-resource PUTs.
    # 'az cognitiveservices account create' returns as soon as the ARM record is written,
    # but the backend service (project management layer) is still initialising.
    _wait_for_account_ready "$AiFoundryAccountId" 600 15 || true

    projectResourceId="${AiFoundryAccountId}/projects/${AiFoundryProjectName}"
    project_exists=$(az resource show --ids "$projectResourceId" \
        --api-version "$AiFoundryProjectApiVersion" \
        --query 'properties.provisioningState' -o tsv 2>/dev/null || true)
    project_exists_lc="${project_exists,,}"
    if [[ "$project_exists_lc" == "succeeded" ]]; then
        echo "[WARNING] AI Foundry project $AiFoundryProjectName already exists (Succeeded), skipping"
    elif [[ -n "$project_exists_lc" && "$project_exists_lc" != "none" && "$project_exists_lc" != "failed" ]]; then
        echo "[INFO] AI Foundry project $AiFoundryProjectName exists with state '$project_exists_lc', polling for completion..."
        if _wait_for_project "$projectResourceId" "$AiFoundryProjectApiVersion" 600 15; then
            echo "[SUCCESS] AI Foundry project $AiFoundryProjectName reached Succeeded state"
        else
            DEPLOYMENT_ERRORS+=("Creating AI Foundry project: $AiFoundryProjectName (state stuck at $project_exists_lc)")
        fi
    else
        project_body=$(jq -n \
            --arg loc "$LocationAiFoundry" \
            --arg dn "$AiFoundryProjectName" \
            --arg desc "AI Foundry project for $ProjectName ($Environment)" \
            '{location:$loc, identity:{type:"SystemAssigned"}, properties:{displayName:$dn, description:$desc}}')
        project_body_file=$(mktemp)
        echo "$project_body" > "$project_body_file"
        project_arm_url="https://management.azure.com${projectResourceId}?api-version=${AiFoundryProjectApiVersion}"

        # Issue the PUT — retry up to 5 times with exponential backoff for genuine
        # transient backend errors (ServiceUnavailable, 429, etc.).
        put_max=5
        for put_attempt in $(seq 1 $put_max); do
            echo "[INFO] Creating AI Foundry project: $AiFoundryProjectName (PUT attempt $put_attempt/$put_max)"
            az_silent rest --method put --url "$project_arm_url" \
                --body "@$project_body_file"
            put_exit=$LAST_EXIT
            if [[ $put_exit -eq 0 ]]; then
                break
            fi
            # 202 Accepted is success even though az CLI may return non-zero
            if echo "${LAST_ERR}${LAST_OUT}" | grep -qiE 'AsyncOperation|Operation-Location|"Accepted"|"creating"|202'; then
                echo "[INFO] PUT returned async/202 indicator — treating as accepted"
                break
            fi
            if [[ $put_attempt -lt $put_max ]]; then
                # Exponential backoff capped at 60s: 15, 30, 60, 60, ...
                delay=$(( 15 * (1 << (put_attempt - 1)) ))
                [[ $delay -gt 60 ]] && delay=60
                is_transient=0
                echo "${LAST_ERR}${LAST_OUT}" | grep -qiE 'InternalServerError|ServiceUnavailable|GatewayTimeout|429|TooManyRequests|temporar' && is_transient=1
                label="Error"; [[ $is_transient -eq 1 ]] && label="Transient error"
                echo "[WARNING] $label on attempt $put_attempt, retrying in ${delay}s..."
                sleep $delay
            fi
        done
        rm -f "$project_body_file"

        # Regardless of PUT exit code, poll until the resource reaches Succeeded.
        # ARM may have accepted the operation even when az CLI reported non-zero.
        echo "[INFO] Polling for project provisioning state (up to 10 min)..."
        if _wait_for_project "$projectResourceId" "$AiFoundryProjectApiVersion" 600 15; then
            echo "[SUCCESS] AI Foundry project $AiFoundryProjectName created (Succeeded)"
        else
            final_state=$(az resource show --ids "$projectResourceId" \
                --api-version "$AiFoundryProjectApiVersion" \
                --query 'properties.provisioningState' -o tsv 2>/dev/null || true)
            if [[ -n "$final_state" ]]; then
                echo "[ERROR] Creating AI Foundry project: $AiFoundryProjectName — stuck in state '${final_state}' after all retries" >&2
            else
                echo "[ERROR] Creating AI Foundry project: $AiFoundryProjectName — resource not found after all PUT attempts" >&2
            fi
            echo "  Verify: az resource show --ids $projectResourceId --api-version $AiFoundryProjectApiVersion" >&2
            DEPLOYMENT_ERRORS+=("Creating AI Foundry project: $AiFoundryProjectName")
        fi
    fi
fi

# Deploy LLM models from deploy-models.csv
if [[ ! -f "$DeployModelsCsvPath" ]]; then
    echo "[WARNING] $DeployModelsCsvPath not found - skipping model deployments"
else
    row_index=0
    while IFS= read -r model_line || [[ -n "$model_line" ]]; do
        model_line="${model_line#"${model_line%%[![:space:]]*}"}"; model_line="${model_line%"${model_line##*[![:space:]]}"}"
        [[ -z "$model_line" || "$model_line" == \#* ]] && continue
        IFS=',' read -ra cols <<< "$model_line"
        if (( ${#cols[@]} < 3 )); then
            echo "[WARNING] Skipping malformed line in deploy-models.csv: $model_line"
            continue
        fi
        model_name="${cols[0]// /}"; model_sku="${cols[1]// /}"; model_version="${cols[2]// /}"

        ok=0
        invoke_foundry_model_deployment "$AiFoundryName" "$ResourceGroupName" \
            "$model_name" "$model_sku" "$model_version" "$AiFoundrySkuCapacity" && ok=1

        while [[ $ok -eq 0 ]]; do
            show_model_suggestions "$LocationAiFoundry" "$model_name" "$model_sku"
            echo ""
            echo "[INPUT] Model '$model_name' (sku '$model_sku', version '$model_version') is unavailable. Provide an alternative or press Enter to skip."
            read -r -p "Alternative model name (Enter to skip): " alt_model
            if [[ -z "$alt_model" ]]; then
                echo "[INFO] Skipping model '$model_name'"
                break
            fi
            read -r -p "Alternative deployment type / sku-name (default: $model_sku): " alt_sku
            [[ -z "$alt_sku" ]] && alt_sku="$model_sku"
            alt_version=""
            while [[ -z "$alt_version" ]]; do
                read -r -p "Alternative model version: " alt_version
                [[ -z "$alt_version" ]] && echo "[ERROR] Model version is required"
            done
            model_name="${alt_model// /}"; model_sku="${alt_sku// /}"; model_version="${alt_version// /}"
            invoke_foundry_model_deployment "$AiFoundryName" "$ResourceGroupName" \
                "$model_name" "$model_sku" "$model_version" "$AiFoundrySkuCapacity" && ok=1
        done

        if (( row_index == 0 && ok == 1 )); then
            AiFoundryDeploymentName="$model_name"
            AiFoundryModelName="$model_name"
            AiFoundryModelVersion="$model_version"
        fi
        ((row_index++)) || true
    done < "$DeployModelsCsvPath"
fi

# CU completion model on CU resource
cu_deploy_exists=$(az cognitiveservices account deployment show \
    --name "$ContentUnderstandingName" --resource-group "$ResourceGroupName" \
    --deployment-name "$CuCompletionDeploymentName" --query name -o tsv 2>/dev/null || true)
if [[ -n "$cu_deploy_exists" ]]; then
    echo "[WARNING] CU completion model deployment $CuCompletionDeploymentName already exists on $ContentUnderstandingName, skipping"
else
    if az cognitiveservices account deployment create \
            --name "$ContentUnderstandingName" --resource-group "$ResourceGroupName" \
            --deployment-name "$CuCompletionDeploymentName" \
            --model-name "$CuCompletionModelName" --model-version "$CuCompletionModelVersion" \
            --model-format OpenAI --sku-name "$AiFoundrySkuName" --sku-capacity "$CuCompletionSkuCapacity" \
            --output table 2>/dev/null; then
        echo "[SUCCESS] CU completion model $CuCompletionModelName deployed as $CuCompletionDeploymentName on $ContentUnderstandingName"
    else
        DEPLOYMENT_ERRORS+=("Deploying CU completion model $CuCompletionModelName on $ContentUnderstandingName")
    fi
fi

cu_embed_exists=$(az cognitiveservices account deployment show \
    --name "$ContentUnderstandingName" --resource-group "$ResourceGroupName" \
    --deployment-name "$CuEmbeddingDeploymentName" --query name -o tsv 2>/dev/null || true)
if [[ -n "$cu_embed_exists" ]]; then
    echo "[WARNING] CU embedding model deployment $CuEmbeddingDeploymentName already exists on $ContentUnderstandingName, skipping"
else
    if az cognitiveservices account deployment create \
            --name "$ContentUnderstandingName" --resource-group "$ResourceGroupName" \
            --deployment-name "$CuEmbeddingDeploymentName" \
            --model-name "$CuEmbeddingModelName" --model-version "$CuEmbeddingModelVersion" \
            --model-format OpenAI --sku-name "$AiFoundrySkuName" --sku-capacity "$CuEmbeddingSkuCapacity" \
            --output table 2>/dev/null; then
        echo "[SUCCESS] CU embedding model $CuEmbeddingModelName deployed as $CuEmbeddingDeploymentName on $ContentUnderstandingName"
    else
        DEPLOYMENT_ERRORS+=("Deploying CU embedding model $CuEmbeddingModelName on $ContentUnderstandingName")
    fi
fi

# =============================================================================
# Configure Content Understanding defaults (PATCH)
# =============================================================================
echo ""
echo ">>> Configuring Content Understanding completion model defaults"
CuEndpoint=$(az cognitiveservices account show --name "$ContentUnderstandingName" \
    --resource-group "$ResourceGroupName" --query 'properties.endpoint' -o tsv 2>/dev/null || true)
CuResourceId=$(az cognitiveservices account show --name "$ContentUnderstandingName" \
    --resource-group "$ResourceGroupName" --query id -o tsv 2>/dev/null || true)

if [[ -z "$CuEndpoint" ]]; then
    echo "[WARNING] Cannot configure CU defaults - CU endpoint not available"
else
    # Ensure current user has Cognitive Services User on CU
    if [[ -n "$CurrentUserId" && -n "$CuResourceId" ]]; then
        ensure_role_assignment "$CurrentUserId" "Cognitive Services User" "$CuResourceId" "User"
        rc=$?
        if [[ $rc -eq 1 ]]; then
            echo "[INFO] Granted Cognitive Services User to current user on $ContentUnderstandingName"
            echo "[INFO] Waiting 60 seconds for RBAC propagation..."
            sleep 60
        fi
    fi

    cu_defaults_url="${CuEndpoint}contentunderstanding/defaults?api-version=2025-11-01"

    # Check if defaults already set correctly
    existing_defaults=$(az rest --method GET --url "$cu_defaults_url" \
        --resource https://cognitiveservices.azure.com -o json 2>/dev/null || echo '{}')
    cur_completion=$(echo "$existing_defaults" | jq -r --arg m "$CuCompletionModelName" \
        '.modelDeployments[$m] // empty' 2>/dev/null || true)
    cur_embedding=$(echo "$existing_defaults" | jq -r --arg m "$CuEmbeddingModelName" \
        '.modelDeployments[$m] // empty' 2>/dev/null || true)

    if [[ "$cur_completion" == "$CuCompletionDeploymentName" && "$cur_embedding" == "$CuEmbeddingDeploymentName" ]]; then
        echo "[OK] Content Understanding defaults already configured"
    else
        echo "[INFO] Content Understanding defaults need updating"
        defaults_body=$(jq -n \
            --arg cm "$CuCompletionModelName" --arg cd "$CuCompletionDeploymentName" \
            --arg em "$CuEmbeddingModelName" --arg ed "$CuEmbeddingDeploymentName" \
            '{modelDeployments: {($cm): $cd, ($em): $ed}}')
        defaults_file=$(mktemp)
        echo "$defaults_body" > "$defaults_file"
        cu_defaults_set=0
        for ((attempt=1; attempt<=5; attempt++)); do
            az_silent rest --method PATCH --url "$cu_defaults_url" \
                --resource https://cognitiveservices.azure.com \
                --body "@$defaults_file" --headers Content-Type=application/json
            if [[ $LAST_EXIT -eq 0 ]]; then
                echo "[SUCCESS] Content Understanding defaults set ($CuCompletionModelName -> $CuCompletionDeploymentName on $ContentUnderstandingName)"
                cu_defaults_set=1; break
            fi
            if [[ $attempt -lt 5 ]]; then
                if echo "$LAST_ERR" | grep -qi 'PermissionDenied'; then
                    echo "[INFO] Permission not yet propagated, retrying in 30 seconds (attempt $attempt/5)..."
                    sleep 30
                elif echo "$LAST_ERR" | grep -qi 'ResourceNotFound\|Subdomain does not map'; then
                    echo "[INFO] Endpoint not yet reachable (custom domain propagating), retrying in 30 seconds (attempt $attempt/5)..."
                    sleep 30
                else
                    break  # Non-retryable error
                fi
            fi
        done
        rm -f "$defaults_file"
        if [[ $cu_defaults_set -eq 0 ]]; then
            echo "[ERROR] Failed to set Content Understanding defaults" >&2
            [[ -n "$LAST_ERR" ]] && echo "  $LAST_ERR" >&2
            DEPLOYMENT_ERRORS+=("Content Understanding defaults")
        fi
    fi
fi

# =============================================================================
# STEP 10: App Service (Java Spring Boot Web App)
# =============================================================================
echo ""
echo ">>> Step 10/12: App Service (Java Spring Boot Web App)"
if test_az_resource appservice plan show --name "$AppServicePlanName" \
        --resource-group "$ResourceGroupName" --query name -o tsv; then
    echo "[WARNING] App Service Plan $AppServicePlanName already exists, skipping"
else
    if az appservice plan create --name "$AppServicePlanName" \
            --resource-group "$ResourceGroupName" --location "$LocationAppService" \
            --sku P0v3 --is-linux \
            --tags "project=$ProjectName" "environment=$Environment" --output table; then
        echo "[SUCCESS] App Service Plan $AppServicePlanName created"
    else
        DEPLOYMENT_ERRORS+=("Creating App Service Plan: $AppServicePlanName")
    fi
fi

if test_az_resource webapp show --name "$WebAppName" \
        --resource-group "$ResourceGroupName" --query name -o tsv; then
    echo "[WARNING] Web App $WebAppName already exists, skipping"
else
    if az webapp create --name "$WebAppName" --resource-group "$ResourceGroupName" \
            --plan "$AppServicePlanName" --runtime "JAVA:21-java21" \
            --tags "project=$ProjectName" "environment=$Environment" "app=spring-boot-web" --output table; then
        echo "[SUCCESS] Web App $WebAppName created"
    else
        DEPLOYMENT_ERRORS+=("Creating Web App: $WebAppName")
    fi
fi

# =============================================================================
# STEP 11: Function Apps (Flex Consumption)
# =============================================================================
echo ""
echo ">>> Step 11/12: Function Apps (Flex Consumption, Java 21)"
AppInsightsKey=$(az monitor app-insights component show --app "$AppInsightsName" \
    --resource-group "$ResourceGroupName" --query instrumentationKey -o tsv 2>/dev/null || true)

COMMON_FUNC_ARGS=(--resource-group "$ResourceGroupName"
    --storage-account "$StorageAccountName"
    --flexconsumption-location "$LocationFunctionApp"
    --runtime java --runtime-version 21.0)
if [[ -n "$AppInsightsKey" ]]; then
    COMMON_FUNC_ARGS+=(--app-insights "$AppInsightsName" --app-insights-key "$AppInsightsKey")
else
    echo "[WARNING] Application Insights key not found, creating function apps without App Insights"
    COMMON_FUNC_ARGS+=(--disable-app-insights true)
fi

create_func() {
    local name="$1" tag_func="$2"
    if test_az_resource functionapp show --name "$name" \
            --resource-group "$ResourceGroupName" --query name -o tsv; then
        echo "[WARNING] Function app $name already exists, skipping"
    else
        if az functionapp create --name "$name" "${COMMON_FUNC_ARGS[@]}" \
                --tags "project=$ProjectName" "environment=$Environment" "function=$tag_func" \
                --output table; then
            echo "[SUCCESS] Function app $name created"
        else
            DEPLOYMENT_ERRORS+=("Creating function app: $name")
        fi
    fi
}
create_func "$FuncMailboxName"   "mailbox-to-queue"
create_func "$FuncQueueDbName"   "queue-to-db"
create_func "$FuncCuQueueDbName" "cu-queue-to-db"

# =============================================================================
# STEP 12: Managed Identities & RBAC
# =============================================================================
echo ""
echo ">>> Step 12/12: Managed Identities & RBAC"

# Verify all resources exist before proceeding
check_exists() {
    local kind="$1" name="$2" rg="$3"
    test_az_resource "$kind" show --name "$name" --resource-group "$rg" --query name -o tsv
}

MailboxExists=$(check_exists functionapp "$FuncMailboxName" "$ResourceGroupName" && echo 1 || echo 0)
QueueDbExists=$(check_exists functionapp "$FuncQueueDbName" "$ResourceGroupName" && echo 1 || echo 0)
CuQueueDbExists=$(check_exists functionapp "$FuncCuQueueDbName" "$ResourceGroupName" && echo 1 || echo 0)
WebAppExists=$(check_exists webapp "$WebAppName" "$ResourceGroupName" && echo 1 || echo 0)

if [[ "$MailboxExists" == "0" || "$QueueDbExists" == "0" || "$CuQueueDbExists" == "0" ]]; then
    echo "[ERROR] One or more function apps do not exist. Cannot configure managed identities." >&2
    [[ "$MailboxExists" == "0" ]]   && echo "  Missing: $FuncMailboxName" >&2
    [[ "$QueueDbExists" == "0" ]]   && echo "  Missing: $FuncQueueDbName" >&2
    [[ "$CuQueueDbExists" == "0" ]] && echo "  Missing: $FuncCuQueueDbName" >&2
    exit 1
fi
if [[ "$WebAppExists" == "0" ]]; then
    echo "[ERROR] Web app $WebAppName does not exist. Cannot configure managed identity." >&2
    exit 1
fi

# Enable managed identities
get_or_assign_func_identity() {
    local name="$1" rg="$2"
    local id
    id=$(az functionapp identity show --name "$name" --resource-group "$rg" \
        --query principalId -o tsv 2>/dev/null || true)
    if [[ -n "$id" ]]; then
        echo "[OK] Managed identity already enabled for $name"
    else
        echo "[INFO] Enabling managed identity for $name"
        az functionapp identity assign --name "$name" --resource-group "$rg" --output none 2>/dev/null || true
        id=$(az functionapp identity show --name "$name" --resource-group "$rg" \
            --query principalId -o tsv 2>/dev/null || true)
        echo "[SUCCESS] Managed identity enabled for $name"
    fi
    echo "$id"
}
MailboxIdentity=$(get_or_assign_func_identity "$FuncMailboxName" "$ResourceGroupName")
QueueDbIdentity=$(get_or_assign_func_identity "$FuncQueueDbName" "$ResourceGroupName")
CuQueueDbIdentity=$(get_or_assign_func_identity "$FuncCuQueueDbName" "$ResourceGroupName")

WebAppIdentity=$(az webapp identity show --name "$WebAppName" --resource-group "$ResourceGroupName" \
    --query principalId -o tsv 2>/dev/null || true)
if [[ -n "$WebAppIdentity" ]]; then
    echo "[OK] Managed identity already enabled for $WebAppName"
else
    echo "[INFO] Enabling managed identity for $WebAppName"
    az webapp identity assign --name "$WebAppName" --resource-group "$ResourceGroupName" --output none 2>/dev/null || true
    WebAppIdentity=$(az webapp identity show --name "$WebAppName" --resource-group "$ResourceGroupName" \
        --query principalId -o tsv 2>/dev/null || true)
    echo "[SUCCESS] Managed identity enabled for $WebAppName"
fi

CuIdentity=$(az cognitiveservices account identity show --name "$ContentUnderstandingName" \
    --resource-group "$ResourceGroupName" --query principalId -o tsv 2>/dev/null || true)
if [[ -n "$CuIdentity" ]]; then
    echo "[OK] Managed identity already enabled for $ContentUnderstandingName"
else
    echo "[INFO] Enabling managed identity for $ContentUnderstandingName"
    az cognitiveservices account identity assign --name "$ContentUnderstandingName" \
        --resource-group "$ResourceGroupName" --output none 2>/dev/null || true
    CuIdentity=$(az cognitiveservices account identity show --name "$ContentUnderstandingName" \
        --resource-group "$ResourceGroupName" --query principalId -o tsv 2>/dev/null || true)
    if [[ -n "$CuIdentity" ]]; then
        echo "[SUCCESS] Managed identity enabled for $ContentUnderstandingName"
    else
        echo "[WARNING] Could not enable managed identity on $ContentUnderstandingName. Storage Blob Data Reader may need manual assignment."
    fi
fi

if [[ -z "$MailboxIdentity" || -z "$QueueDbIdentity" || -z "$CuQueueDbIdentity" || -z "$WebAppIdentity" ]]; then
    echo "[ERROR] Failed to retrieve managed identity principal IDs. Cannot assign RBAC." >&2
    exit 1
fi

newAssignments=0
# ra: wrapper for managed-identity RBAC assignments.
# Passes 'ServicePrincipal' to avoid graph.microsoft.com lookup on each call.
ra() {
    local assignee="$1" role="$2" scope="$3"
    ensure_role_assignment "$assignee" "$role" "$scope" "ServicePrincipal"
    [[ $? -eq 1 ]] && ((newAssignments++)) || true
}

# Key Vault Secrets User
KeyVaultId=$(az keyvault show --name "$KeyVaultName" --resource-group "$ResourceGroupName" \
    --query id -o tsv 2>/dev/null || true)
if [[ -z "$KeyVaultId" ]]; then
    echo "[ERROR] Could not retrieve Key Vault resource ID for '$KeyVaultName'. RBAC assignments for KV skipped." >&2
    DEPLOYMENT_ERRORS+=("Key Vault RBAC: could not retrieve resource ID for $KeyVaultName")
else
    echo "[INFO] Key Vault Secrets User role for function apps and web app"
    for identity in "$MailboxIdentity" "$QueueDbIdentity" "$CuQueueDbIdentity" "$WebAppIdentity"; do
        ra "$identity" "Key Vault Secrets User" "$KeyVaultId"
    done
fi

# Service Bus
ServiceBusId=$(az servicebus namespace show --name "$ServiceBusNamespace" \
    --resource-group "$ResourceGroupName" --query id -o tsv 2>/dev/null || true)
echo "[INFO] Service Bus roles for function apps"
ra "$MailboxIdentity"   "Azure Service Bus Data Sender"   "$ServiceBusId"
ra "$QueueDbIdentity"   "Azure Service Bus Data Receiver" "$ServiceBusId"
ra "$CuQueueDbIdentity" "Azure Service Bus Data Receiver" "$ServiceBusId"

# Storage
StorageAccountId=$(az storage account show --name "$StorageAccountName" \
    --resource-group "$ResourceGroupName" --query id -o tsv 2>/dev/null || true)
echo "[INFO] Storage account roles for function apps"
for identity in "$MailboxIdentity" "$QueueDbIdentity" "$CuQueueDbIdentity"; do
    for role in "Storage Blob Data Owner" "Storage Account Contributor" \
                "Storage Queue Data Contributor" "Storage Table Data Contributor"; do
        ra "$identity" "$role" "$StorageAccountId"
    done
done
echo "[INFO] Storage roles for web app"
ra "$WebAppIdentity" "Storage Blob Data Reader"        "$StorageAccountId"
ra "$WebAppIdentity" "Storage Table Data Contributor" "$StorageAccountId"
if [[ -n "$CurrentUserId" ]]; then
    echo "[INFO] Storage Blob Data Contributor for admin user"
    ensure_role_assignment "$CurrentUserId" "Storage Blob Data Contributor" "$StorageAccountId" "User"
    [[ $? -eq 1 ]] && ((newAssignments++)) || true
fi
if [[ -n "$CuIdentity" ]]; then
    echo "[INFO] Storage Blob Data Reader for Content Understanding"
    ra "$CuIdentity" "Storage Blob Data Reader" "$StorageAccountId"
fi

# Cosmos DB
CosmosDbAccountId=$(az cosmosdb show --name "$CosmosDbAccountName" \
    --resource-group "$ResourceGroupName" --query id -o tsv 2>/dev/null || true)
CosmosDataContributorRoleId="00000000-0000-0000-0000-000000000002"
echo "[INFO] Cosmos DB Data Contributor role for function apps and web app"
for identity in "$MailboxIdentity" "$QueueDbIdentity" "$CuQueueDbIdentity" "$WebAppIdentity"; do
    ensure_cosmos_role_assignment "$CosmosDbAccountName" "$ResourceGroupName" \
        "$CosmosDataContributorRoleId" "$identity" "$CosmosDbAccountId"
    [[ $? -eq 1 ]] && ((newAssignments++)) || true
done

# Content Understanding
ContentUnderstandingId=$(az cognitiveservices account show --name "$ContentUnderstandingName" \
    --resource-group "$ResourceGroupName" --query id -o tsv 2>/dev/null || true)
echo "[INFO] Cognitive Services User role for function apps and web app"
for identity in "$MailboxIdentity" "$QueueDbIdentity" "$CuQueueDbIdentity" "$WebAppIdentity"; do
    ra "$identity" "Cognitive Services User" "$ContentUnderstandingId"
done

# AI Foundry
# - Cognitive Services OpenAI User : chat completions / embeddings (function apps + web app)
# - Azure AI Developer (account)    : Agents API — account-level grant
# - Azure AI Developer (project)    : Agents API — project-level grant (required by Foundry portal RBAC)
AiFoundryId=$(az cognitiveservices account show --name "$AiFoundryName" \
    --resource-group "$ResourceGroupName" --query id -o tsv 2>/dev/null || true)
AiFoundryProjectId="${AiFoundryId}/projects/${AiFoundryProjectName}"

echo "[INFO] Cognitive Services OpenAI User role for function apps and web app"
for identity in "$MailboxIdentity" "$QueueDbIdentity" "$CuQueueDbIdentity" "$WebAppIdentity"; do
    ra "$identity" "Cognitive Services OpenAI User" "$AiFoundryId"
done

echo "[INFO] Azure AI Developer role for web app — account scope"
ra "$WebAppIdentity" "Azure AI Developer" "$AiFoundryId"
echo "[INFO] Azure AI Developer role for web app — project scope"
ra "$WebAppIdentity" "Azure AI Developer" "$AiFoundryProjectId"

# EIA AI Foundry Agent Writer (custom): Azure AI Developer only covers OpenAI/* data actions;
# the AIServices/* path (used by AI Foundry agents endpoint) is absent from that role definition.
EiaAgentWriterRole="EIA AI Foundry Agent Writer"
ensure_custom_role_definition \
    "$EiaAgentWriterRole" \
    "Grants AIServices/* data-plane access needed for AI Foundry agents API (AIServices/* absent from Azure AI Developer role definition)" \
    '["Microsoft.CognitiveServices/accounts/AIServices/*"]' \
    "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName"
# Resolve by ID — az CLI cannot resolve custom role names at deep sub-resource scopes
EiaAgentWriterRoleId=$(az role definition list --name "$EiaAgentWriterRole" --query '[0].id' -o tsv 2>/dev/null || true)
if [[ -z "$EiaAgentWriterRoleId" ]]; then
    echo "[ERROR] Could not resolve definition ID for custom role '$EiaAgentWriterRole'" >&2
    DEPLOYMENT_ERRORS+=("Custom role ID lookup failed: '$EiaAgentWriterRole'")
else
    echo "[INFO] $EiaAgentWriterRole (custom) for web app — account scope"
    ra "$WebAppIdentity" "$EiaAgentWriterRoleId" "$AiFoundryId"
    echo "[INFO] $EiaAgentWriterRole (custom) for web app — project scope"
    ra "$WebAppIdentity" "$EiaAgentWriterRoleId" "$AiFoundryProjectId"
fi

if (( newAssignments > 0 )); then
    echo "[SUCCESS] $newAssignments new RBAC assignment(s) created"
else
    echo "[OK] All RBAC assignments already in place"
fi

if (( newAssignments > 0 )); then
    echo ""
    echo "[INFO] Waiting 30 seconds for RBAC propagation..."
    sleep 30
else
    echo "[OK] Skipping propagation wait (no new assignments)"
fi

# =============================================================================
# Store Secrets in Key Vault
# =============================================================================
echo "[INFO] Storing configuration secrets in Key Vault..."
echo "[INFO] Validating Key Vault write access..."

# Recover or purge soft-deleted test secret from previous run
az keyvault secret recover --vault-name "$KeyVaultName" --name deployment-test --output none 2>/dev/null || \
    az keyvault secret purge --vault-name "$KeyVaultName" --name deployment-test --output none 2>/dev/null || true

kv_ready=0
for ((i=1; i<=12; i++)); do
    if az keyvault secret set --vault-name "$KeyVaultName" --name deployment-test \
            --value ok --output none 2>/tmp/kv_test_err.$$; then
        kv_ready=1
        echo "[SUCCESS] Key Vault write access confirmed"
        rm -f /tmp/kv_test_err.$$; break
    fi
    reason=$(cat /tmp/kv_test_err.$$ 2>/dev/null || true)
    rm -f /tmp/kv_test_err.$$
    echo "[INFO] Key Vault not ready yet (attempt $i/12). Waiting 10 seconds..."
    [[ -n "$reason" ]] && echo "  Reason: $reason"
    sleep 10
done
if [[ $kv_ready -eq 0 ]]; then
    echo "[ERROR] Cannot write to Key Vault $KeyVaultName after 12 attempts." >&2
    echo "[ERROR] Ensure your account has 'Key Vault Administrator' or 'Key Vault Secrets Officer' role on the vault." >&2
    echo "[ERROR] Current user: $CurrentUserId" >&2
    echo "[ERROR] Key Vault ID: $KeyVaultId" >&2
    echo "[ERROR] You can assign it manually with:" >&2
    echo "  az role assignment create --assignee $CurrentUserId --role 'Key Vault Administrator' --scope $KeyVaultId" >&2
    exit 1
fi

SbConn=$(az servicebus namespace authorization-rule keys list \
    --namespace-name "$ServiceBusNamespace" --resource-group "$ResourceGroupName" \
    --name RootManageSharedAccessKey --query primaryConnectionString -o tsv 2>/dev/null || true)
KvUrl="https://$KeyVaultName.vault.azure.net/"
SbUrl="https://$ServiceBusNamespace.servicebus.windows.net/"
CosmosDbEndpoint=$(az cosmosdb show --name "$CosmosDbAccountName" \
    --resource-group "$ResourceGroupName" --query documentEndpoint -o tsv 2>/dev/null || true)
ContentUnderstandingEndpoint=$(az cognitiveservices account show --name "$ContentUnderstandingName" \
    --resource-group "$ResourceGroupName" --query 'properties.endpoint' -o tsv 2>/dev/null || true)
AiFoundryEndpoint=$(az cognitiveservices account show --name "$AiFoundryName" \
    --resource-group "$ResourceGroupName" --query 'properties.endpoint' -o tsv 2>/dev/null || true)
MailboxPollingSchedule="${MAILBOX_POLLING_SCHEDULE:-0 */5 * * * *}"

declare -A KV_SECRETS=(
    [ServiceBusConnectionString]="$SbConn"
    [MailboxPollingSchedule]="$MailboxPollingSchedule"
    [KeyVaultUrl]="$KvUrl"
    [ServiceBusUrl]="$SbUrl"
    [ServiceBusTopicName]="$ServiceBusTopicName"
    [ServiceBusSubscriptionName]="$ServiceBusSubName"
    [GraphClientId]="$GraphClientId"
    [GraphClientSecret]="$GraphClientSecret"
    [GraphTenantId]="$TenantId"
    [WebAppTenantId]="$TenantId"
    [WebAppClientId]="$WebAppClientId"
    [WebAppClientSecret]="$WebAppClientSecret"
    [CosmosDbEndpoint]="$CosmosDbEndpoint"
    [CosmosDbDatabaseName]="$CosmosDbDatabaseName"
    [CosmosDbContainerName]="$CosmosDbContainerName"
    [ContentUnderstandingEndpoint]="$ContentUnderstandingEndpoint"
    [ContentUnderstandingCompletionModel]="$CuCompletionModelName"
    [AiFoundryEndpoint]="$AiFoundryEndpoint"
    [AiFoundryDeploymentName]="$AiFoundryDeploymentName"
    [AiFoundryModelName]="$AiFoundryModelName"
    [AiFoundryApiVersion]="$AiFoundryApiVersion"
    [StorageEndpoint]="$StorageBlobEndpoint"
    [StorageContainerName]="$StorageContainerName"
    [StorageQueueName]="$StorageQueueName"
    [StorageQueuePollingSchedule]="$StorageQueuePollingSchedule"
    [UserEmailAddress]="$UserEmailAddress"
    [PollingMailboxName]="$PollingMailboxName"
    [ReadMailboxForPastNSeconds]="$ReadMailboxForPastNSeconds"
)
for key in "${!KV_SECRETS[@]}"; do
    val="${KV_SECRETS[$key]}"
    if [[ -z "$val" ]]; then
        echo "[WARNING] Skipping Key Vault secret '$key' - value is empty"
        continue
    fi
    if ! az keyvault secret set --vault-name "$KeyVaultName" --name "$key" \
            --value "$val" --output none 2>/tmp/kv_set_err.$$; then
        echo "[ERROR] Failed to set Key Vault secret: $key" >&2
        cat /tmp/kv_set_err.$$ >&2 || true
        DEPLOYMENT_ERRORS+=("Key Vault secret: $key")
    fi
    rm -f /tmp/kv_set_err.$$
done

if (( ${#DEPLOYMENT_ERRORS[@]} == 0 )); then
    echo "[SUCCESS] Secrets stored in Key Vault"
else
    echo "[WARNING] Some secrets failed to store in Key Vault"
fi

# =============================================================================
# Configure Function App Settings
# =============================================================================
echo "[INFO] Configuring Function App settings..."
echo "[INFO] Switching function apps to identity-based storage (runtime + deployment)"

for func_name in "$FuncMailboxName" "$FuncQueueDbName" "$FuncCuQueueDbName"; do
    # Remove key-based app settings
    az functionapp config appsettings delete --name "$func_name" --resource-group "$ResourceGroupName" \
        --setting-names AzureWebJobsStorage DEPLOYMENT_STORAGE_CONNECTION_STRING \
        --output none 2>/dev/null || true

    # Switch deployment storage to SystemAssignedIdentity via ARM REST
    site_json=$(az rest --method GET \
        --url "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$func_name?api-version=2024-04-01" \
        -o json 2>/dev/null || echo '{}')
    current_auth=$(echo "$site_json" | jq -r \
        '.properties.functionAppConfig.deployment.storage.authentication.type // empty' 2>/dev/null || true)
    if [[ "$current_auth" == "SystemAssignedIdentity" ]]; then
        echo "[OK] Already identity-based for $func_name"
        continue
    fi
    # Patch the auth type
    patch_body=$(echo "$site_json" | jq \
        '.properties.functionAppConfig.deployment.storage.authentication.type = "SystemAssignedIdentity" |
         .properties.functionAppConfig.deployment.storage.authentication.storageAccountConnectionStringName = null')
    patch_file=$(mktemp)
    echo "$patch_body" > "$patch_file"
    az_silent rest --method PUT \
        --url "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$func_name?api-version=2024-04-01" \
        --body "@$patch_file" --output none
    rm -f "$patch_file"
    if [[ $LAST_EXIT -ne 0 ]]; then
        echo "[ERROR] Failed to switch deployment storage for $func_name" >&2
        DEPLOYMENT_ERRORS+=("Deployment storage: $func_name")
    else
        echo "[SUCCESS] Switched to identity-based for $func_name"
    fi
done

# Mailbox function app settings
ServiceBusHostname="$ServiceBusNamespace.servicebus.windows.net"
set_function_app_settings "$FuncMailboxName" "$ResourceGroupName" \
    "AzureWebJobsStorage__accountName=$StorageAccountName" \
    "AZURE_KEY_VAULT_URL=$KvUrl" \
    "MailboxPollingSchedule=@Microsoft.KeyVault(VaultName=$KeyVaultName;SecretName=MailboxPollingSchedule)"

set_function_app_settings "$FuncQueueDbName" "$ResourceGroupName" \
    "AzureWebJobsStorage__accountName=$StorageAccountName" \
    "AZURE_KEY_VAULT_URL=$KvUrl" \
    "ServiceBusConnection__fullyQualifiedNamespace=$ServiceBusHostname" \
    "ServiceBusTopicName=$ServiceBusTopicName" \
    "ServiceBusSubscriptionName=$ServiceBusSubName"

set_function_app_settings "$FuncCuQueueDbName" "$ResourceGroupName" \
    "AzureWebJobsStorage__accountName=$StorageAccountName" \
    "AZURE_KEY_VAULT_URL=$KvUrl" \
    "StorageQueuePollingSchedule=@Microsoft.KeyVault(VaultName=$KeyVaultName;SecretName=StorageQueuePollingSchedule)"

echo "[SUCCESS] Function App settings configured"

# =============================================================================
# Configure Web App Settings
# =============================================================================
echo "[INFO] Configuring Web App settings..."
WebAppResourceId=$(az webapp show --name "$WebAppName" --resource-group "$ResourceGroupName" \
    --query id -o tsv 2>/dev/null || true)
web_settings_body=$(jq -n \
    --arg kvu "$KvUrl" \
    --arg kv "$KeyVaultName" \
    --arg cosmos "https://${CosmosDbAccountName}.documents.azure.com:443/" \
    --arg cdb "$CosmosDbDatabaseName" \
    --arg ccont "$CosmosDbContainerName" \
    --arg stg "https://${StorageAccountName}.blob.core.windows.net/" \
    --arg scont "$StorageContainerName" \
    '{properties: {
        AZURE_KEY_VAULT_URL: $kvu,
        TENANT_ID:           ("@Microsoft.KeyVault(VaultName=" + $kv + ";SecretName=WebAppTenantId)"),
        WEBAPP_CLIENT_ID:    ("@Microsoft.KeyVault(VaultName=" + $kv + ";SecretName=WebAppClientId)"),
        WEBAPP_CLIENT_SECRET:("@Microsoft.KeyVault(VaultName=" + $kv + ";SecretName=WebAppClientSecret)"),
        COSMOS_ENDPOINT:     $cosmos,
        COSMOS_DATABASE_NAME:$cdb,
        COSMOS_CONTAINER_NAME:$ccont,
        STORAGE_ENDPOINT:    $stg,
        STORAGE_CONTAINER_NAME:$scont,
        AI_FOUNDRY_REASONING_EFFORT:"medium",
        AGENT_CONVERSATION_TTL_HOURS:"168"
    }}')
web_settings_file=$(mktemp)
echo "$web_settings_body" > "$web_settings_file"
az_silent rest --method PUT \
    --url "https://management.azure.com${WebAppResourceId}/config/appsettings?api-version=2023-01-01" \
    --body "@$web_settings_file" --output none
rm -f "$web_settings_file"
if [[ $LAST_EXIT -ne 0 ]]; then
    echo "[ERROR] Failed to configure settings for web app $WebAppName" >&2
    DEPLOYMENT_ERRORS+=("Web app settings: $WebAppName")
else
    echo "[SUCCESS] Web App settings configured"
fi

# =============================================================================
# Cleanup: remove temporary deployment-test secret
# =============================================================================
echo "[INFO] Cleaning up temporary Key Vault secrets..."
if az keyvault secret delete --vault-name "$KeyVaultName" --name deployment-test \
        --output none 2>/dev/null; then
    sleep 5
    az keyvault secret purge --vault-name "$KeyVaultName" --name deployment-test \
        --output none 2>/dev/null || true
    echo "[OK] Temporary secret 'deployment-test' removed"
fi

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
if (( ${#DEPLOYMENT_ERRORS[@]} > 0 )); then
    echo "[FAILED] =========================================="
    echo "[FAILED] Infrastructure deployment completed with ${#DEPLOYMENT_ERRORS[@]} error(s)!"
    echo "[FAILED] =========================================="
    echo ""
    echo "  Failed operations:"
    for err in "${DEPLOYMENT_ERRORS[@]}"; do echo "    - $err"; done
    echo ""
    echo "  Resource Group      : $ResourceGroupName"
    echo "  Key Vault           : $KeyVaultName"
    echo "  Storage Account     : $StorageAccountName"
    echo "  Service Bus NS      : $ServiceBusNamespace"
    echo "  Service Bus Topic   : $ServiceBusTopicName"
    echo "  Cosmos DB Account   : $CosmosDbAccountName"
    echo "  Cosmos DB Database  : $CosmosDbDatabaseName"
    echo "  App Service Plan    : $AppServicePlanName"
    echo "  Web App             : $WebAppName"
    echo "  Function (Mailbox)  : $FuncMailboxName"
    echo "  Function (Queue-DB) : $FuncQueueDbName"
    echo "  Function (CU-Queue) : $FuncCuQueueDbName"
    echo "  Graph API App ID    : $GraphClientId"
    echo "  Content Understanding: $ContentUnderstandingName"
    echo "  AI Foundry          : $AiFoundryName"
    echo "  AI Foundry Model    : $AiFoundryDeploymentName"
    echo "  App Insights        : $AppInsightsName"
    echo "[FAILED] =========================================="
    echo ""
    echo "[INFO] Fix the errors above and re-run the script. It is idempotent and will skip already-created resources."
    exit 1
fi

echo "[SUCCESS] =========================================="
echo "[SUCCESS] Infrastructure deployment completed!"
echo "[SUCCESS] =========================================="
echo "  Resource Group      : $ResourceGroupName"
echo "  Key Vault           : $KeyVaultName"
echo "  Storage Account     : $StorageAccountName"
echo "  Service Bus NS      : $ServiceBusNamespace"
echo "  Service Bus Topic   : $ServiceBusTopicName"
echo "  Cosmos DB Account   : $CosmosDbAccountName"
echo "  Cosmos DB Database  : $CosmosDbDatabaseName"
echo "  App Service Plan    : $AppServicePlanName"
echo "  Web App             : $WebAppName"
echo "  Function (Mailbox)  : $FuncMailboxName"
echo "  Function (Queue-DB) : $FuncQueueDbName"
echo "  Function (CU-Queue) : $FuncCuQueueDbName"
echo "  Graph API App ID    : $GraphClientId"
echo "  Content Understanding: $ContentUnderstandingName"
echo "  AI Foundry          : $AiFoundryName"
echo "  AI Foundry Model    : $AiFoundryDeploymentName"
echo "  App Insights        : $AppInsightsName"
echo "[SUCCESS] =========================================="
echo ""
echo "[INFO] Next Steps:"
echo "  1. Grant Graph API admin consent (requires tenant admin role):"
echo "       ./2.grant-graph-consent.sh $SUFFIX"
echo "  2. Build and provision the Azure AI Foundry agents:"
echo "       ./3.deploy-agents.sh $SUFFIX"
echo "  3. Register Content Understanding analyzer schemas:"
echo "       ./4.content-understanding-add-schema.sh $SUFFIX"
echo "  4. Build and deploy application code (functions + web app):"
echo "       ./5.deploy-code.sh $SUFFIX"
echo "  5. (Optional) Configure operational tweaks in the deployed environment:"
echo "       ./6.operation-dev.sh $SUFFIX"
echo "  6. Test the deployment with sample data"

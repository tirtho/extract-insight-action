#!/bin/bash
# =============================================================================
# Azure Infrastructure Deployment Script for extract-insight-action
#
# Creates all necessary Azure resources. Idempotent - can be run multiple times safely.
#
# Usage:
#   chmod +x deploy-infrastructure.sh
#   ./deploy-infrastructure.sh <suffix>
#   ./deploy-infrastructure.sh 999
#
# Or source config.env first:
#   source config.env && ./deploy-infrastructure.sh 999
# =============================================================================

set -euo pipefail

# =============================================================================
# REQUIRED ARGUMENT: Suffix
# =============================================================================
if [ -z "${1:-}" ]; then
    echo "Usage: $0 <suffix>"
    echo "  <suffix>  Required. A short suffix (e.g. 999) appended to globally-unique resource names."
    echo ""
    echo "Example: $0 999"
    exit 1
fi
SUFFIX="$1"

# =============================================================================
# CONFIGURATION
# =============================================================================
PROJECT_NAME="${PROJECT_NAME:-eia}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
LOCATION="${LOCATION:-centralus}"

# Get subscription/tenant from Azure CLI
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-$(az account show --query id -o tsv 2>/dev/null || echo "")}"
TENANT_ID="${TENANT_ID:-$(az account show --query tenantId -o tsv 2>/dev/null || echo "")}"

# Suffix is a required command-line argument

# Resource names
PROJ_CLEAN="${PROJECT_NAME//-/}"
RESOURCE_GROUP_NAME="${RESOURCE_GROUP_NAME:-rg-${PROJECT_NAME}-${ENVIRONMENT}-${SUFFIX}}"
KEY_VAULT_NAME="${KEY_VAULT_NAME:-kv-${PROJECT_NAME}-${ENVIRONMENT}-${SUFFIX}}"
SERVICE_BUS_NAMESPACE="${SERVICE_BUS_NAMESPACE:-sb-${PROJECT_NAME}-${ENVIRONMENT}}"
STORAGE_ACCOUNT_NAME="${STORAGE_ACCOUNT_NAME:-st${PROJ_CLEAN}${ENVIRONMENT}${SUFFIX}}"
FUNC_MAILBOX_NAME="${FUNCTION_APP_MAILBOX_NAME:-func-mailbox-${PROJECT_NAME}-${ENVIRONMENT}}"
FUNC_QUEUEDB_NAME="${FUNCTION_APP_QUEUE_DB_NAME:-func-queuedb-${PROJECT_NAME}-${ENVIRONMENT}}"
SERVICE_BUS_TOPIC_NAME="${SERVICE_BUS_TOPIC_NAME:-email-processing}"
SERVICE_BUS_SUB_NAME="${SERVICE_BUS_SUBSCRIPTION_NAME:-email-processor}"
GRAPH_APP_NAME="${GRAPH_APP_NAME:-${PROJECT_NAME}-graph-api-${ENVIRONMENT}}"
GRAPH_CLIENT_ID="${GRAPH_CLIENT_ID:-}"
GRAPH_CLIENT_SECRET="${GRAPH_CLIENT_SECRET:-}"
APP_INSIGHTS_NAME="${APP_INSIGHTS_NAME:-ai-${PROJECT_NAME}-${ENVIRONMENT}}"
COSMOS_DB_ACCOUNT_NAME="${COSMOS_DB_ACCOUNT_NAME:-cosmos-${PROJECT_NAME}-${ENVIRONMENT}-${SUFFIX}}"
COSMOS_DB_DATABASE_NAME="DocAIDatabase"
COSMOS_DB_CONTAINER_NAME="EmailExtracts"
APP_SERVICE_PLAN_NAME="${APP_SERVICE_PLAN_NAME:-plan-${PROJECT_NAME}-${ENVIRONMENT}}"
WEB_APP_NAME="${WEB_APP_NAME:-app-${PROJECT_NAME}-${ENVIRONMENT}-${SUFFIX}}"
CONTENT_UNDERSTANDING_NAME="${CONTENT_UNDERSTANDING_NAME:-cu-${PROJECT_NAME}-${ENVIRONMENT}-${SUFFIX}}"
AI_FOUNDRY_NAME="${AI_FOUNDRY_NAME:-oai-${PROJECT_NAME}-${ENVIRONMENT}-${SUFFIX}}"
AI_FOUNDRY_DEPLOYMENT_NAME="gpt-4.1"
AI_FOUNDRY_MODEL_NAME="gpt-4.1"
AI_FOUNDRY_MODEL_VERSION="2025-04-14"
AI_FOUNDRY_API_VERSION="2024-12-01-preview"
AI_FOUNDRY_SKU_NAME="GlobalStandard"
AI_FOUNDRY_SKU_CAPACITY="50"

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================
DEPLOYMENT_ERRORS=()

log_info()    { echo -e "\033[0;36m[INFO]\033[0m $1"; }
log_success() { echo -e "\033[0;32m[SUCCESS]\033[0m $1"; }
log_warning() { echo -e "\033[1;33m[WARNING]\033[0m $1"; }
log_error()   { echo -e "\033[0;31m[ERROR]\033[0m $1"; }

# Run az CLI command, log errors, track failures. Returns stdout on success.
run_az() {
    local description="$1"
    shift
    log_info "$description"
    local output
    if output=$(az "$@" 2>&1); then
        echo "$output"
    else
        local exit_code=$?
        log_error "$description failed (exit code $exit_code)"
        echo "$output" | grep -i "error\|warning" | head -20 | while IFS= read -r line; do
            echo -e "\033[0;31m  $line\033[0m"
        done
        DEPLOYMENT_ERRORS+=("$description")
        return 1
    fi
}

# Run az CLI silently; captures exit code and stdout
run_az_silent() {
    local output
    output=$(az "$@" 2>/dev/null) && echo "$output" || return $?
}

# Check if a resource exists (returns 0 if exists, 1 otherwise)
resource_exists() {
    az "$@" > /dev/null 2>&1
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

# Ensure a Cosmos DB role assignment exists. Returns 0 if already existed, 1 if newly created.
ensure_cosmos_role_assignment() {
    local account_name="$1" resource_group="$2" role_def_id="$3" principal_id="$4" scope="$5"
    local existing
    existing=$(az cosmosdb sql role assignment list \
        --account-name "$account_name" --resource-group "$resource_group" \
        --query "[?principalId=='$principal_id'] | [0].id" --output tsv 2>/dev/null || echo "")
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

# Set function app settings using az rest + temp JSON file (merge with existing)
set_function_app_settings() {
    local func_name="$1"
    local resource_group="$2"
    shift 2

    local func_id
    func_id=$(az functionapp show --name "$func_name" --resource-group "$resource_group" --query id -o tsv 2>/dev/null) || return 1

    local existing_json
    existing_json=$(az rest --method POST --url "${func_id}/config/appsettings/list?api-version=2023-01-01" 2>/dev/null) || existing_json='{}'

    local merged
    merged=$(echo "$existing_json" | jq -r '.properties // {}')

    for setting in "$@"; do
        local key="${setting%%=*}"
        local value="${setting#*=}"
        merged=$(echo "$merged" | jq --arg k "$key" --arg v "$value" '. + {($k): $v}')
    done

    local temp_file
    temp_file=$(mktemp)
    echo "$merged" | jq '{properties: .}' > "$temp_file"

    az rest --method PUT \
        --url "${func_id}/config/appsettings?api-version=2023-01-01" \
        --body "@${temp_file}" \
        --output none 2>/dev/null
    local rc=$?
    rm -f "$temp_file"
    return $rc
}

# =============================================================================
# BANNER
# =============================================================================
echo ""
log_info "============================================================"
log_info "Azure Infrastructure Deployment for $PROJECT_NAME"
log_info "Environment : $ENVIRONMENT"
log_info "Location    : $LOCATION"
log_info "RG          : $RESOURCE_GROUP_NAME"
log_info "============================================================"
echo ""

# =============================================================================
# PREREQUISITES
# =============================================================================
log_info "Checking prerequisites..."

if ! command -v az &> /dev/null; then
    log_error "Azure CLI is not installed."
    exit 1
fi

if ! command -v jq &> /dev/null; then
    log_error "jq is not installed. Install it with: sudo apt-get install jq (or brew install jq)"
    exit 1
fi

ACCT_STATE=$(az account show --query state -o tsv 2>/dev/null || echo "")
if [ "$ACCT_STATE" != "Enabled" ]; then
    log_error "Not logged in to Azure CLI. Run 'az login' first."
    exit 1
fi

if [ -n "$SUBSCRIPTION_ID" ]; then
    az account set --subscription "$SUBSCRIPTION_ID"
    log_success "Subscription set to: $SUBSCRIPTION_ID"
fi

log_info "Installing/upgrading required Azure CLI extensions..."
az extension add --name application-insights --upgrade --yes 2>/dev/null || true
log_success "Prerequisites OK"

# =============================================================================
# STEP 1/11: Resource Group
# =============================================================================
echo ""
echo ">>> Step 1/12: Resource Group"

if resource_exists group show --name "$RESOURCE_GROUP_NAME" --query name -o tsv; then
    log_warning "Resource group $RESOURCE_GROUP_NAME already exists, skipping"
else
    run_az "Creating resource group: $RESOURCE_GROUP_NAME" \
        group create --name "$RESOURCE_GROUP_NAME" --location "$LOCATION" \
        --tags "project=$PROJECT_NAME" "environment=$ENVIRONMENT" --output table
    log_success "Resource group $RESOURCE_GROUP_NAME created"
fi

# =============================================================================
# STEP 2/11: Storage Account
# =============================================================================
echo ""
echo ">>> Step 2/12: Storage Account"

if resource_exists storage account show --name "$STORAGE_ACCOUNT_NAME" --resource-group "$RESOURCE_GROUP_NAME" --query name -o tsv; then
    log_warning "Storage account $STORAGE_ACCOUNT_NAME already exists, skipping"
else
    run_az "Creating storage account: $STORAGE_ACCOUNT_NAME" \
        storage account create --name "$STORAGE_ACCOUNT_NAME" \
        --resource-group "$RESOURCE_GROUP_NAME" --location "$LOCATION" \
        --sku Standard_LRS --kind StorageV2 --access-tier Hot \
        --tags "project=$PROJECT_NAME" "environment=$ENVIRONMENT" --output table
    log_success "Storage account $STORAGE_ACCOUNT_NAME created"
fi

log_info "Disabling soft-delete on storage account: $STORAGE_ACCOUNT_NAME"
run_az "Disabling blob and container soft-delete" \
    storage account blob-service-properties update \
    --account-name "$STORAGE_ACCOUNT_NAME" --resource-group "$RESOURCE_GROUP_NAME" \
    --enable-delete-retention false --enable-container-delete-retention false \
    --output none
run_az "Disabling file share soft-delete" \
    storage account file-service-properties update \
    --account-name "$STORAGE_ACCOUNT_NAME" --resource-group "$RESOURCE_GROUP_NAME" \
    --enable-delete-retention false \
    --output none
log_success "Soft-delete disabled on storage account"

# =============================================================================
# STEP 3/11: Key Vault
# =============================================================================
echo ""
echo ">>> Step 3/12: Key Vault"

if resource_exists keyvault show --name "$KEY_VAULT_NAME" --query name -o tsv; then
    log_warning "Key Vault $KEY_VAULT_NAME already exists, skipping creation"
else
    run_az "Creating Key Vault: $KEY_VAULT_NAME" \
        keyvault create --name "$KEY_VAULT_NAME" \
        --resource-group "$RESOURCE_GROUP_NAME" --location "$LOCATION" \
        --sku standard --enable-rbac-authorization true \
        --retention-days 7 \
        --tags "project=$PROJECT_NAME" "environment=$ENVIRONMENT" --output table
    log_success "Key Vault $KEY_VAULT_NAME created"
fi

# Ensure minimum soft-delete retention (7 days), no purge protection, and public network access
# Note: Soft-delete cannot be fully disabled on Azure Key Vault (enforced since 2020)
log_info "Setting Key Vault soft-delete retention to minimum (7 days), public network access enabled"
az keyvault update --name "$KEY_VAULT_NAME" \
    --resource-group "$RESOURCE_GROUP_NAME" \
    --retention-days 7 \
    --public-network-access Enabled \
    --output none 2>/dev/null || true

CURRENT_USER_ID=$(az ad signed-in-user show --query id -o tsv 2>/dev/null || echo "")
KEY_VAULT_ID=$(az keyvault show --name "$KEY_VAULT_NAME" --resource-group "$RESOURCE_GROUP_NAME" --query id -o tsv 2>/dev/null || echo "")
if [ -n "$CURRENT_USER_ID" ] && [ -n "$KEY_VAULT_ID" ]; then
    if ensure_role_assignment "$CURRENT_USER_ID" "Key Vault Administrator" "$KEY_VAULT_ID"; then
        log_success "Key Vault Administrator role already assigned to current user"
    else
        log_success "Key Vault Administrator role assigned to current user"
        log_info "Waiting 60 seconds for RBAC propagation..."
        sleep 60
    fi
fi

# =============================================================================
# STEP 4/11: Graph API Registration
# =============================================================================
echo ""
echo ">>> Step 4/12: Graph API Registration"

EXISTING_APP_ID=$(az ad app list --display-name "$GRAPH_APP_NAME" --query "[0].appId" -o tsv 2>/dev/null || echo "")
if [ -n "$EXISTING_APP_ID" ] && [ "$EXISTING_APP_ID" != "None" ]; then
    log_success "App registration $GRAPH_APP_NAME already exists with ID: $EXISTING_APP_ID"
    GRAPH_CLIENT_ID="$EXISTING_APP_ID"
else
    GRAPH_PERMS='[{"resourceAppId":"00000003-0000-0000-c000-000000000000","resourceAccess":[{"id":"810c84a8-4a9e-49e6-bf7d-12d183f40d01","type":"Role"},{"id":"40f97065-369a-49f4-947c-6a255697ae91","type":"Role"}]}]'
    az ad app create --display-name "$GRAPH_APP_NAME" --sign-in-audience AzureADMyOrg \
        --required-resource-accesses "$GRAPH_PERMS" --output none 2>/dev/null || true
    GRAPH_CLIENT_ID=$(az ad app list --display-name "$GRAPH_APP_NAME" --query "[0].appId" -o tsv 2>/dev/null || echo "")
    log_success "App registration created with ID: $GRAPH_CLIENT_ID"
fi

if [ -z "$GRAPH_CLIENT_SECRET" ]; then
    # Check if credentials already exist to avoid invalidating stored secrets
    EXISTING_CREDS=$(az ad app credential list --id "$GRAPH_CLIENT_ID" --query "[0].keyId" -o tsv 2>/dev/null || echo "")
    if [ -n "$EXISTING_CREDS" ]; then
        log_success "Client secret already exists for $GRAPH_APP_NAME (stored in Key Vault)"
    else
        GRAPH_CLIENT_SECRET=$(az ad app credential reset --id "$GRAPH_CLIENT_ID" \
            --display-name "extract-insight-action-secret" --years 2 --query password -o tsv 2>/dev/null || echo "")
        log_success "Client secret created for Graph API"
    fi
fi

log_info "Run ./grant-graph-consent.sh $SUFFIX to grant admin consent (requires tenant admin role)"

# =============================================================================
# STEP 5/11: Service Bus
# =============================================================================
echo ""
echo ">>> Step 5/12: Service Bus"

if resource_exists servicebus namespace show --name "$SERVICE_BUS_NAMESPACE" --resource-group "$RESOURCE_GROUP_NAME" --query name -o tsv; then
    log_warning "Service Bus namespace $SERVICE_BUS_NAMESPACE already exists, skipping"
else
    run_az "Creating Service Bus namespace: $SERVICE_BUS_NAMESPACE" \
        servicebus namespace create --name "$SERVICE_BUS_NAMESPACE" \
        --resource-group "$RESOURCE_GROUP_NAME" --location "$LOCATION" \
        --sku Standard \
        --tags "project=$PROJECT_NAME" "environment=$ENVIRONMENT" --output table
    log_success "Service Bus namespace $SERVICE_BUS_NAMESPACE created"
fi

if resource_exists servicebus topic show --name "$SERVICE_BUS_TOPIC_NAME" --namespace-name "$SERVICE_BUS_NAMESPACE" --resource-group "$RESOURCE_GROUP_NAME" --query name -o tsv; then
    log_warning "Service Bus topic $SERVICE_BUS_TOPIC_NAME already exists, skipping"
else
    run_az "Creating Service Bus topic: $SERVICE_BUS_TOPIC_NAME" \
        servicebus topic create --name "$SERVICE_BUS_TOPIC_NAME" \
        --namespace-name "$SERVICE_BUS_NAMESPACE" --resource-group "$RESOURCE_GROUP_NAME" \
        --max-size 1024 --default-message-time-to-live P14D --output table
    log_success "Service Bus topic $SERVICE_BUS_TOPIC_NAME created"
fi

if resource_exists servicebus topic subscription show --name "$SERVICE_BUS_SUB_NAME" --topic-name "$SERVICE_BUS_TOPIC_NAME" --namespace-name "$SERVICE_BUS_NAMESPACE" --resource-group "$RESOURCE_GROUP_NAME" --query name -o tsv; then
    log_warning "Service Bus subscription $SERVICE_BUS_SUB_NAME already exists, skipping"
else
    run_az "Creating Service Bus subscription: $SERVICE_BUS_SUB_NAME" \
        servicebus topic subscription create --name "$SERVICE_BUS_SUB_NAME" \
        --topic-name "$SERVICE_BUS_TOPIC_NAME" --namespace-name "$SERVICE_BUS_NAMESPACE" \
        --resource-group "$RESOURCE_GROUP_NAME" \
        --max-delivery-count 10 --default-message-time-to-live P14D --output table
    log_success "Service Bus subscription $SERVICE_BUS_SUB_NAME created"
fi

# =============================================================================
# STEP 6/11: Application Insights
# =============================================================================
echo ""
echo ">>> Step 6/12: Application Insights"

if resource_exists monitor app-insights component show --app "$APP_INSIGHTS_NAME" --resource-group "$RESOURCE_GROUP_NAME" --query name -o tsv; then
    log_warning "Application Insights $APP_INSIGHTS_NAME already exists, skipping"
else
    run_az "Creating Application Insights: $APP_INSIGHTS_NAME" \
        monitor app-insights component create --app "$APP_INSIGHTS_NAME" \
        --resource-group "$RESOURCE_GROUP_NAME" --location "$LOCATION" \
        --kind web --application-type web \
        --tags "project=$PROJECT_NAME" "environment=$ENVIRONMENT" --output table
    log_success "Application Insights $APP_INSIGHTS_NAME created"
fi

# =============================================================================
# STEP 7/12: Azure Cosmos DB (NoSQL)
# =============================================================================
echo ""
echo ">>> Step 7/12: Azure Cosmos DB (NoSQL)"

if resource_exists cosmosdb show --name "$COSMOS_DB_ACCOUNT_NAME" --resource-group "$RESOURCE_GROUP_NAME" --query name -o tsv; then
    log_warning "Cosmos DB account $COSMOS_DB_ACCOUNT_NAME already exists, skipping account creation"
else
    if run_az "Creating Cosmos DB account: $COSMOS_DB_ACCOUNT_NAME" \
        cosmosdb create --name "$COSMOS_DB_ACCOUNT_NAME" \
        --resource-group "$RESOURCE_GROUP_NAME" \
        --locations regionName="$LOCATION" failoverPriority=0 isZoneRedundant=false \
        --kind GlobalDocumentDB \
        --default-consistency-level Session \
        --tags "project=$PROJECT_NAME" "environment=$ENVIRONMENT" \
        --output table; then
        log_success "Cosmos DB account $COSMOS_DB_ACCOUNT_NAME created"
    fi
fi

DB_EXISTS=$(az cosmosdb sql database show --account-name "$COSMOS_DB_ACCOUNT_NAME" --resource-group "$RESOURCE_GROUP_NAME" --name "$COSMOS_DB_DATABASE_NAME" --query name -o tsv 2>/dev/null || echo "")
if [ -n "$DB_EXISTS" ]; then
    log_warning "Database $COSMOS_DB_DATABASE_NAME already exists, skipping"
else
    run_az "Creating database: $COSMOS_DB_DATABASE_NAME" \
        cosmosdb sql database create --account-name "$COSMOS_DB_ACCOUNT_NAME" \
        --resource-group "$RESOURCE_GROUP_NAME" --name "$COSMOS_DB_DATABASE_NAME" \
        --output table
fi

CONTAINER_EXISTS=$(az cosmosdb sql container show --account-name "$COSMOS_DB_ACCOUNT_NAME" --resource-group "$RESOURCE_GROUP_NAME" --database-name "$COSMOS_DB_DATABASE_NAME" --name "$COSMOS_DB_CONTAINER_NAME" --query name -o tsv 2>/dev/null || echo "")
if [ -n "$CONTAINER_EXISTS" ]; then
    log_warning "Container $COSMOS_DB_CONTAINER_NAME already exists, skipping"
else
    run_az "Creating container: $COSMOS_DB_CONTAINER_NAME (partition key: /id)" \
        cosmosdb sql container create --account-name "$COSMOS_DB_ACCOUNT_NAME" \
        --resource-group "$RESOURCE_GROUP_NAME" --database-name "$COSMOS_DB_DATABASE_NAME" \
        --name "$COSMOS_DB_CONTAINER_NAME" --partition-key-path "/id" \
        --output table
fi

# =============================================================================
# STEP 8/12: Azure Content Understanding
# =============================================================================
echo ""
echo ">>> Step 8/12: Azure Content Understanding"

if resource_exists cognitiveservices account show --name "$CONTENT_UNDERSTANDING_NAME" --resource-group "$RESOURCE_GROUP_NAME" --query name -o tsv; then
    log_warning "Content Understanding $CONTENT_UNDERSTANDING_NAME already exists, skipping"
else
    if run_az "Creating Azure Content Understanding: $CONTENT_UNDERSTANDING_NAME" \
        cognitiveservices account create --name "$CONTENT_UNDERSTANDING_NAME" \
        --resource-group "$RESOURCE_GROUP_NAME" --location "$LOCATION" \
        --kind AIServices --sku S0 \
        --custom-domain "$CONTENT_UNDERSTANDING_NAME" \
        --tags "project=$PROJECT_NAME" "environment=$ENVIRONMENT" \
        --output table --yes; then
        log_success "Content Understanding $CONTENT_UNDERSTANDING_NAME created"
    fi
fi

# =============================================================================
# STEP 9/12: Azure AI Foundry + LLM Model Deployment
# =============================================================================
echo ""
echo ">>> Step 9/12: Azure AI Foundry + LLM Model Deployment"

# Create AI Foundry resource (Azure AI Services account)
if resource_exists cognitiveservices account show --name "$AI_FOUNDRY_NAME" --resource-group "$RESOURCE_GROUP_NAME" --query name -o tsv; then
    log_warning "AI Foundry resource $AI_FOUNDRY_NAME already exists, skipping"
else
    if run_az "Creating Azure AI Foundry resource: $AI_FOUNDRY_NAME" \
        cognitiveservices account create --name "$AI_FOUNDRY_NAME" \
        --resource-group "$RESOURCE_GROUP_NAME" --location "$LOCATION" \
        --kind AIServices --sku S0 \
        --custom-domain "$AI_FOUNDRY_NAME" \
        --tags "project=$PROJECT_NAME" "environment=$ENVIRONMENT" \
        --output table --yes; then
        log_success "AI Foundry resource $AI_FOUNDRY_NAME created"
    fi
fi

# Deploy LLM model (gpt-4.1, GlobalStandard, 50K TPM)
DEPLOYMENT_EXISTS=$(az cognitiveservices account deployment show --name "$AI_FOUNDRY_NAME" --resource-group "$RESOURCE_GROUP_NAME" --deployment-name "$AI_FOUNDRY_DEPLOYMENT_NAME" --query name -o tsv 2>/dev/null || echo "")
if [ -n "$DEPLOYMENT_EXISTS" ]; then
    log_warning "Model deployment $AI_FOUNDRY_DEPLOYMENT_NAME already exists, skipping"
else
    if run_az "Deploying model $AI_FOUNDRY_MODEL_NAME ($AI_FOUNDRY_SKU_NAME, ${AI_FOUNDRY_SKU_CAPACITY}K TPM)" \
        cognitiveservices account deployment create \
        --name "$AI_FOUNDRY_NAME" --resource-group "$RESOURCE_GROUP_NAME" \
        --deployment-name "$AI_FOUNDRY_DEPLOYMENT_NAME" \
        --model-name "$AI_FOUNDRY_MODEL_NAME" \
        --model-version "$AI_FOUNDRY_MODEL_VERSION" \
        --model-format OpenAI \
        --sku-name "$AI_FOUNDRY_SKU_NAME" \
        --sku-capacity "$AI_FOUNDRY_SKU_CAPACITY" \
        --output table; then
        log_success "Model $AI_FOUNDRY_MODEL_NAME deployed as $AI_FOUNDRY_DEPLOYMENT_NAME"
    fi
fi

# =============================================================================
# STEP 10/12: App Service (Java Spring Boot Web App)
# =============================================================================
echo ""
echo ">>> Step 10/12: App Service (Java Spring Boot Web App)"

if resource_exists appservice plan show --name "$APP_SERVICE_PLAN_NAME" --resource-group "$RESOURCE_GROUP_NAME" --query name -o tsv; then
    log_warning "App Service Plan $APP_SERVICE_PLAN_NAME already exists, skipping"
else
    if run_az "Creating App Service Plan: $APP_SERVICE_PLAN_NAME (Linux P0v3)" \
        appservice plan create --name "$APP_SERVICE_PLAN_NAME" \
        --resource-group "$RESOURCE_GROUP_NAME" --location "$LOCATION" \
        --sku P0v3 --is-linux \
        --tags "project=$PROJECT_NAME" "environment=$ENVIRONMENT" \
        --output table; then
        log_success "App Service Plan $APP_SERVICE_PLAN_NAME created"
    fi
fi

if resource_exists webapp show --name "$WEB_APP_NAME" --resource-group "$RESOURCE_GROUP_NAME" --query name -o tsv; then
    log_warning "Web App $WEB_APP_NAME already exists, skipping"
else
    if run_az "Creating Web App: $WEB_APP_NAME (Java 21 Spring Boot)" \
        webapp create --name "$WEB_APP_NAME" \
        --resource-group "$RESOURCE_GROUP_NAME" \
        --plan "$APP_SERVICE_PLAN_NAME" \
        --runtime "JAVA:21-java21" \
        --tags "project=$PROJECT_NAME" "environment=$ENVIRONMENT" "app=spring-boot-web" \
        --output table; then
        log_success "Web App $WEB_APP_NAME created"
    fi
fi

# =============================================================================
# STEP 11/12: Function Apps (Flex Consumption)
# =============================================================================
echo ""
echo ">>> Step 11/12: Function Apps (Flex Consumption, Java 21)"

APP_INSIGHTS_KEY=$(az monitor app-insights component show --app "$APP_INSIGHTS_NAME" \
    --resource-group "$RESOURCE_GROUP_NAME" --query instrumentationKey -o tsv 2>/dev/null || echo "")

COMMON_FUNC_ARGS=(--resource-group "$RESOURCE_GROUP_NAME" --storage-account "$STORAGE_ACCOUNT_NAME"
                  --flexconsumption-location "$LOCATION"
                  --runtime java --runtime-version 21.0)
if [ -n "$APP_INSIGHTS_KEY" ]; then
    COMMON_FUNC_ARGS+=(--app-insights "$APP_INSIGHTS_NAME" --app-insights-key "$APP_INSIGHTS_KEY")
else
    log_warning "Application Insights key not found, creating function apps without App Insights"
    COMMON_FUNC_ARGS+=(--disable-app-insights true)
fi

if resource_exists functionapp show --name "$FUNC_MAILBOX_NAME" --resource-group "$RESOURCE_GROUP_NAME" --query name -o tsv; then
    log_warning "Function app $FUNC_MAILBOX_NAME already exists, skipping"
else
    if run_az "Creating function app: $FUNC_MAILBOX_NAME" \
        functionapp create --name "$FUNC_MAILBOX_NAME" \
        "${COMMON_FUNC_ARGS[@]}" \
        --tags "project=$PROJECT_NAME" "environment=$ENVIRONMENT" "function=mailbox-to-queue" \
        --output table; then
        log_success "Function app $FUNC_MAILBOX_NAME created"
    fi
fi

if resource_exists functionapp show --name "$FUNC_QUEUEDB_NAME" --resource-group "$RESOURCE_GROUP_NAME" --query name -o tsv; then
    log_warning "Function app $FUNC_QUEUEDB_NAME already exists, skipping"
else
    if run_az "Creating function app: $FUNC_QUEUEDB_NAME" \
        functionapp create --name "$FUNC_QUEUEDB_NAME" \
        "${COMMON_FUNC_ARGS[@]}" \
        --tags "project=$PROJECT_NAME" "environment=$ENVIRONMENT" "function=queue-to-db" \
        --output table; then
        log_success "Function app $FUNC_QUEUEDB_NAME created"
    fi
fi

# =============================================================================
# STEP 12/12: Managed Identities & RBAC
# =============================================================================
echo ""
echo ">>> Step 12/12: Managed Identities & RBAC"

MAILBOX_EXISTS=false
QUEUEDB_EXISTS=false
WEBAPP_EXISTS=false
resource_exists functionapp show --name "$FUNC_MAILBOX_NAME" --resource-group "$RESOURCE_GROUP_NAME" --query name -o tsv && MAILBOX_EXISTS=true
resource_exists functionapp show --name "$FUNC_QUEUEDB_NAME" --resource-group "$RESOURCE_GROUP_NAME" --query name -o tsv && QUEUEDB_EXISTS=true
resource_exists webapp show --name "$WEB_APP_NAME" --resource-group "$RESOURCE_GROUP_NAME" --query name -o tsv && WEBAPP_EXISTS=true

if [ "$MAILBOX_EXISTS" = false ] || [ "$QUEUEDB_EXISTS" = false ]; then
    log_error "One or both function apps do not exist. Cannot configure managed identities."
    [ "$MAILBOX_EXISTS" = false ] && log_error "  Missing: $FUNC_MAILBOX_NAME"
    [ "$QUEUEDB_EXISTS" = false ] && log_error "  Missing: $FUNC_QUEUEDB_NAME"
    log_error "Please fix the function app creation errors above and re-run the script."
    exit 1
fi
if [ "$WEBAPP_EXISTS" = false ]; then
    log_error "Web app $WEB_APP_NAME does not exist. Cannot configure managed identity."
    log_error "Please fix the web app creation errors above and re-run the script."
    exit 1
fi

# Enable managed identities (skip if already enabled)
MAILBOX_IDENTITY=$(az functionapp identity show --name "$FUNC_MAILBOX_NAME" --resource-group "$RESOURCE_GROUP_NAME" --query principalId -o tsv 2>/dev/null || echo "")
if [ -n "$MAILBOX_IDENTITY" ]; then
    log_success "Managed identity already enabled for $FUNC_MAILBOX_NAME"
else
    log_info "Enabling managed identity for $FUNC_MAILBOX_NAME"
    az functionapp identity assign --name "$FUNC_MAILBOX_NAME" --resource-group "$RESOURCE_GROUP_NAME" --output none 2>/dev/null
    MAILBOX_IDENTITY=$(az functionapp identity show --name "$FUNC_MAILBOX_NAME" --resource-group "$RESOURCE_GROUP_NAME" --query principalId -o tsv 2>/dev/null || echo "")
    log_success "Managed identity enabled for $FUNC_MAILBOX_NAME"
fi

QUEUEDB_IDENTITY=$(az functionapp identity show --name "$FUNC_QUEUEDB_NAME" --resource-group "$RESOURCE_GROUP_NAME" --query principalId -o tsv 2>/dev/null || echo "")
if [ -n "$QUEUEDB_IDENTITY" ]; then
    log_success "Managed identity already enabled for $FUNC_QUEUEDB_NAME"
else
    log_info "Enabling managed identity for $FUNC_QUEUEDB_NAME"
    az functionapp identity assign --name "$FUNC_QUEUEDB_NAME" --resource-group "$RESOURCE_GROUP_NAME" --output none 2>/dev/null
    QUEUEDB_IDENTITY=$(az functionapp identity show --name "$FUNC_QUEUEDB_NAME" --resource-group "$RESOURCE_GROUP_NAME" --query principalId -o tsv 2>/dev/null || echo "")
    log_success "Managed identity enabled for $FUNC_QUEUEDB_NAME"
fi

WEBAPP_IDENTITY=$(az webapp identity show --name "$WEB_APP_NAME" --resource-group "$RESOURCE_GROUP_NAME" --query principalId -o tsv 2>/dev/null || echo "")
if [ -n "$WEBAPP_IDENTITY" ]; then
    log_success "Managed identity already enabled for $WEB_APP_NAME"
else
    log_info "Enabling managed identity for $WEB_APP_NAME"
    az webapp identity assign --name "$WEB_APP_NAME" --resource-group "$RESOURCE_GROUP_NAME" --output none 2>/dev/null
    WEBAPP_IDENTITY=$(az webapp identity show --name "$WEB_APP_NAME" --resource-group "$RESOURCE_GROUP_NAME" --query principalId -o tsv 2>/dev/null || echo "")
    log_success "Managed identity enabled for $WEB_APP_NAME"
fi

if [ -z "$MAILBOX_IDENTITY" ] || [ -z "$QUEUEDB_IDENTITY" ] || [ -z "$WEBAPP_IDENTITY" ]; then
    log_error "Failed to retrieve managed identity principal IDs. Cannot assign RBAC."
    exit 1
fi

NEW_ASSIGNMENTS=0

# Key Vault access (RBAC)
KEY_VAULT_ID=$(az keyvault show --name "$KEY_VAULT_NAME" --resource-group "$RESOURCE_GROUP_NAME" --query id -o tsv 2>/dev/null || echo "")
log_info "Key Vault Secrets User role for function apps and web app"
for identity in "$MAILBOX_IDENTITY" "$QUEUEDB_IDENTITY" "$WEBAPP_IDENTITY"; do
    ensure_role_assignment "$identity" "Key Vault Secrets User" "$KEY_VAULT_ID" || NEW_ASSIGNMENTS=$((NEW_ASSIGNMENTS + 1))
done

# Service Bus access
SERVICE_BUS_ID=$(az servicebus namespace show --name "$SERVICE_BUS_NAMESPACE" --resource-group "$RESOURCE_GROUP_NAME" --query id -o tsv 2>/dev/null || echo "")

log_info "Service Bus roles for function apps"
ensure_role_assignment "$MAILBOX_IDENTITY" "Azure Service Bus Data Owner" "$SERVICE_BUS_ID" || NEW_ASSIGNMENTS=$((NEW_ASSIGNMENTS + 1))
ensure_role_assignment "$QUEUEDB_IDENTITY" "Azure Service Bus Data Receiver" "$SERVICE_BUS_ID" || NEW_ASSIGNMENTS=$((NEW_ASSIGNMENTS + 1))

# Storage account access (managed identity for AzureWebJobsStorage)
STORAGE_ACCOUNT_ID=$(az storage account show --name "$STORAGE_ACCOUNT_NAME" --resource-group "$RESOURCE_GROUP_NAME" --query id -o tsv 2>/dev/null || echo "")

log_info "Storage account roles for function apps"
for identity in "$MAILBOX_IDENTITY" "$QUEUEDB_IDENTITY"; do
    for role in "Storage Blob Data Owner" "Storage Account Contributor" "Storage Queue Data Contributor" "Storage Table Data Contributor"; do
        ensure_role_assignment "$identity" "$role" "$STORAGE_ACCOUNT_ID" || NEW_ASSIGNMENTS=$((NEW_ASSIGNMENTS + 1))
    done
done

# Cosmos DB access (data plane RBAC - Built-in Data Contributor)
COSMOS_DB_ACCOUNT_ID=$(az cosmosdb show --name "$COSMOS_DB_ACCOUNT_NAME" --resource-group "$RESOURCE_GROUP_NAME" --query id -o tsv 2>/dev/null || echo "")
COSMOS_DATA_CONTRIBUTOR_ROLE_ID="00000000-0000-0000-0000-000000000002"

log_info "Cosmos DB Data Contributor role for function apps and web app"
for identity in "$MAILBOX_IDENTITY" "$QUEUEDB_IDENTITY" "$WEBAPP_IDENTITY"; do
    ensure_cosmos_role_assignment "$COSMOS_DB_ACCOUNT_NAME" "$RESOURCE_GROUP_NAME" "$COSMOS_DATA_CONTRIBUTOR_ROLE_ID" "$identity" "$COSMOS_DB_ACCOUNT_ID" || NEW_ASSIGNMENTS=$((NEW_ASSIGNMENTS + 1))
done

# Content Understanding access (Cognitive Services User)
CONTENT_UNDERSTANDING_ID=$(az cognitiveservices account show --name "$CONTENT_UNDERSTANDING_NAME" --resource-group "$RESOURCE_GROUP_NAME" --query id -o tsv 2>/dev/null || echo "")

log_info "Cognitive Services User role for function apps and web app"
for identity in "$MAILBOX_IDENTITY" "$QUEUEDB_IDENTITY" "$WEBAPP_IDENTITY"; do
    ensure_role_assignment "$identity" "Cognitive Services User" "$CONTENT_UNDERSTANDING_ID" || NEW_ASSIGNMENTS=$((NEW_ASSIGNMENTS + 1))
done

# AI Foundry access (Cognitive Services OpenAI User)
AI_FOUNDRY_ID=$(az cognitiveservices account show --name "$AI_FOUNDRY_NAME" --resource-group "$RESOURCE_GROUP_NAME" --query id -o tsv 2>/dev/null || echo "")

log_info "Cognitive Services OpenAI User role for function apps and web app"
for identity in "$MAILBOX_IDENTITY" "$QUEUEDB_IDENTITY" "$WEBAPP_IDENTITY"; do
    ensure_role_assignment "$identity" "Cognitive Services OpenAI User" "$AI_FOUNDRY_ID" || NEW_ASSIGNMENTS=$((NEW_ASSIGNMENTS + 1))
done

if [ "$NEW_ASSIGNMENTS" -gt 0 ]; then
    log_success "$NEW_ASSIGNMENTS new RBAC assignment(s) created"
else
    log_success "All RBAC assignments already in place"
fi

# =============================================================================
# Wait for identity propagation (only if new assignments were made)
# =============================================================================
if [ "$NEW_ASSIGNMENTS" -gt 0 ]; then
    echo ""
    log_info "Waiting 30 seconds for RBAC propagation..."
    sleep 30
else
    log_success "Skipping propagation wait (no new assignments)"
fi

# =============================================================================
# Store Secrets in Key Vault
# =============================================================================
log_info "Storing configuration secrets in Key Vault..."

# Validate Key Vault RBAC access before writing secrets
log_info "Validating Key Vault write access..."

# Recover or purge any soft-deleted test secret from a previous run
az keyvault secret recover --vault-name "$KEY_VAULT_NAME" --name "deployment-test" 2>/dev/null || \
    az keyvault secret purge --vault-name "$KEY_VAULT_NAME" --name "deployment-test" 2>/dev/null || true

KV_READY=false
for i in $(seq 1 12); do
    kv_stderr=$(az keyvault secret set --vault-name "$KEY_VAULT_NAME" --name "deployment-test" --value "ok" --output none 2>&1) && {
        KV_READY=true
        log_success "Key Vault write access confirmed"
        break
    }
    log_info "Key Vault not ready yet (attempt $i/12). Waiting 10 seconds..."
    [ -n "$kv_stderr" ] && echo "  Reason: $kv_stderr"
    sleep 10
done
if [ "$KV_READY" = false ]; then
    log_error "Cannot write to Key Vault $KEY_VAULT_NAME after 12 attempts."
    log_error "Ensure your account has 'Key Vault Administrator' or 'Key Vault Secrets Officer' role on the vault."
    log_error "Current user: $CURRENT_USER_ID"
    log_error "Key Vault ID: $KEY_VAULT_ID"
    log_error "You can assign it manually with:"
    echo "  az role assignment create --assignee $CURRENT_USER_ID --role 'Key Vault Administrator' --scope $KEY_VAULT_ID"
    exit 1
fi

SB_CONN=$(az servicebus namespace authorization-rule keys list \
    --namespace-name "$SERVICE_BUS_NAMESPACE" --resource-group "$RESOURCE_GROUP_NAME" \
    --name RootManageSharedAccessKey --query primaryConnectionString -o tsv 2>/dev/null || echo "")
KV_URL="https://${KEY_VAULT_NAME}.vault.azure.net/"
SB_URL="https://${SERVICE_BUS_NAMESPACE}.servicebus.windows.net/"
COSMOS_DB_ENDPOINT=$(az cosmosdb show --name "$COSMOS_DB_ACCOUNT_NAME" --resource-group "$RESOURCE_GROUP_NAME" --query documentEndpoint -o tsv 2>/dev/null || echo "")
CONTENT_UNDERSTANDING_ENDPOINT=$(az cognitiveservices account show --name "$CONTENT_UNDERSTANDING_NAME" --resource-group "$RESOURCE_GROUP_NAME" --query properties.endpoint -o tsv 2>/dev/null || echo "")
AI_FOUNDRY_ENDPOINT=$(az cognitiveservices account show --name "$AI_FOUNDRY_NAME" --resource-group "$RESOURCE_GROUP_NAME" --query properties.endpoint -o tsv 2>/dev/null || echo "")

declare -A KV_SECRETS=(
    ["ServiceBusConnectionString"]="$SB_CONN"
    ["KeyVaultUrl"]="$KV_URL"
    ["ServiceBusUrl"]="$SB_URL"
    ["ServiceBusTopicName"]="$SERVICE_BUS_TOPIC_NAME"
    ["ServiceBusSubscriptionName"]="$SERVICE_BUS_SUB_NAME"
    ["GraphClientId"]="$GRAPH_CLIENT_ID"
    ["GraphClientSecret"]="$GRAPH_CLIENT_SECRET"
    ["GraphTenantId"]="$TENANT_ID"
    ["MailboxFunctionAppName"]="$FUNC_MAILBOX_NAME"
    ["QueueDbFunctionAppName"]="$FUNC_QUEUEDB_NAME"
    ["CosmosDbEndpoint"]="$COSMOS_DB_ENDPOINT"
    ["CosmosDbDatabaseName"]="$COSMOS_DB_DATABASE_NAME"
    ["CosmosDbContainerName"]="$COSMOS_DB_CONTAINER_NAME"
    ["ContentUnderstandingEndpoint"]="$CONTENT_UNDERSTANDING_ENDPOINT"
    ["AiFoundryEndpoint"]="$AI_FOUNDRY_ENDPOINT"
    ["AiFoundryDeploymentName"]="$AI_FOUNDRY_DEPLOYMENT_NAME"
    ["AiFoundryModelName"]="$AI_FOUNDRY_MODEL_NAME"
    ["AiFoundryApiVersion"]="$AI_FOUNDRY_API_VERSION"
)

SECRET_ERRORS=0
for key in "${!KV_SECRETS[@]}"; do
    if [ -z "${KV_SECRETS[$key]}" ]; then
        log_warning "Skipping Key Vault secret '$key' - value is empty"
        continue
    fi
    if ! az keyvault secret set --vault-name "$KEY_VAULT_NAME" --name "$key" --value "${KV_SECRETS[$key]}" --output none 2>&1; then
        log_error "Failed to set Key Vault secret: $key"
        DEPLOYMENT_ERRORS+=("Key Vault secret: $key")
        SECRET_ERRORS=$((SECRET_ERRORS + 1))
    fi
done

if [ "$SECRET_ERRORS" -eq 0 ]; then
    log_success "Secrets stored in Key Vault"
else
    log_warning "Some secrets failed to store in Key Vault"
fi

# =============================================================================
# Configure Function App Settings
# =============================================================================
log_info "Configuring Function App settings..."

log_info "Switching function apps to identity-based storage access"
az functionapp config appsettings delete --name "$FUNC_MAILBOX_NAME" --resource-group "$RESOURCE_GROUP_NAME" \
    --setting-names AzureWebJobsStorage --output none 2>/dev/null || true
az functionapp config appsettings delete --name "$FUNC_QUEUEDB_NAME" --resource-group "$RESOURCE_GROUP_NAME" \
    --setting-names AzureWebJobsStorage --output none 2>/dev/null || true

if ! set_function_app_settings "$FUNC_MAILBOX_NAME" "$RESOURCE_GROUP_NAME" \
    "AzureWebJobsStorage__accountName=$STORAGE_ACCOUNT_NAME" \
    "AZURE_KEY_VAULT_URL=$KV_URL" \
    "AZURE_SERVICE_BUS_URL=$SB_URL" \
    "AZURE_SERVICE_BUS_TOPIC=$SERVICE_BUS_TOPIC_NAME" \
    "PAST_EMAIL_READ_INTERVAL_SECONDS=3600" \
    "AZURE_CLIENT_ID=@Microsoft.KeyVault(VaultName=${KEY_VAULT_NAME};SecretName=GraphClientId)" \
    "AZURE_CLIENT_SECRET=@Microsoft.KeyVault(VaultName=${KEY_VAULT_NAME};SecretName=GraphClientSecret)" \
    "AZURE_TENANT_ID=@Microsoft.KeyVault(VaultName=${KEY_VAULT_NAME};SecretName=GraphTenantId)" \
    "AZURE_COSMOS_DB_ENDPOINT=$COSMOS_DB_ENDPOINT" \
    "AZURE_COSMOS_DB_DATABASE=$COSMOS_DB_DATABASE_NAME" \
    "AZURE_COSMOS_DB_CONTAINER=$COSMOS_DB_CONTAINER_NAME" \
    "AZURE_CONTENT_UNDERSTANDING_ENDPOINT=$CONTENT_UNDERSTANDING_ENDPOINT" \
    "AZURE_OPENAI_ENDPOINT=$AI_FOUNDRY_ENDPOINT" \
    "AZURE_OPENAI_DEPLOYMENT_NAME=$AI_FOUNDRY_DEPLOYMENT_NAME" \
    "AZURE_OPENAI_MODEL_NAME=$AI_FOUNDRY_MODEL_NAME" \
    "AZURE_OPENAI_API_VERSION=$AI_FOUNDRY_API_VERSION"; then
    log_error "Failed to configure settings for $FUNC_MAILBOX_NAME"
    DEPLOYMENT_ERRORS+=("Function app settings: $FUNC_MAILBOX_NAME")
fi

if ! set_function_app_settings "$FUNC_QUEUEDB_NAME" "$RESOURCE_GROUP_NAME" \
    "AzureWebJobsStorage__accountName=$STORAGE_ACCOUNT_NAME" \
    "AZURE_KEY_VAULT_URL=$KV_URL" \
    "AZURE_SERVICE_BUS_URL=$SB_URL" \
    "AZURE_SERVICE_BUS_TOPIC=$SERVICE_BUS_TOPIC_NAME" \
    "AZURE_SERVICE_BUS_SUBSCRIPTION=$SERVICE_BUS_SUB_NAME" \
    "AZURE_COSMOS_DB_ENDPOINT=$COSMOS_DB_ENDPOINT" \
    "AZURE_COSMOS_DB_DATABASE=$COSMOS_DB_DATABASE_NAME" \
    "AZURE_COSMOS_DB_CONTAINER=$COSMOS_DB_CONTAINER_NAME" \
    "AZURE_CONTENT_UNDERSTANDING_ENDPOINT=$CONTENT_UNDERSTANDING_ENDPOINT" \
    "AZURE_OPENAI_ENDPOINT=$AI_FOUNDRY_ENDPOINT" \
    "AZURE_OPENAI_DEPLOYMENT_NAME=$AI_FOUNDRY_DEPLOYMENT_NAME" \
    "AZURE_OPENAI_MODEL_NAME=$AI_FOUNDRY_MODEL_NAME" \
    "AZURE_OPENAI_API_VERSION=$AI_FOUNDRY_API_VERSION"; then
    log_error "Failed to configure settings for $FUNC_QUEUEDB_NAME"
    DEPLOYMENT_ERRORS+=("Function app settings: $FUNC_QUEUEDB_NAME")
fi

log_success "Function App settings configured"

# =============================================================================
# Configure Web App Settings
# =============================================================================
log_info "Configuring Web App settings..."

WEBAPP_RESOURCE_ID=$(az webapp show --name "$WEB_APP_NAME" --resource-group "$RESOURCE_GROUP_NAME" --query id -o tsv 2>/dev/null || echo "")

WEBAPP_SETTINGS_TEMP=$(mktemp)
cat > "$WEBAPP_SETTINGS_TEMP" <<EOFWEBAPP
{
  "properties": {
    "AZURE_KEY_VAULT_URL": "$KV_URL",
    "AZURE_COSMOS_DB_ENDPOINT": "$COSMOS_DB_ENDPOINT",
    "AZURE_COSMOS_DB_DATABASE": "$COSMOS_DB_DATABASE_NAME",
    "AZURE_COSMOS_DB_CONTAINER": "$COSMOS_DB_CONTAINER_NAME",
    "AZURE_SERVICE_BUS_URL": "$SB_URL",
    "AZURE_SERVICE_BUS_TOPIC": "$SERVICE_BUS_TOPIC_NAME",
    "AZURE_CONTENT_UNDERSTANDING_ENDPOINT": "$CONTENT_UNDERSTANDING_ENDPOINT",
    "AZURE_OPENAI_ENDPOINT": "$AI_FOUNDRY_ENDPOINT",
    "AZURE_OPENAI_DEPLOYMENT_NAME": "$AI_FOUNDRY_DEPLOYMENT_NAME",
    "AZURE_OPENAI_MODEL_NAME": "$AI_FOUNDRY_MODEL_NAME",
    "AZURE_OPENAI_API_VERSION": "$AI_FOUNDRY_API_VERSION"
  }
}
EOFWEBAPP

if az rest --method PUT \
    --url "https://management.azure.com${WEBAPP_RESOURCE_ID}/config/appsettings?api-version=2023-01-01" \
    --body "@${WEBAPP_SETTINGS_TEMP}" \
    --output none 2>/dev/null; then
    log_success "Web App settings configured"
else
    log_error "Failed to configure settings for web app $WEB_APP_NAME"
    DEPLOYMENT_ERRORS+=("Web app settings: $WEB_APP_NAME")
fi
rm -f "$WEBAPP_SETTINGS_TEMP"

# =============================================================================
# SUMMARY
# =============================================================================
echo ""
if [ ${#DEPLOYMENT_ERRORS[@]} -gt 0 ]; then
    echo -e "\033[0;31m[FAILED] ==========================================\033[0m"
    echo -e "\033[0;31m[FAILED] Infrastructure deployment completed with ${#DEPLOYMENT_ERRORS[@]} error(s)!\033[0m"
    echo -e "\033[0;31m[FAILED] ==========================================\033[0m"
    echo ""
    echo -e "\033[0;31m  Failed operations:\033[0m"
    for err in "${DEPLOYMENT_ERRORS[@]}"; do
        echo -e "\033[0;31m    - $err\033[0m"
    done
    echo ""
    echo "  Resource Group       : $RESOURCE_GROUP_NAME"
    echo "  Key Vault            : $KEY_VAULT_NAME"
    echo "  Storage Account      : $STORAGE_ACCOUNT_NAME"
    echo "  Service Bus NS       : $SERVICE_BUS_NAMESPACE"
    echo "  Service Bus Topic    : $SERVICE_BUS_TOPIC_NAME"
    echo "  Cosmos DB Account    : $COSMOS_DB_ACCOUNT_NAME"
    echo "  Cosmos DB Database   : $COSMOS_DB_DATABASE_NAME"
    echo "  Content Understanding: $CONTENT_UNDERSTANDING_NAME"
    echo "  AI Foundry           : $AI_FOUNDRY_NAME"
    echo "  AI Foundry Model     : $AI_FOUNDRY_DEPLOYMENT_NAME"
    echo "  App Service Plan     : $APP_SERVICE_PLAN_NAME"
    echo "  Web App              : $WEB_APP_NAME"
    echo "  Function (Mailbox)   : $FUNC_MAILBOX_NAME"
    echo "  Function (Queue-DB)  : $FUNC_QUEUEDB_NAME"
    echo "  Graph API App ID     : $GRAPH_CLIENT_ID"
    echo "  App Insights         : $APP_INSIGHTS_NAME"
    echo -e "\033[0;31m[FAILED] ==========================================\033[0m"
    echo ""
    log_info "Fix the errors above and re-run the script. It is idempotent and will skip already-created resources."
    exit 1
else
    echo -e "\033[0;32m[SUCCESS] ==========================================\033[0m"
    echo -e "\033[0;32m[SUCCESS] Infrastructure deployment completed!\033[0m"
    echo -e "\033[0;32m[SUCCESS] ==========================================\033[0m"
    echo "  Resource Group       : $RESOURCE_GROUP_NAME"
    echo "  Key Vault            : $KEY_VAULT_NAME"
    echo "  Storage Account      : $STORAGE_ACCOUNT_NAME"
    echo "  Service Bus NS       : $SERVICE_BUS_NAMESPACE"
    echo "  Service Bus Topic    : $SERVICE_BUS_TOPIC_NAME"
    echo "  Cosmos DB Account    : $COSMOS_DB_ACCOUNT_NAME"
    echo "  Cosmos DB Database   : $COSMOS_DB_DATABASE_NAME"
    echo "  Content Understanding: $CONTENT_UNDERSTANDING_NAME"
    echo "  AI Foundry           : $AI_FOUNDRY_NAME"
    echo "  AI Foundry Model     : $AI_FOUNDRY_DEPLOYMENT_NAME"
    echo "  App Service Plan     : $APP_SERVICE_PLAN_NAME"
    echo "  Web App              : $WEB_APP_NAME"
    echo "  Function (Mailbox)   : $FUNC_MAILBOX_NAME"
    echo "  Function (Queue-DB)  : $FUNC_QUEUEDB_NAME"
    echo "  Graph API App ID     : $GRAPH_CLIENT_ID"
    echo "  App Insights         : $APP_INSIGHTS_NAME"
    echo -e "\033[0;32m[SUCCESS] ==========================================\033[0m"
    echo ""
    log_info "Next Steps:"
    echo "  1. Grant Graph API admin consent:  ./grant-graph-consent.sh $SUFFIX"
    echo "  2. Deploy your function code to the created function apps"
    echo "  3. Deploy your Spring Boot JAR/WAR to the web app: $WEB_APP_NAME"
    echo "  4. Test the deployment with sample data"
fi

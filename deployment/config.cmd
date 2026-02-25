@echo off
REM =============================================================================
REM Configuration for extract-insight-action Infrastructure Deployment (Windows)
REM
REM Edit the values below, then run:
REM   config.cmd
REM   deploy-infrastructure.cmd
REM =============================================================================

REM =============================================================================
REM REQUIRED CONFIGURATION
REM =============================================================================

REM Project name - will be used as prefix for all resource names
set "PROJECT_NAME=eia"

REM Environment name - dev, staging, prod, etc.
set "ENVIRONMENT=dev"

REM Azure region where resources will be deployed
REM Common options: eastus, westus2, canadacentral, uksouth, australiaeast
set "LOCATION=centralus"

REM Your Azure subscription ID (leave empty to use current subscription)
REM Get it with: az account show --query id -o tsv
set "SUBSCRIPTION_ID="

REM =============================================================================
REM OPTIONAL CONFIGURATION (uncomment and modify if needed)
REM =============================================================================

REM Custom resource names (if you don't want to use default naming convention)
REM set "RESOURCE_GROUP_NAME=rg-my-custom-name"
REM set "KEY_VAULT_NAME=kv-my-custom-name"
REM set "SERVICE_BUS_NAMESPACE=sb-my-custom-name"
REM set "STORAGE_ACCOUNT_NAME=stmycustomname"

REM Service Bus configuration
REM set "SERVICE_BUS_TOPIC_NAME=email-processing"
REM set "SERVICE_BUS_SUBSCRIPTION_NAME=email-processor"

REM Microsoft Graph API app registration
REM set "GRAPH_APP_NAME=my-custom-graph-app"
REM If you have existing Graph API credentials, set them here:
REM set "GRAPH_CLIENT_ID=your-existing-client-id"
REM set "GRAPH_CLIENT_SECRET=your-existing-client-secret"

REM Function app names
REM set "FUNCTION_APP_MAILBOX_NAME=func-mailbox-custom-name"
REM set "FUNCTION_APP_QUEUE_DB_NAME=func-queuedb-custom-name"

REM Application Insights
REM set "APP_INSIGHTS_NAME=ai-custom-name"

REM App Service (Spring Boot Web App)
REM set "APP_SERVICE_PLAN_NAME=plan-custom-name"
REM set "WEB_APP_NAME=app-custom-name"

REM Azure Content Understanding
REM set "CONTENT_UNDERSTANDING_NAME=cu-custom-name"

REM Azure AI Foundry (OpenAI model hosting)
REM set "AI_FOUNDRY_NAME=oai-custom-name"

REM =============================================================================
REM NOTES
REM =============================================================================
REM
REM 1. Resource names will be automatically generated using the pattern:
REM    {resource-type}-{PROJECT_NAME}-{ENVIRONMENT}
REM    Example: rg-eia-dev
REM
REM 2. Globally unique resources (Storage Account, Key Vault) will have
REM    random suffixes added to avoid naming conflicts
REM
REM 3. Storage account names are limited to 24 characters and cannot contain
REM    hyphens, so PROJECT_NAME hyphens will be removed
REM
REM 4. You can override any auto-generated name by setting the specific
REM    variable (uncomment the lines above)
REM

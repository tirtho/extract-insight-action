#Requires -Version 5.1
<#
.SYNOPSIS
    Azure Infrastructure Deployment Script for extract-insight-action
.DESCRIPTION
    Creates all necessary Azure resources. Idempotent - can be run multiple times safely.
.PARAMETER Suffix
    Required. A short suffix (e.g. 999) appended to globally-unique resource names.
.USAGE
    .\deploy-infrastructure.ps1 -Suffix 999
#>
param(
    [Parameter(Mandatory=$true, HelpMessage="Suffix for globally-unique resource names (e.g. 999)")]
    [ValidateNotNullOrEmpty()]
    [string]$Suffix
)

$ErrorActionPreference = "Stop"

# =============================================================================
# CONFIGURATION
# =============================================================================
$ProjectName   = if ($env:PROJECT_NAME)   { $env:PROJECT_NAME }   else { "eia" }
$Environment   = if ($env:ENVIRONMENT)    { $env:ENVIRONMENT }    else { "dev" }
$Location      = if ($env:LOCATION)       { $env:LOCATION }       else { "centralus" }

# Get subscription/tenant from Azure CLI
$SubscriptionId = if ($env:SUBSCRIPTION_ID) { $env:SUBSCRIPTION_ID } else { (az account show --query id -o tsv) }
$TenantId       = if ($env:TENANT_ID)       { $env:TENANT_ID }       else { (az account show --query tenantId -o tsv) }

# Resource names (Suffix is a required command-line argument)
$ResourceGroupName    = if ($env:RESOURCE_GROUP_NAME)       { $env:RESOURCE_GROUP_NAME }       else { "rg-$ProjectName-$Environment-$Suffix" }
$KeyVaultName         = if ($env:KEY_VAULT_NAME)            { $env:KEY_VAULT_NAME }            else { "kv-$ProjectName-$Environment-$Suffix" }
$ServiceBusNamespace  = if ($env:SERVICE_BUS_NAMESPACE)     { $env:SERVICE_BUS_NAMESPACE }     else { "sb-$ProjectName-$Environment-$Suffix" }
$ProjClean            = $ProjectName -replace '-',''
$StorageAccountName   = if ($env:STORAGE_ACCOUNT_NAME)      { $env:STORAGE_ACCOUNT_NAME }      else { "st$ProjClean$Environment$Suffix" }
$FuncMailboxName      = if ($env:FUNCTION_APP_MAILBOX_NAME) { $env:FUNCTION_APP_MAILBOX_NAME } else { "func-mailbox-$ProjectName-$Environment-$Suffix" }
$FuncQueueDbName      = if ($env:FUNCTION_APP_QUEUE_DB_NAME){ $env:FUNCTION_APP_QUEUE_DB_NAME }else { "func-queuedb-$ProjectName-$Environment-$Suffix" }
$ServiceBusTopicName  = if ($env:SERVICE_BUS_TOPIC_NAME)    { $env:SERVICE_BUS_TOPIC_NAME }    else { "email-processing" }
$ServiceBusSubName    = if ($env:SERVICE_BUS_SUBSCRIPTION_NAME) { $env:SERVICE_BUS_SUBSCRIPTION_NAME } else { "email-processor" }
$GraphAppName         = if ($env:GRAPH_APP_NAME)            { $env:GRAPH_APP_NAME }            else { "$ProjectName-graph-api-$Environment" }
$GraphClientId        = $env:GRAPH_CLIENT_ID
$GraphClientSecret    = $env:GRAPH_CLIENT_SECRET
$AppInsightsName      = if ($env:APP_INSIGHTS_NAME)         { $env:APP_INSIGHTS_NAME }         else { "ai-$ProjectName-$Environment" }
$CosmosDbAccountName  = if ($env:COSMOS_DB_ACCOUNT_NAME)    { $env:COSMOS_DB_ACCOUNT_NAME }    else { "cosmos-$ProjectName-$Environment-$Suffix" }
$CosmosDbDatabaseName = "DocAIDatabase"
$CosmosDbContainerName = "EmailExtracts"
$AppServicePlanName   = if ($env:APP_SERVICE_PLAN_NAME)     { $env:APP_SERVICE_PLAN_NAME }     else { "plan-$ProjectName-$Environment" }
$WebAppName           = if ($env:WEB_APP_NAME)              { $env:WEB_APP_NAME }              else { "app-$ProjectName-$Environment-$Suffix" }
$ContentUnderstandingName = if ($env:CONTENT_UNDERSTANDING_NAME) { $env:CONTENT_UNDERSTANDING_NAME } else { "cu-$ProjectName-$Environment-$Suffix" }
$AiFoundryName            = if ($env:AI_FOUNDRY_NAME)            { $env:AI_FOUNDRY_NAME }            else { "oai-$ProjectName-$Environment-$Suffix" }
$AiFoundryDeploymentName  = "gpt-5.1-chat"
$AiFoundryModelName       = "gpt-5.1-chat"
$AiFoundryModelVersion    = "2025-11-13"
$AiFoundryApiVersion      = "2024-12-01-preview"
$AiFoundrySkuName         = "GlobalStandard"
$AiFoundrySkuCapacity     = "50"

# Content Understanding requires a supported completion model (separate from the main LLM deployment).
# Supported: gpt-4o, gpt-4o-mini, gpt-4.1, gpt-4.1-mini, gpt-4.1-nano, gpt-5.2
$CuCompletionDeploymentName = "gpt-4.1"
$CuCompletionModelName      = "gpt-4.1"
$CuCompletionModelVersion   = "2025-04-14"
$CuCompletionSkuCapacity    = "50"
$CuEmbeddingDeploymentName  = "text-embedding-3-large"
$CuEmbeddingModelName       = "text-embedding-3-large"
$CuEmbeddingModelVersion    = "1"
$CuEmbeddingSkuCapacity     = "50"

# Verify JAVA_HOME points to Java 21
if (-not $env:JAVA_HOME) {
    Write-Host "[ERROR] JAVA_HOME is not set. Please set JAVA_HOME to a JDK 21 installation." -ForegroundColor Red
    exit 1
}
$JavaVersionFull = cmd /c "`"$env:JAVA_HOME\bin\java`" -version 2>&1" | Select-Object -First 1
if ($JavaVersionFull -match '"(\d+)') {
    $JavaMajorVersion = $Matches[1]
} else {
    Write-Host "[ERROR] Could not detect Java version from JAVA_HOME ($env:JAVA_HOME)" -ForegroundColor Red
    exit 1
}
if ($JavaMajorVersion -ne '21') {
    Write-Host "[ERROR] This project requires Java 21 but JAVA_HOME points to Java $JavaMajorVersion." -ForegroundColor Red
    Write-Host "        JAVA_HOME: $env:JAVA_HOME" -ForegroundColor Red
    Write-Host "        Please install JDK 21 and update JAVA_HOME." -ForegroundColor Red
    exit 1
}
Write-Host "[INFO] Java 21 confirmed from JAVA_HOME" -ForegroundColor Cyan

# =============================================================================
# HELPER FUNCTION
# =============================================================================
$script:DeploymentErrors = [System.Collections.Generic.List[string]]::new()

function Invoke-AzCli {
    param([string]$Description, [string[]]$Arguments)
    Write-Host "[INFO] $Description" -ForegroundColor Cyan
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    $output = & az @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $prevEAP
    if ($exitCode -ne 0) {
        $errorText = ($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }) -join "`n"
        Write-Host "[ERROR] $Description failed (exit code $exitCode)" -ForegroundColor Red
        if ($errorText) { Write-Host "  $errorText" -ForegroundColor Red }
        $script:DeploymentErrors.Add($Description)
        return $null
    }
    $stdout = ($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n"
    return $stdout
}

function Invoke-AzCliSilent {
    param([string[]]$Arguments)
    $prevPref = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    $allOutput = & az @Arguments 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prevPref
    $stdout = ($allOutput | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n"
    $stderr = ($allOutput | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }) -join "`n"
    return @{ ExitCode = $code; Output = $stdout.Trim(); Error = $stderr.Trim() }
}

function Test-AzResource {
    param([string]$Description, [string[]]$Arguments)
    $r = Invoke-AzCliSilent -Arguments $Arguments
    if ($r.ExitCode -eq 0 -and $r.Output) { return $true }
    return $false
}

# Returns $true if the role assignment was already in place
function Ensure-RoleAssignment {
    param([string]$Assignee, [string]$Role, [string]$Scope)
    if (-not $Scope) {
        Write-Host "[ERROR] Ensure-RoleAssignment: Scope is empty for role '$Role' on assignee '$Assignee'" -ForegroundColor Red
        $script:DeploymentErrors.Add("RBAC: '$Role' for '$Assignee' - empty scope")
        return $false
    }
    $existing = Invoke-AzCliSilent -Arguments @('role','assignment','list','--assignee',$Assignee,'--role',$Role,'--scope',$Scope,'--query','[0].id','-o','tsv')
    if ($existing.ExitCode -eq 0 -and $existing.Output) {
        return $true  # already exists
    }
    $result = Invoke-AzCliSilent -Arguments @('role','assignment','create','--assignee',$Assignee,'--role',$Role,'--scope',$Scope,'--output','none')
    if ($result.ExitCode -ne 0) {
        Write-Host "[ERROR] Failed to assign role '$Role' to '$Assignee' on scope '$Scope'" -ForegroundColor Red
        if ($result.Error) { Write-Host "  $($result.Error)" -ForegroundColor Red }
        $script:DeploymentErrors.Add("RBAC: '$Role' for '$Assignee'")
    }
    return $false  # newly created (or failed - caller increments counter; errors logged above)
}

# Returns $true if the Cosmos DB role assignment was already in place
function Ensure-CosmosRoleAssignment {
    param([string]$AccountName, [string]$ResourceGroup, [string]$RoleDefinitionId, [string]$PrincipalId, [string]$Scope)
    $existing = Invoke-AzCliSilent -Arguments @('cosmosdb','sql','role','assignment','list',
        '--account-name',$AccountName,'--resource-group',$ResourceGroup,
        '--query',"[?principalId=='$PrincipalId'] | [0].id",'--output','tsv')
    if ($existing.ExitCode -eq 0 -and $existing.Output) {
        return $true  # already exists
    }
    Invoke-AzCliSilent -Arguments @('cosmosdb','sql','role','assignment','create',
        '--account-name',$AccountName,'--resource-group',$ResourceGroup,
        '--role-definition-id',$RoleDefinitionId,
        '--principal-id',$PrincipalId,'--scope',$Scope,
        '--output','none') | Out-Null
    return $false  # newly created
}

function Set-FunctionAppSettings {
    param([string]$FunctionAppName, [string]$ResourceGroup, [hashtable]$Settings)
    # Uses az rest with a temp JSON file to avoid CMD special-character issues on Windows
    $funcIdResult = Invoke-AzCliSilent -Arguments @('functionapp','show','--name',$FunctionAppName,'--resource-group',$ResourceGroup,'--query','id','-o','tsv')
    if ($funcIdResult.ExitCode -ne 0 -or -not $funcIdResult.Output) {
        return @{ ExitCode = 1; Output = "Function app $FunctionAppName not found" }
    }
    $funcId = $funcIdResult.Output

    # Get existing settings so we merge rather than replace
    $existingResult = Invoke-AzCliSilent -Arguments @('rest','--method','POST','--url',"$funcId/config/appsettings/list?api-version=2023-01-01")
    $merged = [ordered]@{}
    if ($existingResult.ExitCode -eq 0 -and $existingResult.Output) {
        $existing = $existingResult.Output | ConvertFrom-Json
        if ($existing.properties) {
            $existing.properties.PSObject.Properties | ForEach-Object { $merged[$_.Name] = $_.Value }
        }
    }

    # Apply new/updated settings
    foreach ($kv in $Settings.GetEnumerator()) {
        $merged[$kv.Key] = $kv.Value
    }

    # Write body to temp file to bypass CMD argument escaping entirely
    $body = @{ properties = $merged } | ConvertTo-Json -Depth 5 -Compress
    $tempFile = [System.IO.Path]::GetTempFileName()
    [System.IO.File]::WriteAllText($tempFile, $body, [System.Text.Encoding]::UTF8)

    $r = Invoke-AzCliSilent -Arguments @('rest','--method','PUT','--url',"$funcId/config/appsettings?api-version=2023-01-01",'--body',"@$tempFile")
    Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
    return $r
}

# =============================================================================
# LOCATION AVAILABILITY CHECK
# =============================================================================
$script:ServiceLocationCache = @{}

function Get-ServiceLocation {
    param(
        [Parameter(Mandatory=$true)][string]$ServiceName,
        [Parameter(Mandatory=$true)][string]$DefaultLocation
    )

    # Return cached result if already resolved
    if ($script:ServiceLocationCache.ContainsKey($ServiceName)) {
        return $script:ServiceLocationCache[$ServiceName]
    }

    $csvPath = Join-Path $PSScriptRoot "supported-service-locations.csv"
    if (-not (Test-Path $csvPath)) {
        $script:ServiceLocationCache[$ServiceName] = $DefaultLocation
        return $DefaultLocation
    }

    $lines = Get-Content $csvPath
    foreach ($line in $lines) {
        $line = $line.Trim()
        if (-not $line) { continue }
        $parts = $line -split ','
        if ($parts[0].Trim().ToLower() -eq $ServiceName.ToLower()) {
            $supportedLocations = $parts[1..($parts.Length-1)] | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ -ne '' }
            if ($supportedLocations -contains $DefaultLocation.ToLower()) {
                $script:ServiceLocationCache[$ServiceName] = $DefaultLocation
                return $DefaultLocation
            }
            # Location not supported - prompt user to choose from supported list
            Write-Host "" 
            Write-Host "[WARNING] Location '$DefaultLocation' is not supported for service '$ServiceName'." -ForegroundColor Yellow
            Write-Host "[INFO] Supported locations: $($supportedLocations -join ', ')" -ForegroundColor Cyan
            do {
                $userInput = Read-Host "Enter a supported location for '$ServiceName'"
                $userInput = $userInput.Trim().ToLower()
                if ($userInput -eq '' -or $supportedLocations -notcontains $userInput) {
                    Write-Host "[ERROR] '$userInput' is not in the supported list. Please try again." -ForegroundColor Red
                }
            } while ($userInput -eq '' -or $supportedLocations -notcontains $userInput)

            $script:ServiceLocationCache[$ServiceName] = $userInput
            Write-Host "[INFO] Using location '$userInput' for $ServiceName" -ForegroundColor Cyan
            return $userInput
        }
    }

    # No entry in CSV - assume service is available everywhere
    $script:ServiceLocationCache[$ServiceName] = $DefaultLocation
    return $DefaultLocation
}

# =============================================================================
# BANNER
# =============================================================================
Write-Host ""
Write-Host "[INFO] ============================================================" -ForegroundColor Cyan
Write-Host "[INFO] Azure Infrastructure Deployment for $ProjectName"            -ForegroundColor Cyan
Write-Host "[INFO] Environment : $Environment"                                   -ForegroundColor Cyan
Write-Host "[INFO] Location    : $Location"                                      -ForegroundColor Cyan
Write-Host "[INFO] RG          : $ResourceGroupName"                             -ForegroundColor Cyan
Write-Host "[INFO] ============================================================" -ForegroundColor Cyan
Write-Host ""

# =============================================================================
# PREREQUISITES
# =============================================================================
Write-Host "[INFO] Checking prerequisites..." -ForegroundColor Cyan

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Host "[ERROR] Azure CLI is not installed." -ForegroundColor Red
    exit 1
}

$acctState = az account show --query state -o tsv
if ($acctState -ne "Enabled") {
    Write-Host "[ERROR] Not logged in to Azure CLI. Run 'az login' first." -ForegroundColor Red
    exit 1
}

if ($SubscriptionId) {
    Invoke-AzCliSilent -Arguments @('account','set','--subscription',$SubscriptionId) | Out-Null
    Write-Host "[SUCCESS] Subscription set to: $SubscriptionId" -ForegroundColor Green
}

# Ensure required CLI extensions are installed
Write-Host "[INFO] Installing/upgrading required Azure CLI extensions..." -ForegroundColor Cyan
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = 'SilentlyContinue'
az extension add --name application-insights --upgrade --yes 2>$null
$ErrorActionPreference = $prevEAP
Write-Host "[SUCCESS] Prerequisites OK" -ForegroundColor Green

# Register required resource providers
Write-Host "[INFO] Registering required Azure resource providers..." -ForegroundColor Cyan
$requiredProviders = @('Microsoft.KeyVault','Microsoft.ServiceBus','Microsoft.Storage',
    'Microsoft.Web','Microsoft.Insights','Microsoft.OperationalInsights','Microsoft.DocumentDB',
    'Microsoft.CognitiveServices')
$providersToWait = [System.Collections.Generic.List[string]]::new()
foreach ($provider in $requiredProviders) {
    $state = (Invoke-AzCliSilent -Arguments @('provider','show','--namespace',$provider,'--query','registrationState','-o','tsv')).Output
    if ($state -eq 'Registered') {
        Write-Host "  [OK] $provider already registered" -ForegroundColor Green
    } else {
        Write-Host "  [INFO] Registering $provider..." -ForegroundColor Cyan
        Invoke-AzCliSilent -Arguments @('provider','register','--namespace',$provider) | Out-Null
        $providersToWait.Add($provider)
    }
}
if ($providersToWait.Count -gt 0) {
    Write-Host "[INFO] Waiting for $($providersToWait.Count) provider(s) to finish registering..." -ForegroundColor Cyan
    foreach ($provider in $providersToWait) {
        for ($i = 1; $i -le 60; $i++) {
            $state = (Invoke-AzCliSilent -Arguments @('provider','show','--namespace',$provider,'--query','registrationState','-o','tsv')).Output
            if ($state -eq 'Registered') {
                Write-Host "  [SUCCESS] $provider registered" -ForegroundColor Green
                break
            }
            Start-Sleep -Seconds 5
        }
        if ($state -ne 'Registered') {
            Write-Host "  [WARNING] $provider still not registered after 5 minutes - continuing anyway" -ForegroundColor Yellow
        }
    }
}

# =============================================================================
# VALIDATE SERVICE LOCATIONS
# =============================================================================
Write-Host ""
Write-Host "[INFO] Validating service availability in location '$Location'..." -ForegroundColor Cyan

$LocationResourceGroup        = Get-ServiceLocation -ServiceName "resourcegroup"        -DefaultLocation $Location
$LocationStorage              = Get-ServiceLocation -ServiceName "storageaccount"       -DefaultLocation $Location
$LocationKeyVault             = Get-ServiceLocation -ServiceName "keyvault"             -DefaultLocation $Location
$LocationServiceBus           = Get-ServiceLocation -ServiceName "servicebus"           -DefaultLocation $Location
$LocationAppInsights          = Get-ServiceLocation -ServiceName "applicationinsights"  -DefaultLocation $Location
$LocationCosmosDb             = Get-ServiceLocation -ServiceName "cosmosdb"             -DefaultLocation $Location
$LocationContentUnderstanding = Get-ServiceLocation -ServiceName "contentunderstanding" -DefaultLocation $Location
$LocationAiFoundry            = Get-ServiceLocation -ServiceName "aifoundry"            -DefaultLocation $Location
$LocationAppService           = Get-ServiceLocation -ServiceName "appservice"           -DefaultLocation $Location
$LocationFunctionApp          = Get-ServiceLocation -ServiceName "functionapp"          -DefaultLocation $Location

Write-Host "[SUCCESS] Service location validation complete" -ForegroundColor Green

# =============================================================================
# STEP 1: Resource Group
# =============================================================================
Write-Host ""
Write-Host ">>> Step 1/12: Resource Group" -ForegroundColor White

if (Test-AzResource -Arguments @('group','show','--name',$ResourceGroupName,'--query','name','-o','tsv')) {
    Write-Host "[WARNING] Resource group $ResourceGroupName already exists, skipping" -ForegroundColor Yellow
} else {
    $result = Invoke-AzCli -Description "Creating resource group: $ResourceGroupName" `
        -Arguments @('group','create','--name',$ResourceGroupName,'--location',$LocationResourceGroup,
                     '--tags',"project=$ProjectName","environment=$Environment",'--output','table')
    if ($null -ne $result) {
        Write-Host "[SUCCESS] Resource group $ResourceGroupName created" -ForegroundColor Green
    }
}

# =============================================================================
# STEP 2: Storage Account
# =============================================================================
Write-Host ""
Write-Host ">>> Step 2/12: Storage Account" -ForegroundColor White

if (Test-AzResource -Arguments @('storage','account','show','--name',$StorageAccountName,'--resource-group',$ResourceGroupName,'--query','name','-o','tsv')) {
    Write-Host "[WARNING] Storage account $StorageAccountName already exists, skipping" -ForegroundColor Yellow
} else {
    $result = Invoke-AzCli -Description "Creating storage account: $StorageAccountName" `
        -Arguments @('storage','account','create','--name',$StorageAccountName,
                     '--resource-group',$ResourceGroupName,'--location',$LocationStorage,
                     '--sku','Standard_LRS','--kind','StorageV2','--access-tier','Hot',
                     '--tags',"project=$ProjectName","environment=$Environment",'--output','table')
    if ($null -ne $result) {
        Write-Host "[SUCCESS] Storage account $StorageAccountName created" -ForegroundColor Green
    }
}

# Disable soft-delete for blobs, containers, and file shares
Write-Host "[INFO] Disabling soft-delete on storage account: $StorageAccountName" -ForegroundColor Cyan
Invoke-AzCli -Description "Disabling blob and container soft-delete" `
    -Arguments @('storage','account','blob-service-properties','update',
                 '--account-name',$StorageAccountName,'--resource-group',$ResourceGroupName,
                 '--enable-delete-retention','false','--enable-container-delete-retention','false',
                 '--output','none')
Invoke-AzCli -Description "Disabling file share soft-delete" `
    -Arguments @('storage','account','file-service-properties','update',
                 '--account-name',$StorageAccountName,'--resource-group',$ResourceGroupName,
                 '--enable-delete-retention','false',
                 '--output','none')
Write-Host "[SUCCESS] Soft-delete disabled on storage account" -ForegroundColor Green

# Derive container name from USER_EMAIL_ADDRESS (username part, lowercased, alphanumeric+hyphens)
$UserEmail = if ($env:USER_EMAIL_ADDRESS) { $env:USER_EMAIL_ADDRESS } else { "" }
if (-not $UserEmail) {
    Write-Host "[WARNING] USER_EMAIL_ADDRESS is not set – skipping storage container creation" -ForegroundColor Yellow
} else {
    # Extract username part (before @), lowercase, replace invalid chars with hyphens
    $StorageContainerName = ($UserEmail.Split('@')[0]).ToLower() -replace '[^a-z0-9-]', '-' -replace '-+', '-' -replace '^-|-$', ''
    Write-Host "[INFO] Storage container name derived from email: $StorageContainerName" -ForegroundColor Cyan

    # Get the blob endpoint
    $StorageBlobEndpoint = (Invoke-AzCliSilent -Arguments @('storage','account','show','--name',$StorageAccountName,'--resource-group',$ResourceGroupName,'--query','primaryEndpoints.blob','-o','tsv')).Output
    Write-Host "[INFO] Storage blob endpoint: $StorageBlobEndpoint" -ForegroundColor Cyan

    # Create the container (idempotent – skip if exists)
    $existing = Invoke-AzCliSilent -Arguments @('storage','container','show','--name',$StorageContainerName,'--account-name',$StorageAccountName,'--auth-mode','login','--query','name','-o','tsv')
    if ($existing.ExitCode -eq 0 -and $existing.Output) {
        Write-Host "[WARNING] Storage container '$StorageContainerName' already exists, skipping" -ForegroundColor Yellow
    } else {
        $r = Invoke-AzCli -Description "Creating storage container: $StorageContainerName" `
            -Arguments @('storage','container','create','--name',$StorageContainerName,
                         '--account-name',$StorageAccountName,'--auth-mode','login','--output','none')
        if ($null -ne $r) {
            Write-Host "[SUCCESS] Storage container '$StorageContainerName' created" -ForegroundColor Green
        }
    }
}

# =============================================================================
# STEP 3: Key Vault
# =============================================================================
Write-Host ""
Write-Host ">>> Step 3/12: Key Vault" -ForegroundColor White

if (Test-AzResource -Arguments @('keyvault','show','--name',$KeyVaultName,'--query','name','-o','tsv')) {
    Write-Host "[WARNING] Key Vault $KeyVaultName already exists, skipping creation" -ForegroundColor Yellow
} else {
    $result = Invoke-AzCli -Description "Creating Key Vault: $KeyVaultName" `
        -Arguments @('keyvault','create','--name',$KeyVaultName,
                     '--resource-group',$ResourceGroupName,'--location',$LocationKeyVault,
                     '--sku','standard','--enable-rbac-authorization','true',
                     '--retention-days','7',
                     '--tags',"project=$ProjectName","environment=$Environment",'--output','table')
    if ($null -ne $result) {
        Write-Host "[SUCCESS] Key Vault $KeyVaultName created" -ForegroundColor Green
    }
}

# Ensure minimum soft-delete retention (7 days), no purge protection, and public network access
# Note: Soft-delete cannot be fully disabled on Azure Key Vault (enforced since 2020)
Write-Host "[INFO] Setting Key Vault soft-delete retention to minimum (7 days), public network access enabled" -ForegroundColor Cyan
Invoke-AzCliSilent -Arguments @('keyvault','update','--name',$KeyVaultName,
                                '--resource-group',$ResourceGroupName,
                                '--retention-days','7',
                                '--public-network-access','Enabled',
                                '--output','none') | Out-Null

# Grant current user Key Vault Administrator role via RBAC
$CurrentUserId = (Invoke-AzCliSilent -Arguments @('ad','signed-in-user','show','--query','id','-o','tsv')).Output
$KeyVaultId = (Invoke-AzCliSilent -Arguments @('keyvault','show','--name',$KeyVaultName,'--resource-group',$ResourceGroupName,'--query','id','-o','tsv')).Output
if ($CurrentUserId -and $KeyVaultId) {
    $alreadyAssigned = Ensure-RoleAssignment -Assignee $CurrentUserId -Role 'Key Vault Administrator' -Scope $KeyVaultId
    if ($alreadyAssigned) {
        Write-Host "[OK] Key Vault Administrator role already assigned to current user" -ForegroundColor Green
    } else {
        Write-Host "[SUCCESS] Key Vault Administrator role assigned to current user" -ForegroundColor Green
        Write-Host "[INFO] Waiting 60 seconds for RBAC propagation..." -ForegroundColor Cyan
        Start-Sleep -Seconds 60
    }
}

# =============================================================================
# STEP 4: Graph API Registration
# =============================================================================
Write-Host ""
Write-Host ">>> Step 4/12: Graph API Registration" -ForegroundColor White

$ExistingAppId = (Invoke-AzCliSilent -Arguments @('ad','app','list','--display-name',$GraphAppName,'--query','[0].appId','-o','tsv')).Output
if ($ExistingAppId) {
    Write-Host "[OK] App registration $GraphAppName already exists with ID: $ExistingAppId" -ForegroundColor Green
    $GraphClientId = $ExistingAppId
} else {
    $graphPerms = '[{\"resourceAppId\":\"00000003-0000-0000-c000-000000000000\",\"resourceAccess\":[{\"id\":\"810c84a8-4a9e-49e6-bf7d-12d183f40d01\",\"type\":\"Role\"},{\"id\":\"40f97065-369a-49f4-947c-6a255697ae91\",\"type\":\"Role\"}]}]'
    Invoke-AzCliSilent -Arguments @('ad','app','create','--display-name',$GraphAppName,'--sign-in-audience','AzureADMyOrg','--required-resource-accesses',$graphPerms,'--output','none') | Out-Null
    $GraphClientId = (Invoke-AzCliSilent -Arguments @('ad','app','list','--display-name',$GraphAppName,'--query','[0].appId','-o','tsv')).Output
    Write-Host "[SUCCESS] App registration created with ID: $GraphClientId" -ForegroundColor Green
}

if (-not $GraphClientSecret) {
    # Check if credentials already exist to avoid invalidating stored secrets
    $existingCreds = (Invoke-AzCliSilent -Arguments @('ad','app','credential','list','--id',$GraphClientId,'--query','[0].keyId','-o','tsv')).Output
    if ($existingCreds) {
        # Credential exists in Entra ID - verify the secret is also present in Key Vault
        $kvSecret = (Invoke-AzCliSilent -Arguments @('keyvault','secret','show','--vault-name',$KeyVaultName,'--name','GraphClientSecret','--query','value','-o','tsv')).Output
        if ($kvSecret) {
            Write-Host "[OK] Client secret already exists for $GraphAppName and is stored in Key Vault" -ForegroundColor Green
            $GraphClientSecret = $kvSecret
        } else {
            # Secret missing from Key Vault - must rotate the credential to get a new value
            Write-Host "[WARNING] Client secret exists in Entra ID but is missing from Key Vault. Rotating credential..." -ForegroundColor Yellow
            $credResult = Invoke-AzCliSilent -Arguments @('ad','app','credential','reset','--id',$GraphClientId,'--display-name','extract-insight-action-secret','--years','2','--query','password','-o','tsv')
            if ($credResult.ExitCode -eq 0 -and $credResult.Output) {
                $GraphClientSecret = $credResult.Output
                Write-Host "[SUCCESS] Client secret rotated and will be stored in Key Vault" -ForegroundColor Green
            } else {
                Write-Host "[ERROR] Failed to rotate client secret for $GraphAppName" -ForegroundColor Red
                if ($credResult.Error) { Write-Host "  $($credResult.Error)" -ForegroundColor Red }
                $script:DeploymentErrors.Add("Graph API client secret rotation")
            }
        }
    } else {
        $credResult = Invoke-AzCliSilent -Arguments @('ad','app','credential','reset','--id',$GraphClientId,'--display-name','extract-insight-action-secret','--years','2','--query','password','-o','tsv')
        if ($credResult.ExitCode -eq 0 -and $credResult.Output) {
            $GraphClientSecret = $credResult.Output
            Write-Host "[SUCCESS] Client secret created for Graph API" -ForegroundColor Green
        } else {
            Write-Host "[ERROR] Failed to create client secret for $GraphAppName" -ForegroundColor Red
            if ($credResult.Error) { Write-Host "  $($credResult.Error)" -ForegroundColor Red }
            $script:DeploymentErrors.Add("Graph API client secret creation")
        }
    }
}
if (-not $GraphClientSecret) {
    Write-Host "[WARNING] GraphClientSecret is empty - the 'GraphClientSecret' Key Vault secret will be skipped." -ForegroundColor Yellow
    Write-Host "[WARNING] You can set it manually: az keyvault secret set --vault-name $KeyVaultName --name GraphClientSecret --value '<secret>'" -ForegroundColor Yellow
}

Write-Host "[INFO] Run .\grant-graph-consent.ps1 -Suffix $Suffix to grant admin consent (requires tenant admin role)" -ForegroundColor Cyan

# =============================================================================
# STEP 5: Service Bus
# =============================================================================
Write-Host ""
Write-Host ">>> Step 5/12: Service Bus" -ForegroundColor White

if (Test-AzResource -Arguments @('servicebus','namespace','show','--name',$ServiceBusNamespace,'--resource-group',$ResourceGroupName,'--query','name','-o','tsv')) {
    Write-Host "[WARNING] Service Bus namespace $ServiceBusNamespace already exists, skipping" -ForegroundColor Yellow
} else {
    $result = Invoke-AzCli -Description "Creating Service Bus namespace: $ServiceBusNamespace" `
        -Arguments @('servicebus','namespace','create','--name',$ServiceBusNamespace,
                     '--resource-group',$ResourceGroupName,'--location',$LocationServiceBus,
                     '--sku','Standard',
                     '--tags',"project=$ProjectName","environment=$Environment",'--output','table')
    if ($null -ne $result) {
        Write-Host "[SUCCESS] Service Bus namespace $ServiceBusNamespace created" -ForegroundColor Green
    }
}

# Topic
if (Test-AzResource -Arguments @('servicebus','topic','show','--name',$ServiceBusTopicName,'--namespace-name',$ServiceBusNamespace,'--resource-group',$ResourceGroupName,'--query','name','-o','tsv')) {
    Write-Host "[WARNING] Service Bus topic $ServiceBusTopicName already exists, skipping" -ForegroundColor Yellow
} else {
    $result = Invoke-AzCli -Description "Creating Service Bus topic: $ServiceBusTopicName" `
        -Arguments @('servicebus','topic','create','--name',$ServiceBusTopicName,
                     '--namespace-name',$ServiceBusNamespace,'--resource-group',$ResourceGroupName,
                     '--max-size','1024','--default-message-time-to-live','P14D',
                     '--enable-duplicate-detection','true','--duplicate-detection-history-time-window','PT10M',
                     '--output','table')
    if ($null -ne $result) {
        Write-Host "[SUCCESS] Service Bus topic $ServiceBusTopicName created" -ForegroundColor Green
    }
}

# Subscription
if (Test-AzResource -Arguments @('servicebus','topic','subscription','show','--name',$ServiceBusSubName,'--topic-name',$ServiceBusTopicName,'--namespace-name',$ServiceBusNamespace,'--resource-group',$ResourceGroupName,'--query','name','-o','tsv')) {
    Write-Host "[WARNING] Service Bus subscription $ServiceBusSubName already exists, skipping" -ForegroundColor Yellow
} else {
    $result = Invoke-AzCli -Description "Creating Service Bus subscription: $ServiceBusSubName" `
        -Arguments @('servicebus','topic','subscription','create','--name',$ServiceBusSubName,
                     '--topic-name',$ServiceBusTopicName,'--namespace-name',$ServiceBusNamespace,
                     '--resource-group',$ResourceGroupName,
                     '--max-delivery-count','10','--default-message-time-to-live','P14D','--output','table')
    if ($null -ne $result) {
        Write-Host "[SUCCESS] Service Bus subscription $ServiceBusSubName created" -ForegroundColor Green
    }
}

# =============================================================================
# STEP 6: Application Insights
# =============================================================================
Write-Host ""
Write-Host ">>> Step 6/12: Application Insights" -ForegroundColor White

if (Test-AzResource -Arguments @('monitor','app-insights','component','show','--app',$AppInsightsName,'--resource-group',$ResourceGroupName,'--query','name','-o','tsv')) {
    Write-Host "[WARNING] Application Insights $AppInsightsName already exists, skipping" -ForegroundColor Yellow
} else {
    $result = Invoke-AzCli -Description "Creating Application Insights: $AppInsightsName" `
        -Arguments @('monitor','app-insights','component','create','--app',$AppInsightsName,
                     '--resource-group',$ResourceGroupName,'--location',$LocationAppInsights,
                     '--kind','web','--application-type','web',
                     '--tags',"project=$ProjectName","environment=$Environment",'--output','table')
    if ($null -ne $result) {
        Write-Host "[SUCCESS] Application Insights $AppInsightsName created" -ForegroundColor Green
    }
}

# =============================================================================
# STEP 7/12: Azure Cosmos DB (NoSQL)
# =============================================================================
Write-Host ""
Write-Host ">>> Step 7/12: Azure Cosmos DB (NoSQL)" -ForegroundColor White

if (Test-AzResource -Arguments @('cosmosdb','show','--name',$CosmosDbAccountName,'--resource-group',$ResourceGroupName,'--query','name','-o','tsv')) {
    Write-Host "[WARNING] Cosmos DB account $CosmosDbAccountName already exists, skipping account creation" -ForegroundColor Yellow
} else {
    $result = Invoke-AzCli -Description "Creating Cosmos DB account: $CosmosDbAccountName" `
        -Arguments @('cosmosdb','create','--name',$CosmosDbAccountName,
                     '--resource-group',$ResourceGroupName,
                     '--locations',"regionName=$LocationCosmosDb","failoverPriority=0","isZoneRedundant=false",
                     '--kind','GlobalDocumentDB',
                     '--default-consistency-level','Session',
                     '--tags',"project=$ProjectName","environment=$Environment",
                     '--output','table')
    if ($result -ne $null) {
        Write-Host "[SUCCESS] Cosmos DB account $CosmosDbAccountName created" -ForegroundColor Green
    }
}

# Create database
$dbExists = (Invoke-AzCliSilent -Arguments @('cosmosdb','sql','database','show','--account-name',$CosmosDbAccountName,'--resource-group',$ResourceGroupName,'--name',$CosmosDbDatabaseName,'--query','name','-o','tsv')).Output
if ($dbExists) {
    Write-Host "[WARNING] Database $CosmosDbDatabaseName already exists, skipping" -ForegroundColor Yellow
} else {
    Invoke-AzCli -Description "Creating database: $CosmosDbDatabaseName" `
        -Arguments @('cosmosdb','sql','database','create','--account-name',$CosmosDbAccountName,
                     '--resource-group',$ResourceGroupName,'--name',$CosmosDbDatabaseName,
                     '--output','table')
}

# Create container
$containerExists = (Invoke-AzCliSilent -Arguments @('cosmosdb','sql','container','show','--account-name',$CosmosDbAccountName,'--resource-group',$ResourceGroupName,'--database-name',$CosmosDbDatabaseName,'--name',$CosmosDbContainerName,'--query','name','-o','tsv')).Output
if ($containerExists) {
    Write-Host "[WARNING] Container $CosmosDbContainerName already exists, skipping" -ForegroundColor Yellow
} else {
    Invoke-AzCli -Description "Creating container: $CosmosDbContainerName (partition key: /id)" `
        -Arguments @('cosmosdb','sql','container','create','--account-name',$CosmosDbAccountName,
                     '--resource-group',$ResourceGroupName,'--database-name',$CosmosDbDatabaseName,
                     '--name',$CosmosDbContainerName,'--partition-key-path','/id',
                     '--output','table')
}

# =============================================================================
# STEP 8/12: Azure Content Understanding
# =============================================================================
Write-Host ""
Write-Host ">>> Step 8/12: Azure Content Understanding" -ForegroundColor White

if (Test-AzResource -Arguments @('cognitiveservices','account','show','--name',$ContentUnderstandingName,'--resource-group',$ResourceGroupName,'--query','name','-o','tsv')) {
    Write-Host "[WARNING] Content Understanding $ContentUnderstandingName already exists, skipping" -ForegroundColor Yellow
} else {
    $result = Invoke-AzCli -Description "Creating Azure Content Understanding: $ContentUnderstandingName" `
        -Arguments @('cognitiveservices','account','create','--name',$ContentUnderstandingName,
                     '--resource-group',$ResourceGroupName,'--location',$LocationContentUnderstanding,
                     '--kind','AIServices','--sku','S0',
                     '--custom-domain',$ContentUnderstandingName,
                     '--tags',"project=$ProjectName","environment=$Environment",
                     '--output','table','--yes')
    if ($result -ne $null) {
        Write-Host "[SUCCESS] Content Understanding $ContentUnderstandingName created" -ForegroundColor Green
    }
}

# =============================================================================
# STEP 9/12: Azure AI Foundry + LLM Model Deployment
# =============================================================================
Write-Host ""
Write-Host ">>> Step 9/12: Azure AI Foundry + LLM Model Deployment" -ForegroundColor White

# Create AI Foundry resource (Azure AI Services account)
if (Test-AzResource -Arguments @('cognitiveservices','account','show','--name',$AiFoundryName,'--resource-group',$ResourceGroupName,'--query','name','-o','tsv')) {
    Write-Host "[WARNING] AI Foundry resource $AiFoundryName already exists, skipping" -ForegroundColor Yellow
} else {
    $result = Invoke-AzCli -Description "Creating Azure AI Foundry resource: $AiFoundryName" `
        -Arguments @('cognitiveservices','account','create','--name',$AiFoundryName,
                     '--resource-group',$ResourceGroupName,'--location',$LocationAiFoundry,
                     '--kind','AIServices','--sku','S0',
                     '--custom-domain',$AiFoundryName,
                     '--tags',"project=$ProjectName","environment=$Environment",
                     '--output','table','--yes')
    if ($result -ne $null) {
        Write-Host "[SUCCESS] AI Foundry resource $AiFoundryName created" -ForegroundColor Green
    }
}

# Deploy main LLM model (gpt-5.1-chat, GlobalStandard, 50K TPM)
$deploymentExists = (Invoke-AzCliSilent -Arguments @('cognitiveservices','account','deployment','show','--name',$AiFoundryName,'--resource-group',$ResourceGroupName,'--deployment-name',$AiFoundryDeploymentName,'--query','name','-o','tsv')).Output
if ($deploymentExists) {
    Write-Host "[WARNING] Model deployment $AiFoundryDeploymentName already exists, skipping" -ForegroundColor Yellow
} else {
    $result = Invoke-AzCli -Description "Deploying model $AiFoundryModelName ($AiFoundrySkuName, ${AiFoundrySkuCapacity}K TPM)" `
        -Arguments @('cognitiveservices','account','deployment','create',
                     '--name',$AiFoundryName,'--resource-group',$ResourceGroupName,
                     '--deployment-name',$AiFoundryDeploymentName,
                     '--model-name',$AiFoundryModelName,
                     '--model-version',$AiFoundryModelVersion,
                     '--model-format','OpenAI',
                     '--sku-name',$AiFoundrySkuName,
                     '--sku-capacity',$AiFoundrySkuCapacity,
                     '--output','table')
    if ($result -ne $null) {
        Write-Host "[SUCCESS] Model $AiFoundryModelName deployed as $AiFoundryDeploymentName" -ForegroundColor Green
    }
}

# Deploy CU-compatible completion model on the CU resource itself (gpt-4.1)
# The PATCH /contentunderstanding/defaults resolves deployments from the CU
# resource, not from a separate AI Foundry resource.
$cuDeploymentExists = (Invoke-AzCliSilent -Arguments @('cognitiveservices','account','deployment','show','--name',$ContentUnderstandingName,'--resource-group',$ResourceGroupName,'--deployment-name',$CuCompletionDeploymentName,'--query','name','-o','tsv')).Output
if ($cuDeploymentExists) {
    Write-Host "[WARNING] CU completion model deployment $CuCompletionDeploymentName already exists on $ContentUnderstandingName, skipping" -ForegroundColor Yellow
} else {
    $result = Invoke-AzCli -Description "Deploying CU completion model $CuCompletionModelName on $ContentUnderstandingName ($AiFoundrySkuName, ${CuCompletionSkuCapacity}K TPM)" `
        -Arguments @('cognitiveservices','account','deployment','create',
                     '--name',$ContentUnderstandingName,'--resource-group',$ResourceGroupName,
                     '--deployment-name',$CuCompletionDeploymentName,
                     '--model-name',$CuCompletionModelName,
                     '--model-version',$CuCompletionModelVersion,
                     '--model-format','OpenAI',
                     '--sku-name',$AiFoundrySkuName,
                     '--sku-capacity',$CuCompletionSkuCapacity,
                     '--output','table')
    if ($result -ne $null) {
        Write-Host "[SUCCESS] CU completion model $CuCompletionModelName deployed as $CuCompletionDeploymentName on $ContentUnderstandingName" -ForegroundColor Green
    }
}

# Deploy CU embedding model on the CU resource (text-embedding-3-large)
$cuEmbedDeploymentExists = (Invoke-AzCliSilent -Arguments @('cognitiveservices','account','deployment','show','--name',$ContentUnderstandingName,'--resource-group',$ResourceGroupName,'--deployment-name',$CuEmbeddingDeploymentName,'--query','name','-o','tsv')).Output
if ($cuEmbedDeploymentExists) {
    Write-Host "[WARNING] CU embedding model deployment $CuEmbeddingDeploymentName already exists on $ContentUnderstandingName, skipping" -ForegroundColor Yellow
} else {
    $result = Invoke-AzCli -Description "Deploying CU embedding model $CuEmbeddingModelName on $ContentUnderstandingName ($AiFoundrySkuName, ${CuEmbeddingSkuCapacity}K TPM)" `
        -Arguments @('cognitiveservices','account','deployment','create',
                     '--name',$ContentUnderstandingName,'--resource-group',$ResourceGroupName,
                     '--deployment-name',$CuEmbeddingDeploymentName,
                     '--model-name',$CuEmbeddingModelName,
                     '--model-version',$CuEmbeddingModelVersion,
                     '--model-format','OpenAI',
                     '--sku-name',$AiFoundrySkuName,
                     '--sku-capacity',$CuEmbeddingSkuCapacity,
                     '--output','table')
    if ($result -ne $null) {
        Write-Host "[SUCCESS] CU embedding model $CuEmbeddingModelName deployed as $CuEmbeddingDeploymentName on $ContentUnderstandingName" -ForegroundColor Green
    }
}

# =============================================================================
# STEP 10/12: App Service (Java Spring Boot Web App)
# =============================================================================

# --- Content Understanding: set completion model defaults --------------------
# The CU service requires PATCH /contentunderstanding/defaults before custom
# analyzers can be created. This is idempotent; re-running is harmless.
# The deploying user needs "Cognitive Services User" (data-plane role) to write defaults.
# "Cognitive Services Contributor" is management-plane only and lacks the required
# dataAction Microsoft.CognitiveServices/accounts/analyzers/defaults/write.
Write-Host ""
Write-Host ">>> Configuring Content Understanding completion model defaults" -ForegroundColor White

$CuEndpoint = (Invoke-AzCliSilent -Arguments @('cognitiveservices','account','show','--name',$ContentUnderstandingName,'--resource-group',$ResourceGroupName,'--query','properties.endpoint','-o','tsv')).Output
$CuResourceId = (Invoke-AzCliSilent -Arguments @('cognitiveservices','account','show','--name',$ContentUnderstandingName,'--resource-group',$ResourceGroupName,'--query','id','-o','tsv')).Output

if (-not $CuEndpoint) {
    Write-Host "[WARNING] Cannot configure CU defaults - CU endpoint not available" -ForegroundColor Yellow
} else {
    # Ensure current user has Cognitive Services User on CU (data-plane role required for PATCH defaults)
    $cuRbacWait = $false
    if ($CurrentUserId -and $CuResourceId) {
        $cuRoleAlready = Ensure-RoleAssignment -Assignee $CurrentUserId -Role 'Cognitive Services User' -Scope $CuResourceId
        if (-not $cuRoleAlready) {
            Write-Host "[INFO] Granted Cognitive Services User to current user on $ContentUnderstandingName" -ForegroundColor Cyan
            $cuRbacWait = $true
            Write-Host "[INFO] Waiting 60 seconds for RBAC propagation..." -ForegroundColor Cyan
            Start-Sleep -Seconds 60
        }
    }

    $cuDefaultsUrl = "${CuEndpoint}contentunderstanding/defaults?api-version=2025-11-01"

    # Check if defaults are already set to the correct deployments
    $existingDefaults = Invoke-AzCliSilent -Arguments @('rest','--method','GET','--url',$cuDefaultsUrl,'--resource','https://cognitiveservices.azure.com')
    $needsUpdate = $true
    if ($existingDefaults.ExitCode -eq 0 -and $existingDefaults.Output) {
        $parsed = $existingDefaults.Output | ConvertFrom-Json -ErrorAction SilentlyContinue
        $currentCompletion = $parsed.modelDeployments."$CuCompletionModelName"
        $currentEmbedding  = $parsed.modelDeployments."$CuEmbeddingModelName"
        if ($currentCompletion -eq $CuCompletionDeploymentName -and $currentEmbedding -eq $CuEmbeddingDeploymentName) {
            Write-Host "[OK] Content Understanding defaults already configured ($CuCompletionModelName -> $CuCompletionDeploymentName, $CuEmbeddingModelName -> $CuEmbeddingDeploymentName)" -ForegroundColor Green
            $needsUpdate = $false
        } else {
            Write-Host "[INFO] Content Understanding defaults need updating" -ForegroundColor Cyan
        }
    }

    if ($needsUpdate) {
        $defaultsBody = @{
            modelDeployments = @{
                $CuCompletionModelName = $CuCompletionDeploymentName
                $CuEmbeddingModelName  = $CuEmbeddingDeploymentName
            }
        } | ConvertTo-Json -Depth 5 -Compress

        $tempDefaultsFile = [System.IO.Path]::GetTempFileName()
        [System.IO.File]::WriteAllText($tempDefaultsFile, $defaultsBody, [System.Text.Encoding]::UTF8)

        # Retry up to 3 times in case RBAC propagation is still in-flight
        $cuDefaultsSet = $false
        $maxRetries = 3
        for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
            $setResult = Invoke-AzCliSilent -Arguments @('rest','--method','PATCH','--url',$cuDefaultsUrl,'--resource','https://cognitiveservices.azure.com','--body',"@$tempDefaultsFile",'--headers','Content-Type=application/json')
            if ($setResult.ExitCode -eq 0) {
                Write-Host "[SUCCESS] Content Understanding defaults set ($CuCompletionModelName -> $CuCompletionDeploymentName on $ContentUnderstandingName)" -ForegroundColor Green
                $cuDefaultsSet = $true
                break
            }
            if ($attempt -lt $maxRetries -and $setResult.Error -match 'PermissionDenied') {
                Write-Host "[INFO] Permission not yet propagated, retrying in 30 seconds (attempt $attempt/$maxRetries)..." -ForegroundColor Cyan
                Start-Sleep -Seconds 30
            }
        }
        Remove-Item $tempDefaultsFile -Force -ErrorAction SilentlyContinue

        if (-not $cuDefaultsSet) {
            Write-Host "[ERROR] Failed to set Content Understanding defaults" -ForegroundColor Red
            if ($setResult.Error) { Write-Host "  $($setResult.Error)" -ForegroundColor Red }
            $script:DeploymentErrors.Add("Content Understanding defaults")
        }
    }
}
Write-Host ""
Write-Host ">>> Step 10/12: App Service (Java Spring Boot Web App)" -ForegroundColor White

# Create App Service Plan (Linux, P0v3 tier)
if (Test-AzResource -Arguments @('appservice','plan','show','--name',$AppServicePlanName,'--resource-group',$ResourceGroupName,'--query','name','-o','tsv')) {
    Write-Host "[WARNING] App Service Plan $AppServicePlanName already exists, skipping" -ForegroundColor Yellow
} else {
    $result = Invoke-AzCli -Description "Creating App Service Plan: $AppServicePlanName (Linux P0v3)" `
        -Arguments @('appservice','plan','create','--name',$AppServicePlanName,
                     '--resource-group',$ResourceGroupName,'--location',$LocationAppService,
                     '--sku','P0v3','--is-linux',
                     '--tags',"project=$ProjectName","environment=$Environment",
                     '--output','table')
    if ($result -ne $null) {
        Write-Host "[SUCCESS] App Service Plan $AppServicePlanName created" -ForegroundColor Green
    }
}

# Create Web App (Java 21 / Java SE)
if (Test-AzResource -Arguments @('webapp','show','--name',$WebAppName,'--resource-group',$ResourceGroupName,'--query','name','-o','tsv')) {
    Write-Host "[WARNING] Web App $WebAppName already exists, skipping" -ForegroundColor Yellow
} else {
    $result = Invoke-AzCli -Description "Creating Web App: $WebAppName (Java 21 Spring Boot)" `
        -Arguments @('webapp','create','--name',$WebAppName,
                     '--resource-group',$ResourceGroupName,
                     '--plan',$AppServicePlanName,
                     '--runtime','JAVA:21-java21',
                     '--tags',"project=$ProjectName","environment=$Environment","app=spring-boot-web",
                     '--output','table')
    if ($result -ne $null) {
        Write-Host "[SUCCESS] Web App $WebAppName created" -ForegroundColor Green
    }
}

# =============================================================================
# STEP 11/12: Function Apps (Flex Consumption)
# =============================================================================
Write-Host ""
Write-Host ">>> Step 11/12: Function Apps (Flex Consumption, Java 21)" -ForegroundColor White

$AppInsightsKey = (Invoke-AzCliSilent -Arguments @('monitor','app-insights','component','show','--app',$AppInsightsName,'--resource-group',$ResourceGroupName,'--query','instrumentationKey','-o','tsv')).Output

# Build common args for Flex Consumption function app creation
$CommonFuncArgs = @('--resource-group',$ResourceGroupName,'--storage-account',$StorageAccountName,
                    '--flexconsumption-location',$LocationFunctionApp,
                    '--runtime','java','--runtime-version','21.0')
if ($AppInsightsKey) {
    $CommonFuncArgs += @('--app-insights',$AppInsightsName,'--app-insights-key',$AppInsightsKey)
} else {
    Write-Host "[WARNING] Application Insights key not found, creating function apps without App Insights" -ForegroundColor Yellow
    $CommonFuncArgs += @('--disable-app-insights','true')
}

# Mailbox function
if (Test-AzResource -Arguments @('functionapp','show','--name',$FuncMailboxName,'--resource-group',$ResourceGroupName,'--query','name','-o','tsv')) {
    Write-Host "[WARNING] Function app $FuncMailboxName already exists, skipping" -ForegroundColor Yellow
} else {
    $result = Invoke-AzCli -Description "Creating function app: $FuncMailboxName" `
        -Arguments (@('functionapp','create','--name',$FuncMailboxName) + $CommonFuncArgs + @(
                     '--tags',"project=$ProjectName","environment=$Environment","function=mailbox-to-queue",
                     '--output','table'))
    if ($result -ne $null) {
        Write-Host "[SUCCESS] Function app $FuncMailboxName created" -ForegroundColor Green
    }
}

# Queue-to-DB function
if (Test-AzResource -Arguments @('functionapp','show','--name',$FuncQueueDbName,'--resource-group',$ResourceGroupName,'--query','name','-o','tsv')) {
    Write-Host "[WARNING] Function app $FuncQueueDbName already exists, skipping" -ForegroundColor Yellow
} else {
    $result = Invoke-AzCli -Description "Creating function app: $FuncQueueDbName" `
        -Arguments (@('functionapp','create','--name',$FuncQueueDbName) + $CommonFuncArgs + @(
                     '--tags',"project=$ProjectName","environment=$Environment","function=queue-to-db",
                     '--output','table'))
    if ($result -ne $null) {
        Write-Host "[SUCCESS] Function app $FuncQueueDbName created" -ForegroundColor Green
    }
}

# =============================================================================
# STEP 12/12: Managed Identities & RBAC
# =============================================================================
Write-Host ""
Write-Host ">>> Step 12/12: Managed Identities & RBAC" -ForegroundColor White

# Verify function apps and web app exist before proceeding
$MailboxExists = Test-AzResource -Arguments @('functionapp','show','--name',$FuncMailboxName,'--resource-group',$ResourceGroupName,'--query','name','-o','tsv')
$QueueDbExists = Test-AzResource -Arguments @('functionapp','show','--name',$FuncQueueDbName,'--resource-group',$ResourceGroupName,'--query','name','-o','tsv')
$WebAppExists  = Test-AzResource -Arguments @('webapp','show','--name',$WebAppName,'--resource-group',$ResourceGroupName,'--query','name','-o','tsv')

if (-not $MailboxExists -or -not $QueueDbExists) {
    Write-Host "[ERROR] One or both function apps do not exist. Cannot configure managed identities." -ForegroundColor Red
    if (-not $MailboxExists) { Write-Host "  Missing: $FuncMailboxName" -ForegroundColor Red }
    if (-not $QueueDbExists) { Write-Host "  Missing: $FuncQueueDbName" -ForegroundColor Red }
    Write-Host "[ERROR] Please fix the function app creation errors above and re-run the script." -ForegroundColor Red
    exit 1
}
if (-not $WebAppExists) {
    Write-Host "[ERROR] Web app $WebAppName does not exist. Cannot configure managed identity." -ForegroundColor Red
    Write-Host "[ERROR] Please fix the web app creation errors above and re-run the script." -ForegroundColor Red
    exit 1
}

# Enable managed identities (skip if already enabled)
$MailboxIdentity = (Invoke-AzCliSilent -Arguments @('functionapp','identity','show','--name',$FuncMailboxName,'--resource-group',$ResourceGroupName,'--query','principalId','-o','tsv')).Output
if ($MailboxIdentity) {
    Write-Host "[OK] Managed identity already enabled for $FuncMailboxName" -ForegroundColor Green
} else {
    Write-Host "[INFO] Enabling managed identity for $FuncMailboxName" -ForegroundColor Cyan
    Invoke-AzCliSilent -Arguments @('functionapp','identity','assign','--name',$FuncMailboxName,'--resource-group',$ResourceGroupName,'--output','none') | Out-Null
    $MailboxIdentity = (Invoke-AzCliSilent -Arguments @('functionapp','identity','show','--name',$FuncMailboxName,'--resource-group',$ResourceGroupName,'--query','principalId','-o','tsv')).Output
    Write-Host "[SUCCESS] Managed identity enabled for $FuncMailboxName" -ForegroundColor Green
}

$QueueDbIdentity = (Invoke-AzCliSilent -Arguments @('functionapp','identity','show','--name',$FuncQueueDbName,'--resource-group',$ResourceGroupName,'--query','principalId','-o','tsv')).Output
if ($QueueDbIdentity) {
    Write-Host "[OK] Managed identity already enabled for $FuncQueueDbName" -ForegroundColor Green
} else {
    Write-Host "[INFO] Enabling managed identity for $FuncQueueDbName" -ForegroundColor Cyan
    Invoke-AzCliSilent -Arguments @('functionapp','identity','assign','--name',$FuncQueueDbName,'--resource-group',$ResourceGroupName,'--output','none') | Out-Null
    $QueueDbIdentity = (Invoke-AzCliSilent -Arguments @('functionapp','identity','show','--name',$FuncQueueDbName,'--resource-group',$ResourceGroupName,'--query','principalId','-o','tsv')).Output
    Write-Host "[SUCCESS] Managed identity enabled for $FuncQueueDbName" -ForegroundColor Green
}

$WebAppIdentity = (Invoke-AzCliSilent -Arguments @('webapp','identity','show','--name',$WebAppName,'--resource-group',$ResourceGroupName,'--query','principalId','-o','tsv')).Output
if ($WebAppIdentity) {
    Write-Host "[OK] Managed identity already enabled for $WebAppName" -ForegroundColor Green
} else {
    Write-Host "[INFO] Enabling managed identity for $WebAppName" -ForegroundColor Cyan
    Invoke-AzCliSilent -Arguments @('webapp','identity','assign','--name',$WebAppName,'--resource-group',$ResourceGroupName,'--output','none') | Out-Null
    $WebAppIdentity = (Invoke-AzCliSilent -Arguments @('webapp','identity','show','--name',$WebAppName,'--resource-group',$ResourceGroupName,'--query','principalId','-o','tsv')).Output
    Write-Host "[SUCCESS] Managed identity enabled for $WebAppName" -ForegroundColor Green
}

# Content Understanding — enable system-assigned managed identity so it can access Storage blobs
$CuIdentity = (Invoke-AzCliSilent -Arguments @('cognitiveservices','account','identity','show','--name',$ContentUnderstandingName,'--resource-group',$ResourceGroupName,'--query','principalId','-o','tsv')).Output
if ($CuIdentity) {
    Write-Host "[OK] Managed identity already enabled for $ContentUnderstandingName" -ForegroundColor Green
} else {
    Write-Host "[INFO] Enabling managed identity for $ContentUnderstandingName" -ForegroundColor Cyan
    Invoke-AzCliSilent -Arguments @('cognitiveservices','account','identity','assign','--name',$ContentUnderstandingName,'--resource-group',$ResourceGroupName,'--output','none') | Out-Null
    $CuIdentity = (Invoke-AzCliSilent -Arguments @('cognitiveservices','account','identity','show','--name',$ContentUnderstandingName,'--resource-group',$ResourceGroupName,'--query','principalId','-o','tsv')).Output
    if ($CuIdentity) {
        Write-Host "[SUCCESS] Managed identity enabled for $ContentUnderstandingName" -ForegroundColor Green
    } else {
        Write-Host "[WARNING] Could not enable managed identity on $ContentUnderstandingName. It may need Storage Blob Data Reader granted manually." -ForegroundColor Yellow
    }
}

if (-not $MailboxIdentity -or -not $QueueDbIdentity -or -not $WebAppIdentity) {
    Write-Host "[ERROR] Failed to retrieve managed identity principal IDs. Cannot assign RBAC." -ForegroundColor Red
    exit 1
}

$newAssignments = 0

# Key Vault access (RBAC)
$KeyVaultId = (Invoke-AzCliSilent -Arguments @('keyvault','show','--name',$KeyVaultName,'--resource-group',$ResourceGroupName,'--query','id','-o','tsv')).Output
if (-not $KeyVaultId) {
    Write-Host "[ERROR] Could not retrieve Key Vault resource ID for '$KeyVaultName'. RBAC assignments for Key Vault will be skipped." -ForegroundColor Red
    $script:DeploymentErrors.Add("Key Vault RBAC: could not retrieve resource ID for $KeyVaultName")
} else {
    Write-Host "[INFO] Key Vault Secrets User role for function apps and web app" -ForegroundColor Cyan
    foreach ($identity in @($MailboxIdentity, $QueueDbIdentity, $WebAppIdentity)) {
        if (-not (Ensure-RoleAssignment -Assignee $identity -Role 'Key Vault Secrets User' -Scope $KeyVaultId)) { $newAssignments++ }
    }
}

# Service Bus access
$ServiceBusId = (Invoke-AzCliSilent -Arguments @('servicebus','namespace','show','--name',$ServiceBusNamespace,'--resource-group',$ResourceGroupName,'--query','id','-o','tsv')).Output

Write-Host "[INFO] Service Bus roles for function apps" -ForegroundColor Cyan
if (-not (Ensure-RoleAssignment -Assignee $MailboxIdentity -Role 'Azure Service Bus Data Sender' -Scope $ServiceBusId)) { $newAssignments++ }
if (-not (Ensure-RoleAssignment -Assignee $QueueDbIdentity -Role 'Azure Service Bus Data Receiver' -Scope $ServiceBusId)) { $newAssignments++ }

# Storage account access (managed identity for AzureWebJobsStorage)
$StorageAccountId = (Invoke-AzCliSilent -Arguments @('storage','account','show','--name',$StorageAccountName,'--resource-group',$ResourceGroupName,'--query','id','-o','tsv')).Output

Write-Host "[INFO] Storage account roles for function apps" -ForegroundColor Cyan
foreach ($identity in @($MailboxIdentity, $QueueDbIdentity)) {
    foreach ($role in @('Storage Blob Data Owner','Storage Account Contributor','Storage Queue Data Contributor','Storage Table Data Contributor')) {
        if (-not (Ensure-RoleAssignment -Assignee $identity -Role $role -Scope $StorageAccountId)) { $newAssignments++ }
    }
}

# Admin user needs blob access for container creation and direct blob operations
if ($CurrentUserId) {
    Write-Host "[INFO] Storage Blob Data Contributor for admin user" -ForegroundColor Cyan
    if (-not (Ensure-RoleAssignment -Assignee $CurrentUserId -Role 'Storage Blob Data Contributor' -Scope $StorageAccountId)) { $newAssignments++ }
}

# Content Understanding needs to read blobs from Storage when given a blob URL
if ($CuIdentity) {
    Write-Host "[INFO] Storage Blob Data Reader for Content Understanding" -ForegroundColor Cyan
    if (-not (Ensure-RoleAssignment -Assignee $CuIdentity -Role 'Storage Blob Data Reader' -Scope $StorageAccountId)) { $newAssignments++ }
}

# Cosmos DB access (data plane RBAC - Built-in Data Contributor)
$CosmosDbAccountId = (Invoke-AzCliSilent -Arguments @('cosmosdb','show','--name',$CosmosDbAccountName,'--resource-group',$ResourceGroupName,'--query','id','-o','tsv')).Output
$CosmosDataContributorRoleId = "00000000-0000-0000-0000-000000000002"

Write-Host "[INFO] Cosmos DB Data Contributor role for function apps and web app" -ForegroundColor Cyan
foreach ($identity in @($MailboxIdentity, $QueueDbIdentity, $WebAppIdentity)) {
    if (-not (Ensure-CosmosRoleAssignment -AccountName $CosmosDbAccountName -ResourceGroup $ResourceGroupName -RoleDefinitionId $CosmosDataContributorRoleId -PrincipalId $identity -Scope $CosmosDbAccountId)) { $newAssignments++ }
}

# Content Understanding access (Cognitive Services User)
$ContentUnderstandingId = (Invoke-AzCliSilent -Arguments @('cognitiveservices','account','show','--name',$ContentUnderstandingName,'--resource-group',$ResourceGroupName,'--query','id','-o','tsv')).Output

Write-Host "[INFO] Cognitive Services User role for function apps and web app" -ForegroundColor Cyan
foreach ($identity in @($MailboxIdentity, $QueueDbIdentity, $WebAppIdentity)) {
    if (-not (Ensure-RoleAssignment -Assignee $identity -Role 'Cognitive Services User' -Scope $ContentUnderstandingId)) { $newAssignments++ }
}

# AI Foundry access (Cognitive Services OpenAI User)
$AiFoundryId = (Invoke-AzCliSilent -Arguments @('cognitiveservices','account','show','--name',$AiFoundryName,'--resource-group',$ResourceGroupName,'--query','id','-o','tsv')).Output

Write-Host "[INFO] Cognitive Services OpenAI User role for function apps and web app" -ForegroundColor Cyan
foreach ($identity in @($MailboxIdentity, $QueueDbIdentity, $WebAppIdentity)) {
    if (-not (Ensure-RoleAssignment -Assignee $identity -Role 'Cognitive Services OpenAI User' -Scope $AiFoundryId)) { $newAssignments++ }
}

if ($newAssignments -gt 0) {
    Write-Host "[SUCCESS] $newAssignments new RBAC assignment(s) created" -ForegroundColor Green
} else {
    Write-Host "[OK] All RBAC assignments already in place" -ForegroundColor Green
}

# =============================================================================
# Wait for identity propagation (only if new assignments were made)
# =============================================================================
if ($newAssignments -gt 0) {
    Write-Host ""
    Write-Host "[INFO] Waiting 30 seconds for RBAC propagation..." -ForegroundColor Cyan
    Start-Sleep -Seconds 30
} else {
    Write-Host "[OK] Skipping propagation wait (no new assignments)" -ForegroundColor Green
}

# =============================================================================
# Store Secrets in Key Vault
# =============================================================================
Write-Host "[INFO] Storing configuration secrets in Key Vault..." -ForegroundColor Cyan

# Validate Key Vault RBAC access before writing secrets
Write-Host "[INFO] Validating Key Vault write access..." -ForegroundColor Cyan

# Recover or purge any soft-deleted test secret from a previous run
$purgeResult = Invoke-AzCliSilent -Arguments @('keyvault','secret','recover','--vault-name',$KeyVaultName,'--name','deployment-test')
if ($purgeResult.ExitCode -ne 0) {
    # Recovery failed (secret may not exist in deleted state) — try purge instead
    Invoke-AzCliSilent -Arguments @('keyvault','secret','purge','--vault-name',$KeyVaultName,'--name','deployment-test') | Out-Null
}

$maxRetries = 12
$retryDelay = 10
$kvReady = $false
for ($i = 1; $i -le $maxRetries; $i++) {
    # Capture stderr via temp file so we always get the real error message
    $stderrFile = [System.IO.Path]::GetTempFileName()
    try {
        $prevPref = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'
        $null = & az keyvault secret set --vault-name $KeyVaultName --name 'deployment-test' --value 'ok' --output none 2>$stderrFile
        $setExitCode = $LASTEXITCODE
        $ErrorActionPreference = $prevPref
        $stderrContent = ''
        if (Test-Path $stderrFile) {
            $raw = Get-Content $stderrFile -Raw
            if ($raw) { $stderrContent = $raw.Trim() }
        }
    } finally {
        Remove-Item $stderrFile -Force -ErrorAction SilentlyContinue
    }
    if ($setExitCode -eq 0) {
        $kvReady = $true
        Write-Host "[SUCCESS] Key Vault write access confirmed" -ForegroundColor Green
        break
    }
    Write-Host "[INFO] Key Vault not ready yet (attempt $i/$maxRetries). Waiting $retryDelay seconds..." -ForegroundColor Cyan
    if ($stderrContent) { Write-Host "  Reason: $stderrContent" -ForegroundColor Yellow }
    Start-Sleep -Seconds $retryDelay
}
if (-not $kvReady) {
    Write-Host "[ERROR] Cannot write to Key Vault $KeyVaultName after $maxRetries attempts." -ForegroundColor Red
    Write-Host "[ERROR] Ensure your account has 'Key Vault Administrator' or 'Key Vault Secrets Officer' role on the vault." -ForegroundColor Red
    Write-Host "[ERROR] Current user: $CurrentUserId" -ForegroundColor Red
    Write-Host "[ERROR] Key Vault ID: $KeyVaultId" -ForegroundColor Red
    Write-Host "[ERROR] You can assign it manually with:" -ForegroundColor Red
    Write-Host "  az role assignment create --assignee $CurrentUserId --role 'Key Vault Administrator' --scope $KeyVaultId" -ForegroundColor Yellow
    exit 1
}

$SbConn      = (Invoke-AzCliSilent -Arguments @('servicebus','namespace','authorization-rule','keys','list','--namespace-name',$ServiceBusNamespace,'--resource-group',$ResourceGroupName,'--name','RootManageSharedAccessKey','--query','primaryConnectionString','-o','tsv')).Output
$KvUrl       = "https://$KeyVaultName.vault.azure.net/"
$SbUrl       = "https://$ServiceBusNamespace.servicebus.windows.net/"
$CosmosDbEndpoint = (Invoke-AzCliSilent -Arguments @('cosmosdb','show','--name',$CosmosDbAccountName,'--resource-group',$ResourceGroupName,'--query','documentEndpoint','-o','tsv')).Output
$ContentUnderstandingEndpoint = (Invoke-AzCliSilent -Arguments @('cognitiveservices','account','show','--name',$ContentUnderstandingName,'--resource-group',$ResourceGroupName,'--query','properties.endpoint','-o','tsv')).Output
$AiFoundryEndpoint = (Invoke-AzCliSilent -Arguments @('cognitiveservices','account','show','--name',$AiFoundryName,'--resource-group',$ResourceGroupName,'--query','properties.endpoint','-o','tsv')).Output

$MailboxPollingSchedule = if ($env:MAILBOX_POLLING_SCHEDULE) { $env:MAILBOX_POLLING_SCHEDULE } else { "0 */5 * * * *" }

$kvSecrets = @{
    "ServiceBusConnectionString" = $SbConn
    "MailboxPollingSchedule"     = $MailboxPollingSchedule
    "KeyVaultUrl"                = $KvUrl
    "ServiceBusUrl"              = $SbUrl
    "ServiceBusTopicName"        = $ServiceBusTopicName
    "ServiceBusSubscriptionName" = $ServiceBusSubName
    "GraphClientId"              = $GraphClientId
    "GraphClientSecret"          = $GraphClientSecret
    "GraphTenantId"              = $TenantId
    "MailboxFunctionAppName"     = $FuncMailboxName
    "QueueDbFunctionAppName"     = $FuncQueueDbName
    "CosmosDbEndpoint"           = $CosmosDbEndpoint
    "CosmosDbDatabaseName"       = $CosmosDbDatabaseName
    "CosmosDbContainerName"               = $CosmosDbContainerName
    "ContentUnderstandingEndpoint"          = $ContentUnderstandingEndpoint
    "ContentUnderstandingCompletionModel"     = $CuCompletionModelName
    "AiFoundryEndpoint"                     = $AiFoundryEndpoint
    "AiFoundryDeploymentName"               = $AiFoundryDeploymentName
    "AiFoundryModelName"                    = $AiFoundryModelName
    "AiFoundryApiVersion"                   = $AiFoundryApiVersion
    "StorageEndpoint"                       = $StorageBlobEndpoint
    "StorageContainerName"                  = $StorageContainerName
}
foreach ($entry in $kvSecrets.GetEnumerator()) {
    if (-not $entry.Value) {
        Write-Host "[WARNING] Skipping Key Vault secret '$($entry.Key)' - value is empty" -ForegroundColor Yellow
        continue
    }
    $r = Invoke-AzCliSilent -Arguments @('keyvault','secret','set','--vault-name',$KeyVaultName,'--name',$entry.Key,'--value',$entry.Value,'--output','none')
    if ($r.ExitCode -ne 0) {
        Write-Host "[ERROR] Failed to set Key Vault secret: $($entry.Key)" -ForegroundColor Red
        if ($r.Error) { Write-Host "  $($r.Error)" -ForegroundColor Red }
        $script:DeploymentErrors.Add("Key Vault secret: $($entry.Key)")
    }
}

if ($script:DeploymentErrors.Count -eq 0) {
    Write-Host "[SUCCESS] Secrets stored in Key Vault" -ForegroundColor Green
} else {
    Write-Host "[WARNING] Some secrets failed to store in Key Vault" -ForegroundColor Yellow
}

# =============================================================================
# Configure Function App Settings
# =============================================================================
Write-Host "[INFO] Configuring Function App settings..." -ForegroundColor Cyan

# Remove the auto-set AzureWebJobsStorage connection string and switch to identity-based storage
Write-Host "[INFO] Switching function apps to identity-based storage access" -ForegroundColor Cyan
Invoke-AzCliSilent -Arguments @('functionapp','config','appsettings','delete','--name',$FuncMailboxName,'--resource-group',$ResourceGroupName,'--setting-names','AzureWebJobsStorage','--output','none') | Out-Null
Invoke-AzCliSilent -Arguments @('functionapp','config','appsettings','delete','--name',$FuncQueueDbName,'--resource-group',$ResourceGroupName,'--setting-names','AzureWebJobsStorage','--output','none') | Out-Null

# Note: FUNCTIONS_WORKER_RUNTIME and FUNCTIONS_EXTENSION_VERSION are managed by the platform
# on Flex Consumption plans and must NOT be set as app settings.
$mailboxSettings = @{
    "AzureWebJobsStorage__accountName" = $StorageAccountName
    "AZURE_KEY_VAULT_URL"              = $KvUrl
    "MailboxPollingSchedule"           = "@Microsoft.KeyVault(VaultName=$KeyVaultName;SecretName=MailboxPollingSchedule)"
}
$r1 = Set-FunctionAppSettings -FunctionAppName $FuncMailboxName -ResourceGroup $ResourceGroupName -Settings $mailboxSettings
if ($r1.ExitCode -ne 0) {
    Write-Host "[ERROR] Failed to configure settings for $FuncMailboxName" -ForegroundColor Red
    if ($r1.Error) { Write-Host "  $($r1.Error)" -ForegroundColor Red }
    $script:DeploymentErrors.Add("Function app settings: $FuncMailboxName")
}

$ServiceBusHostname = "$ServiceBusNamespace.servicebus.windows.net"
$queueDbSettings = @{
    "AzureWebJobsStorage__accountName"          = $StorageAccountName
    "AZURE_KEY_VAULT_URL"                       = $KvUrl
    # Identity-based Service Bus connection for the @ServiceBusTopicTrigger binding
    "ServiceBusConnection__fullyQualifiedNamespace" = $ServiceBusHostname
    # Binding expressions used in the @ServiceBusTopicTrigger annotation
    "ServiceBusTopicName"                       = $ServiceBusTopicName
    "ServiceBusSubscriptionName"                = $ServiceBusSubName
}
$r2 = Set-FunctionAppSettings -FunctionAppName $FuncQueueDbName -ResourceGroup $ResourceGroupName -Settings $queueDbSettings
if ($r2.ExitCode -ne 0) {
    Write-Host "[ERROR] Failed to configure settings for $FuncQueueDbName" -ForegroundColor Red
    if ($r2.Error) { Write-Host "  $($r2.Error)" -ForegroundColor Red }
    $script:DeploymentErrors.Add("Function app settings: $FuncQueueDbName")
}

Write-Host "[SUCCESS] Function App settings configured" -ForegroundColor Green

# =============================================================================
# Configure Web App Settings
# =============================================================================
Write-Host "[INFO] Configuring Web App settings..." -ForegroundColor Cyan

$webAppSettingsPayload = @{
    properties = @{
        "AZURE_KEY_VAULT_URL"      = $KvUrl
    }
} | ConvertTo-Json -Compress

$webAppSettingsTempFile = [System.IO.Path]::GetTempFileName()
$webAppSettingsPayload | Set-Content -Path $webAppSettingsTempFile -Encoding UTF8

$webAppResourceId = (Invoke-AzCliSilent -Arguments @('webapp','show','--name',$WebAppName,'--resource-group',$ResourceGroupName,'--query','id','-o','tsv')).Output
$r3 = Invoke-AzCliSilent -Arguments @('rest','--method','PUT',
    '--url',"https://management.azure.com$webAppResourceId/config/appsettings?api-version=2023-01-01",
    '--body',"`@$webAppSettingsTempFile",
    '--output','none')
Remove-Item $webAppSettingsTempFile -ErrorAction SilentlyContinue

if ($r3.ExitCode -ne 0) {
    Write-Host "[ERROR] Failed to configure settings for web app $WebAppName" -ForegroundColor Red
    $script:DeploymentErrors.Add("Web app settings: $WebAppName")
} else {
    Write-Host "[SUCCESS] Web App settings configured" -ForegroundColor Green
}

# =============================================================================
# SUMMARY
# =============================================================================
Write-Host ""
if ($script:DeploymentErrors.Count -gt 0) {
    Write-Host "[FAILED] ==========================================" -ForegroundColor Red
    Write-Host "[FAILED] Infrastructure deployment completed with $($script:DeploymentErrors.Count) error(s)!" -ForegroundColor Red
    Write-Host "[FAILED] ==========================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Failed operations:" -ForegroundColor Red
    foreach ($err in $script:DeploymentErrors) {
        Write-Host "    - $err" -ForegroundColor Red
    }
    Write-Host ""
    Write-Host "  Resource Group      : $ResourceGroupName"
    Write-Host "  Key Vault           : $KeyVaultName"
    Write-Host "  Storage Account     : $StorageAccountName"
    Write-Host "  Service Bus NS      : $ServiceBusNamespace"
    Write-Host "  Service Bus Topic   : $ServiceBusTopicName"
    Write-Host "  Cosmos DB Account   : $CosmosDbAccountName"
    Write-Host "  Cosmos DB Database  : $CosmosDbDatabaseName"
    Write-Host "  App Service Plan    : $AppServicePlanName"
    Write-Host "  Web App             : $WebAppName"
    Write-Host "  Function (Mailbox)  : $FuncMailboxName"
    Write-Host "  Function (Queue-DB) : $FuncQueueDbName"
    Write-Host "  Graph API App ID    : $GraphClientId"
    Write-Host "  Content Understanding: $ContentUnderstandingName"
    Write-Host "  AI Foundry          : $AiFoundryName"
    Write-Host "  AI Foundry Model    : $AiFoundryDeploymentName"
    Write-Host "  App Insights        : $AppInsightsName"
    Write-Host "[FAILED] ==========================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "[INFO] Fix the errors above and re-run the script. It is idempotent and will skip already-created resources." -ForegroundColor Cyan
    exit 1
} else {
    Write-Host "[SUCCESS] ==========================================" -ForegroundColor Green
    Write-Host "[SUCCESS] Infrastructure deployment completed!"       -ForegroundColor Green
    Write-Host "[SUCCESS] ==========================================" -ForegroundColor Green
    Write-Host "  Resource Group      : $ResourceGroupName"
    Write-Host "  Key Vault           : $KeyVaultName"
    Write-Host "  Storage Account     : $StorageAccountName"
    Write-Host "  Service Bus NS      : $ServiceBusNamespace"
    Write-Host "  Service Bus Topic   : $ServiceBusTopicName"
    Write-Host "  Cosmos DB Account   : $CosmosDbAccountName"
    Write-Host "  Cosmos DB Database  : $CosmosDbDatabaseName"
    Write-Host "  App Service Plan    : $AppServicePlanName"
    Write-Host "  Web App             : $WebAppName"
    Write-Host "  Function (Mailbox)  : $FuncMailboxName"
    Write-Host "  Function (Queue-DB) : $FuncQueueDbName"
    Write-Host "  Graph API App ID    : $GraphClientId"
    Write-Host "  Content Understanding: $ContentUnderstandingName"
    Write-Host "  AI Foundry          : $AiFoundryName"
    Write-Host "  AI Foundry Model    : $AiFoundryDeploymentName"
    Write-Host "  App Insights        : $AppInsightsName"
    Write-Host "[SUCCESS] ==========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "[INFO] Next Steps:" -ForegroundColor Cyan
    Write-Host "  1. Grant Graph API admin consent:  .\grant-graph-consent.ps1 -Suffix $Suffix"
    Write-Host "  2. Deploy your function code to the created function apps"
    Write-Host "  3. Deploy your Spring Boot JAR/WAR to the web app: $WebAppName"
    Write-Host "  4. Test the deployment with sample data"
}

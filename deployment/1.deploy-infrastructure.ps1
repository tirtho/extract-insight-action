#Requires -Version 5.1
<#
.SYNOPSIS
    Azure Infrastructure Deployment Script for extract-insight-action
.DESCRIPTION
    Creates all necessary Azure resources. Idempotent - can be run multiple times safely.
.PARAMETER Environment
    Optional. Environment name (default: dev).
.PARAMETER Suffix
    Optional. A short suffix (default: 1) appended to globally-unique resource names.
.USAGE
    .\deploy-infrastructure.ps1 -Suffix 999
    .\deploy-infrastructure.ps1 -Environment dev -Suffix 999
#>
param(
    [Parameter(HelpMessage="Environment (default: dev, example: dev)")]
    [string]$Environment,

    [Parameter(HelpMessage="Suffix for globally-unique resource names (default: 1, example: 1)")]
    [string]$Suffix
)

$ErrorActionPreference = "Stop"

# =============================================================================
# INPUTS (no config file dependency)
# =============================================================================
$ProjectName = "eia"

$locationInput = Read-Host "Enter location [default: centralus, example: centralus]"
$Location = if ([string]::IsNullOrWhiteSpace($locationInput)) {
    "centralus"
} else {
    $locationInput.Trim().ToLowerInvariant()
}

if ([string]::IsNullOrWhiteSpace($Environment)) {
    $environmentInput = Read-Host "Enter environment [default: dev, example: dev]"
    $Environment = if ([string]::IsNullOrWhiteSpace($environmentInput)) {
        "dev"
    } else {
        $environmentInput.Trim().ToLowerInvariant()
    }
} else {
    $Environment = $Environment.Trim().ToLowerInvariant()
}

if ([string]::IsNullOrWhiteSpace($Suffix)) {
    $suffixInput = Read-Host "Enter suffix [default: 1, example: 1]"
    $Suffix = if ([string]::IsNullOrWhiteSpace($suffixInput)) { "1" } else { $suffixInput.Trim() }
} else {
    $Suffix = $Suffix.Trim()
}

$signedInIdentity = (az account show --query user.name -o tsv 2>$null)
$tenantFqdn = if ($signedInIdentity -match '@(.+)$') {
    $Matches[1].ToLowerInvariant()
} elseif ($env:USERDNSDOMAIN) {
    $env:USERDNSDOMAIN.Trim().ToLowerInvariant()
} else {
    "contoso.onmicrosoft.com"
}

$userNamePartInput = Read-Host "Enter user email name part [default: fsi-demo, example: fsi-demo]"
$userNamePart = if ([string]::IsNullOrWhiteSpace($userNamePartInput)) {
    "fsi-demo"
} else {
    ($userNamePartInput.Trim().ToLowerInvariant() -replace '[^a-z0-9._-]', '')
}
if ([string]::IsNullOrWhiteSpace($userNamePart)) {
    $userNamePart = "fsi-demo"
}
$UserEmailAddress = "$userNamePart@$tenantFqdn"

$contentUnderstandingLocationInput = Read-Host "Enter Content Understanding deployment region [default: $Location, example: eastus]"
$ContentUnderstandingRequestedLocation = if ([string]::IsNullOrWhiteSpace($contentUnderstandingLocationInput)) {
    $Location
} else {
    $contentUnderstandingLocationInput.Trim().ToLowerInvariant()
}

Write-Host "[INFO] Deployment key: $ProjectName-$Environment-$Suffix" -ForegroundColor Cyan
Write-Host "[INFO] User email    : $UserEmailAddress" -ForegroundColor Cyan
Write-Host "[INFO] Content Understanding region: $ContentUnderstandingRequestedLocation" -ForegroundColor Cyan

# Derived: SUFFIX / KEY_VAULT_NAME / AZURE_KEY_VAULT_URL exported for downstream scripts.
# Also write env.bat at the repo root so cmd-based tools can pick up AZURE_KEY_VAULT_URL.
[System.Environment]::SetEnvironmentVariable('PROJECT_NAME', $ProjectName, 'Process')
[System.Environment]::SetEnvironmentVariable('ENVIRONMENT', $Environment, 'Process')
[System.Environment]::SetEnvironmentVariable('LOCATION', $Location, 'Process')
[System.Environment]::SetEnvironmentVariable('USER_EMAIL_ADDRESS', $UserEmailAddress, 'Process')
[System.Environment]::SetEnvironmentVariable('SUFFIX', $Suffix, 'Process')
$env:PROJECT_NAME          = $ProjectName
$env:ENVIRONMENT           = $Environment
$env:LOCATION              = $Location
$env:USER_EMAIL_ADDRESS    = $UserEmailAddress
$env:SUFFIX                = $Suffix
$env:KEY_VAULT_NAME        = "kv-$ProjectName-$Environment-$Suffix"
$env:AZURE_KEY_VAULT_URL   = "https://$($env:KEY_VAULT_NAME).vault.azure.net"
[System.Environment]::SetEnvironmentVariable('KEY_VAULT_NAME',       $env:KEY_VAULT_NAME,       'Process')
[System.Environment]::SetEnvironmentVariable('AZURE_KEY_VAULT_URL',  $env:AZURE_KEY_VAULT_URL,  'Process')

$envBatPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'env.bat'
$envBatContent = "@echo off`r`nset AZURE_KEY_VAULT_URL=$($env:AZURE_KEY_VAULT_URL)"
try {
    Set-Content -Path $envBatPath -Value $envBatContent -Encoding ASCII -Force
    Write-Host "[INFO] Wrote $envBatPath" -ForegroundColor Cyan
} catch {
    Write-Host "[WARNING] Could not write $envBatPath : $_" -ForegroundColor Yellow
}

# Get subscription/tenant from Azure CLI
$SubscriptionId = (az account show --query id -o tsv)
$TenantId       = (az account show --query tenantId -o tsv)

# Resource names (derived from eia-environment-suffix)
$ResourceGroupName    = "rg-$ProjectName-$Environment-$Suffix"
$KeyVaultName         = "kv-$ProjectName-$Environment-$Suffix"
$ServiceBusNamespace  = "sb-$ProjectName-$Environment-$Suffix"
$ProjClean            = ($ProjectName.ToLowerInvariant()) -replace '[^a-z0-9]',''
$EnvironmentCleanForStorage = ($Environment.ToLowerInvariant()) -replace '[^a-z0-9]',''
$SuffixCleanForStorage      = ($Suffix.ToLowerInvariant()) -replace '[^a-z0-9]',''
$DefaultStorageAccountName  = "st$ProjClean$EnvironmentCleanForStorage$SuffixCleanForStorage"
$StorageAccountName   = $DefaultStorageAccountName

if ($StorageAccountName.Length -lt 3 -or $StorageAccountName.Length -gt 24 -or $StorageAccountName -notmatch '^[a-z0-9]+$') {
    Write-Host "[ERROR] Invalid storage account name '$StorageAccountName'." -ForegroundColor Red
    Write-Host "        Storage account names must be 3-24 chars and contain only lowercase letters and digits." -ForegroundColor Red
    Write-Host "        Suggested value: $DefaultStorageAccountName" -ForegroundColor Red
    exit 1
}
$FuncMailboxName      = "func-mailbox-$ProjectName-$Environment-$Suffix"
$FuncQueueDbName      = "func-queuedb-$ProjectName-$Environment-$Suffix"
$FuncCuQueueDbName    = "func-cuqueuedb-$ProjectName-$Environment-$Suffix"
$ServiceBusTopicName  = "email-processing"
$ServiceBusSubName    = "email-processor"
$GraphAppName         = "$ProjectName-graph-api-$Environment"
$GraphClientId        = $env:GRAPH_CLIENT_ID
$GraphClientSecret    = $env:GRAPH_CLIENT_SECRET
$WebAppAuthAppName    = "$ProjectName-webapp-auth-$Environment"
$WebAppClientId       = $env:WEBAPP_CLIENT_ID
$WebAppClientSecret   = $env:WEBAPP_CLIENT_SECRET
$AppInsightsName      = "ai-$ProjectName-$Environment"
$CosmosDbAccountName  = "cosmos-$ProjectName-$Environment-$Suffix"
$StorageQueueName     = "cu-analyze-ops-$ProjectName-$Environment-$Suffix"
$StorageQueuePollingSchedule = "0 */1 * * * *"

# Mailbox application configuration (folded in from 4.kv-settings-for-applications.ps1).
# UserEmailAddress is required for the application to function; the deployment
# will halt early if it is not provided.
$UserEmailAddress = $env:USER_EMAIL_ADDRESS
$PollingMailboxName = "Inbox"
$ReadMailboxForPastNSeconds = "3600"
$CosmosDbDatabaseName = "DocAIDatabase"
$CosmosDbContainerName = "EmailExtracts"
# Must match the output dimensions of the embeddings model in deploy-models.csv.
$CosmosDbVectorDimensions = 1536
$AppServicePlanName   = "plan-$ProjectName-$Environment"
$WebAppName           = "app-$ProjectName-$Environment-$Suffix"

# Multi-agent orchestration framework (agent-service) — isolated VNet + Flex Consumption
# function app, separate from the extract/functions/* apps (see MULTIAGENT_FRAMEWORK_DESIGN.md).
$FuncAgentServiceName        = "func-agentservice-$ProjectName-$Environment-$Suffix"
$AgentServiceApiAppName      = "$ProjectName-agent-service-api-$Environment-$Suffix"
$AgentServiceVNetName        = "vnet-agentservice-$ProjectName-$Environment-$Suffix"
$AgentServiceSubnetName      = "snet-agentservice"
$AgentServiceVNetAddressSpace   = "10.100.0.0/24"
$AgentServiceSubnetAddressSpace = "10.100.0.0/24"
# Defaults written to Key Vault so OrchestratorAgent.fromKeyVault() works before
# 3.deploy-agents.ps1 provisions the orchestrator/jury agents; matches MultiAgentConfig's
# fallback values and AgentProvisioning's DEFAULT_AGENT_NAME constants.
$MultiAgentOrchestratorAgentName = "MultiAgentOrchestrator"
$MultiAgentJuryAgentName         = "MultiAgentJury"
$MultiAgentJuryTieMargin         = "0.10"
$MultiAgentJuryMinDispatchScore  = "0.6"
$MultiAgentJuryMaxCandidates     = "3"
$MultiAgentTaskMaxRetries        = "3"
$MultiAgentTaskMaxTotalCalls     = "6"
$MultiAgentAsyncStateTtlDays     = "3"

$ContentUnderstandingName = "cu-$ProjectName-$Environment-$Suffix"
$AiFoundryName            = "oai-$ProjectName-$Environment-$Suffix"
$AiFoundryProjectName     = "proj-$ProjectName-$Environment-$Suffix"
$AiFoundryProjectApiVersion = "2025-04-01-preview"
$AiFoundryApiVersion      = "2024-12-01-preview"
$AiFoundrySkuName         = "GlobalStandard"
# SKU Capacity is now dynamically calculated based on available quota (see Get-AvailableCapacity function)
# Exempts resources from the governance policies that would otherwise disable public network access.
# Hardening is applied later by 5.deploy-code-secure-window.ps1.
$SecurityControlTag       = "SecurityControl=Ignore"
$DeployModelsCsvPath      = Join-Path $PSScriptRoot "deploy-models.csv"

# The "primary" model used by the Java app (deployment name stored in Key Vault).
# Defaults are derived from deploy-models.csv at runtime (see Step 9).
# These initial values are fallbacks if the CSV is missing or contains no LLM entries.
$AiFoundryDeploymentName  = "gpt-5.1-chat"
$AiFoundryModelName       = "gpt-5.1-chat"

# AI Foundry embeddings model for vector search on emails and attachments.
# Defaults are derived from deploy-models.csv at runtime (see Step 9).
# These initial values are fallbacks if the CSV is missing or contains no embeddings entries.
$AiFoundryEmbeddingsDeploymentName = "text-embedding-3-small"
$AiFoundryEmbeddingsModelName      = "text-embedding-3-small"
$AiFoundryEmbeddingsModelVersion   = "1"
$AiFoundryEmbeddingsSkuCapacity    = "50"

# Content Understanding requires a supported completion model (separate from the main LLM deployment).
# Supported: gpt-4o, gpt-4o-mini, gpt-4.1, gpt-4.1-mini, gpt-4.1-nano, gpt-5.2
$CuCompletionDeploymentName = "gpt-5.2"
$CuCompletionModelName      = "gpt-5.2"
$CuCompletionModelVersion   = ""
$CuCompletionSkuCapacity    = "50"
$CuEmbeddingDeploymentName  = "text-embedding-3-small"
$CuEmbeddingModelName       = "text-embedding-3-small"
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

# Verify USER_EMAIL_ADDRESS is set (required for mailbox polling)
if (-not $UserEmailAddress) {
    Write-Host "[ERROR] USER_EMAIL_ADDRESS environment variable is not set." -ForegroundColor Red
    Write-Host "        Set it (e.g. \$env:USER_EMAIL_ADDRESS = 'user@contoso.com') and re-run." -ForegroundColor Red
    exit 1
}
Write-Host "[INFO] USER_EMAIL_ADDRESS = $UserEmailAddress" -ForegroundColor Cyan

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

# Returns $true if the role assignment was already in place.
# Pass -PrincipalType 'ServicePrincipal' (or 'User') for managed identities/users
# to use --assignee-object-id and bypass the graph.microsoft.com lookup that can
# time out on restricted networks.
function Set-RoleAssignment {
    param(
        [string]$Assignee,
        [string]$Role,
        [string]$Scope,
        [string]$PrincipalType = ''
    )
    if (-not $Scope) {
        Write-Host "[ERROR] Set-RoleAssignment: Scope is empty for role '$Role' on assignee '$Assignee'" -ForegroundColor Red
        $script:DeploymentErrors.Add("RBAC: '$Role' for '$Assignee' - empty scope")
        return $false
    }
    $existing = Invoke-AzCliSilent -Arguments @('role','assignment','list','--assignee',$Assignee,'--role',$Role,'--scope',$Scope,'--query','[0].id','-o','tsv')
    if ($existing.ExitCode -eq 0 -and $existing.Output) {
        return $true  # already exists
    }
    if ($PrincipalType) {
        $createArgs = @('role','assignment','create',
            '--assignee-object-id',$Assignee,
            '--assignee-principal-type',$PrincipalType,
            '--role',$Role,'--scope',$Scope,'--output','none')
    } else {
        $createArgs = @('role','assignment','create','--assignee',$Assignee,'--role',$Role,'--scope',$Scope,'--output','none')
    }
    $result = Invoke-AzCliSilent -Arguments $createArgs
    if ($result.ExitCode -ne 0) {
        Write-Host "[ERROR] Failed to assign role '$Role' to '$Assignee' on scope '$Scope'" -ForegroundColor Red
        if ($result.Error)  { Write-Host "  $($result.Error)"  -ForegroundColor Red }
        if ($result.Output) { Write-Host "  $($result.Output)" -ForegroundColor Red }
        $script:DeploymentErrors.Add("RBAC: '$Role' for '$Assignee'")
    }
    return $false  # newly created (or failed - caller increments counter; errors logged above)
}

# Creates a custom role definition if it does not already exist.
# DataActions is a string array; AssignableScopes is a string array.
function Set-CustomRoleDefinition {
    param(
        [string]$RoleName,
        [string]$Description,
        [string[]]$DataActions,
        [string[]]$AssignableScopes
    )
    $existing = Get-CustomRoleDefinitionId -RoleName $RoleName
    if ($existing) {
        Write-Host "[OK] Custom role '$RoleName' already exists" -ForegroundColor Green
        return
    }
    Write-Host "[INFO] Creating custom role '$RoleName'" -ForegroundColor Cyan
    $roleObj = [ordered]@{
        Name             = $RoleName
        Description      = $Description
        Actions          = @()
        DataActions      = $DataActions
        AssignableScopes = $AssignableScopes
    }
    $roleJson = $roleObj | ConvertTo-Json -Depth 5
    $tmpFile  = Join-Path ([System.IO.Path]::GetTempPath()) "custom-role-$([guid]::NewGuid().ToString('N')).json"
    Set-Content -Path $tmpFile -Value $roleJson -Encoding UTF8
    $result = Invoke-AzCliSilent -Arguments @('role','definition','create','--role-definition',"@$tmpFile")
    Remove-Item $tmpFile -ErrorAction SilentlyContinue
    if ($result.ExitCode -ne 0) {
        if ($result.Error -match 'RoleDefinitionWithSameNameExists|same name already exists') {
            $existingAfterConflict = Get-CustomRoleDefinitionId -RoleName $RoleName
            if ($existingAfterConflict) {
                Write-Host "[OK] Custom role '$RoleName' already exists" -ForegroundColor Green
                return
            }
        }
        Write-Host "[ERROR] Failed to create custom role '$RoleName': $($result.Error)" -ForegroundColor Red
        $script:DeploymentErrors.Add("Custom role: '$RoleName'")
    } else {
        Write-Host "[SUCCESS] Custom role '$RoleName' created" -ForegroundColor Green
    }
}

function Get-CustomRoleDefinitionId {
    param([Parameter(Mandatory=$true)][string]$RoleName)

    $query = "[?roleName=='$RoleName' || name=='$RoleName'] | [0].id"
    $result = Invoke-AzCliSilent -Arguments @('role','definition','list',
        '--custom-role-only','true','--query',$query,'-o','tsv')
    if ($result.ExitCode -eq 0 -and $result.Output) { return $result.Output.Trim() }

    $fallback = Invoke-AzCliSilent -Arguments @('role','definition','list',
        '--name',$RoleName,'--query','[0].id','-o','tsv')
    if ($fallback.ExitCode -eq 0 -and $fallback.Output) { return $fallback.Output.Trim() }

    # Directory-wide custom roles may not appear under the current subscription.
    # Query the tenant-level endpoint and follow nextLink pagination.
    $nextUrl = "https://management.azure.com/providers/Microsoft.Authorization/roleDefinitions?api-version=2022-04-01"
    while ($nextUrl) {
        $rest = Invoke-AzCliSilent -Arguments @('rest','--method','GET','--url',$nextUrl,'-o','json')
        if ($rest.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($rest.Output)) { break }
        try {
            $page = $rest.Output | ConvertFrom-Json
            $definition = @($page.value) | Where-Object {
                [string]$_.properties.roleName -ieq $RoleName
            } | Select-Object -First 1
            if ($definition -and $definition.id) { return ([string]$definition.id).Trim() }
            $nextUrl = [string]$page.nextLink
            if ([string]::IsNullOrWhiteSpace($nextUrl)) { $nextUrl = $null }
        } catch {
            $nextUrl = $null
        }
    }
    return $null
}

# Returns $true if the Cosmos DB role assignment was already in place
function Set-CosmosRoleAssignment {
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

function Test-ContainsKeyVaultReferences {
    param([hashtable]$Settings)
    foreach ($entry in $Settings.GetEnumerator()) {
        if ($entry.Value -is [string] -and $entry.Value -match '^@Microsoft\.KeyVault\(') {
            return $true
        }
    }
    return $false
}

function Invoke-ConfigReferenceRefresh {
    param(
        [Parameter(Mandatory=$true)][string]$ResourceId,
        [Parameter(Mandatory=$true)][string]$DisplayName,
        [int]$MaxAttempts = 6,
        [int]$DelaySeconds = 10
    )

    $lastUnresolved = @()
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $refresh = Invoke-AzCliSilent -Arguments @(
            'rest','--method','POST',
            '--uri',"https://management.azure.com$ResourceId/config/configreferences/appsettings/refresh?api-version=2022-03-01",
            '-o','json'
        )

        if ($refresh.ExitCode -ne 0) {
            Write-Host "[WARNING] Key Vault reference refresh failed for $DisplayName (attempt $attempt/$MaxAttempts)" -ForegroundColor Yellow
            if ($refresh.Error) { Write-Host "  $($refresh.Error)" -ForegroundColor Yellow }
        } else {
            $lastUnresolved = @()
            try {
                $payload = $refresh.Output | ConvertFrom-Json
                if ($payload.value) {
                    $lastUnresolved = @($payload.value | Where-Object { $_.properties.status -ne 'Resolved' })
                }
            } catch {
                $lastUnresolved = @()
            }

            if ($lastUnresolved.Count -eq 0) {
                Write-Host "[SUCCESS] Key Vault references refreshed for $DisplayName" -ForegroundColor Green
                return $true
            }

            Write-Host "[INFO] $DisplayName still has unresolved Key Vault references (attempt $attempt/$MaxAttempts)" -ForegroundColor Cyan
            foreach ($item in $lastUnresolved) {
                Write-Host "  - $($item.name): $($item.properties.status)" -ForegroundColor Yellow
            }
        }

        if ($attempt -lt $MaxAttempts) {
            Start-Sleep -Seconds $DelaySeconds
        }
    }

    Write-Host "[WARNING] Key Vault references not fully resolved for $DisplayName after $MaxAttempts attempts" -ForegroundColor Yellow
    return $false
}

# Polls provisioningState of an ARM resource until Succeeded or timeout.
# Returns $true on success, $false on failure/timeout.
function Wait-ForArmResource {
    param(
        [string]$ResourceId,
        [string]$ApiVersion,
        [int]$MaxSeconds = 600,
        [int]$IntervalSeconds = 15,
        # When set, a 'failed' provisioningState is treated as transient and polling continues
        # for the full window. Use for AI Foundry project creation, which passes through a
        # transient 'failed' state before the async LRO settles to 'Succeeded'.
        [switch]$FailedIsTransient
    )
    $waited = 0
    while ($waited -lt $MaxSeconds) {
        $r = Invoke-AzCliSilent -Arguments @('resource','show','--ids',$ResourceId,'--api-version',$ApiVersion,'--query','properties.provisioningState','-o','tsv')
        $state = $r.Output.Trim().ToLower()
        switch ($state) {
            'succeeded' { return $true }
            { $_ -in 'canceled','deleting' } {
                Write-Host "[ERROR] Resource provisioningState = $state" -ForegroundColor Red
                return $false
            }
            'failed' {
                if ($FailedIsTransient) {
                    Write-Host "[INFO] provisioningState = 'failed' (may be transient), waited ${waited}s / ${MaxSeconds}s..." -ForegroundColor Cyan
                } else {
                    Write-Host "[ERROR] Resource provisioningState = $state" -ForegroundColor Red
                    return $false
                }
            }
            default {
                $displayState = if ($state) { $state } else { '(not yet visible)' }
                Write-Host "[INFO] provisioningState = '$displayState', waited ${waited}s / ${MaxSeconds}s..." -ForegroundColor Cyan
            }
        }
        Start-Sleep -Seconds $IntervalSeconds
        $waited += $IntervalSeconds
    }
    Write-Host "[ERROR] Timed out after ${MaxSeconds}s waiting for resource to reach Succeeded state" -ForegroundColor Red
    return $false
}

# =============================================================================
# LOCATION AVAILABILITY CHECK
# =============================================================================
$script:ServiceLocationCache = @{}

function Get-ServiceLocation {
    param(
        [Parameter(Mandatory=$true)][string]$ServiceName,
        [Parameter(Mandatory=$true)][string]$DefaultLocation,
        [switch]$AlwaysPrompt
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

            if ($AlwaysPrompt) {
                # Always present a numbered list and let the user choose
                Write-Host ""
                Write-Host "[INFO] Select a location for service '$ServiceName':" -ForegroundColor Cyan
                for ($i = 0; $i -lt $supportedLocations.Count; $i++) {
                    $marker = ""
                    if ($supportedLocations[$i] -eq $DefaultLocation.ToLower()) { $marker = " (default)" }
                    Write-Host ("  [{0}] {1}{2}" -f ($i+1), $supportedLocations[$i], $marker)
                }
                $defaultIndex = [Array]::IndexOf($supportedLocations, $DefaultLocation.ToLower())
                $defaultPromptIndex = if ($defaultIndex -ge 0) { $defaultIndex + 1 } else { 1 }
                do {
                    $userInput = Read-Host "Enter selection number [1-$($supportedLocations.Count)] (default: $defaultPromptIndex)"
                    if ([string]::IsNullOrWhiteSpace($userInput)) { $userInput = "$defaultPromptIndex" }
                    $valid = $false
                    if ($userInput -match '^\d+$') {
                        $idx = [int]$userInput
                        if ($idx -ge 1 -and $idx -le $supportedLocations.Count) { $valid = $true }
                    }
                    if (-not $valid) {
                        Write-Host "[ERROR] Invalid selection. Enter a number between 1 and $($supportedLocations.Count)." -ForegroundColor Red
                    }
                } while (-not $valid)

                $chosen = $supportedLocations[[int]$userInput - 1]
                $script:ServiceLocationCache[$ServiceName] = $chosen
                Write-Host "[INFO] Using location '$chosen' for $ServiceName" -ForegroundColor Cyan
                return $chosen
            }

            if ($supportedLocations -contains $DefaultLocation.ToLower()) {
                $script:ServiceLocationCache[$ServiceName] = $DefaultLocation
                return $DefaultLocation
            }
            # Location not supported - let the user choose from the supported
            # regions while preserving the early region-input flow.
            Write-Host "[WARNING] Location '$DefaultLocation' is not supported for service '$ServiceName'." -ForegroundColor Yellow
            Write-Host "[INFO] Supported locations: $($supportedLocations -join ', ')" -ForegroundColor Cyan
            for ($i = 0; $i -lt $supportedLocations.Count; $i++) {
                Write-Host ("  [{0}] {1}" -f ($i + 1), $supportedLocations[$i]) -ForegroundColor Cyan
            }
            do {
                $regionSelection = Read-Host "Select Content Understanding region [1-$($supportedLocations.Count)]"
                $validSelection = $regionSelection -match '^\d+$' -and
                    [int]$regionSelection -ge 1 -and
                    [int]$regionSelection -le $supportedLocations.Count
                if (-not $validSelection) {
                    Write-Host "[ERROR] Enter a number between 1 and $($supportedLocations.Count)." -ForegroundColor Red
                }
            } while (-not $validSelection)

            $chosenLocation = $supportedLocations[[int]$regionSelection - 1]
            $script:ServiceLocationCache[$ServiceName] = $chosenLocation
            Write-Host "[INFO] Using selected location '$chosenLocation' for $ServiceName" -ForegroundColor Cyan
            return $chosenLocation
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
$LocationContentUnderstanding = Get-ServiceLocation -ServiceName "contentunderstanding" -DefaultLocation $ContentUnderstandingRequestedLocation
$LocationAiFoundry            = Get-ServiceLocation -ServiceName "aifoundry"            -DefaultLocation $Location -AlwaysPrompt
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
                     '--tags',"project=$ProjectName","environment=$Environment",$SecurityControlTag,'--output','table')
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
                     '--tags',"project=$ProjectName","environment=$Environment",$SecurityControlTag,'--output','table')
    if ($null -ne $result) {
        Write-Host "[SUCCESS] Storage account $StorageAccountName created" -ForegroundColor Green
    }
}

# Governance policy can disable public network access on create, which blocks the
# data-plane calls below. Re-open it here; 5.deploy-code-secure-window.ps1 hardens it later.
Invoke-AzCliSilent -Arguments @('resource','tag','--tags',"project=$ProjectName","environment=$Environment",$SecurityControlTag,
                                '--name',$StorageAccountName,'--resource-group',$ResourceGroupName,
                                '--resource-type','Microsoft.Storage/storageAccounts','--is-incremental','--output','none') | Out-Null
Invoke-AzCliSilent -Arguments @('storage','account','update','--name',$StorageAccountName,'--resource-group',$ResourceGroupName,
                                '--public-network-access','Enabled','--bypass','AzureServices','--default-action','Allow',
                                '--output','none') | Out-Null

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

    # Get the table endpoint
    $StorageTableEndpoint = (Invoke-AzCliSilent -Arguments @('storage','account','show','--name',$StorageAccountName,'--resource-group',$ResourceGroupName,'--query','primaryEndpoints.table','-o','tsv')).Output
    Write-Host "[INFO] Storage table endpoint: $StorageTableEndpoint" -ForegroundColor Cyan

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

# Create the AgentSessions table (idempotent – skip if exists)
Write-Host "[INFO] Creating storage table: AgentSessions" -ForegroundColor Cyan
$existingTable = Invoke-AzCliSilent -Arguments @('storage','table','exists','--name','AgentSessions',
                     '--account-name',$StorageAccountName,'--auth-mode','login','--query','exists','-o','tsv')
if ($existingTable.ExitCode -eq 0 -and $existingTable.Output -eq 'true') {
    Write-Host "[WARNING] Storage table 'AgentSessions' already exists, skipping" -ForegroundColor Yellow
} else {
    $r = Invoke-AzCli -Description "Creating storage table: AgentSessions" `
        -Arguments @('storage','table','create','--name','AgentSessions',
                     '--account-name',$StorageAccountName,'--auth-mode','login','--output','none')
    if ($null -ne $r) {
        Write-Host "[SUCCESS] Storage table 'AgentSessions' created" -ForegroundColor Green
    }
}

# Create the storage queue (idempotent – skip if exists)
Write-Host "[INFO] Creating storage queue: $StorageQueueName" -ForegroundColor Cyan
$existingQueue = Invoke-AzCliSilent -Arguments @('storage','queue','show','--name',$StorageQueueName,'--account-name',$StorageAccountName,'--auth-mode','login','--query','name','-o','tsv')
if ($existingQueue.ExitCode -eq 0 -and $existingQueue.Output) {
    Write-Host "[WARNING] Storage queue '$StorageQueueName' already exists, skipping" -ForegroundColor Yellow
} else {
    $r = Invoke-AzCli -Description "Creating storage queue: $StorageQueueName" `
        -Arguments @('storage','queue','create','--name',$StorageQueueName,
                     '--account-name',$StorageAccountName,'--auth-mode','login','--output','none')
    if ($null -ne $r) {
        Write-Host "[SUCCESS] Storage queue '$StorageQueueName' created" -ForegroundColor Green
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
                     '--tags',"project=$ProjectName","environment=$Environment",$SecurityControlTag,'--output','table')
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
    $alreadyAssigned = Set-RoleAssignment -Assignee $CurrentUserId -Role 'Key Vault Administrator' -Scope $KeyVaultId
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
    # Azure AD replicates the new object asynchronously; poll until it appears.
    for ($i = 1; $i -le 12; $i++) {
        $GraphClientId = (Invoke-AzCliSilent -Arguments @('ad','app','list','--display-name',$GraphAppName,'--query','[0].appId','-o','tsv')).Output
        if ($GraphClientId) { break }
        Write-Host "[INFO] Waiting for app registration to propagate (attempt $i/12)..." -ForegroundColor Cyan
        Start-Sleep -Seconds 10
    }
    if ($GraphClientId) {
        Write-Host "[SUCCESS] App registration created with ID: $GraphClientId" -ForegroundColor Green
    } else {
        Write-Host "[ERROR] App registration $GraphAppName created but ID could not be retrieved after 2 minutes" -ForegroundColor Red
        $script:DeploymentErrors.Add("Graph API app registration: $GraphAppName")
    }
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

Write-Host "[INFO] Run .\2.grant-graph-consent.ps1 -Suffix $Suffix to grant admin consent (requires tenant admin role)" -ForegroundColor Cyan

# -----------------------------------------------------------------------------
# Web app Entra ID app registration for Spring Security OIDC login
# -----------------------------------------------------------------------------
$webAppRedirectUri = "https://$WebAppName.azurewebsites.net/login/oauth2/code/azure"
$localDevRedirectUri = "http://localhost:8080/login/oauth2/code/azure"

$existingWebAuthAppId = (Invoke-AzCliSilent -Arguments @('ad','app','list','--display-name',$WebAppAuthAppName,'--query','[0].appId','-o','tsv')).Output
if ($existingWebAuthAppId) {
    Write-Host "[OK] Web app auth registration $WebAppAuthAppName already exists with ID: $existingWebAuthAppId" -ForegroundColor Green
    $WebAppClientId = $existingWebAuthAppId
} else {
    Invoke-AzCliSilent -Arguments @('ad','app','create',
            '--display-name',$WebAppAuthAppName,
            '--sign-in-audience','AzureADMyOrg',
            '--web-redirect-uris',$webAppRedirectUri,$localDevRedirectUri,
            '--output','none') | Out-Null
    # Azure AD replicates the new object asynchronously; poll until it appears.
    for ($i = 1; $i -le 12; $i++) {
        $WebAppClientId = (Invoke-AzCliSilent -Arguments @('ad','app','list','--display-name',$WebAppAuthAppName,'--query','[0].appId','-o','tsv')).Output
        if ($WebAppClientId) { break }
        Write-Host "[INFO] Waiting for web app auth registration to propagate (attempt $i/12)..." -ForegroundColor Cyan
        Start-Sleep -Seconds 10
    }
    if ($WebAppClientId) {
        Write-Host "[SUCCESS] Web app auth registration created with ID: $WebAppClientId" -ForegroundColor Green
    } else {
        Write-Host "[ERROR] Failed to create web app auth registration: $WebAppAuthAppName" -ForegroundColor Red
        $script:DeploymentErrors.Add("Web app auth registration: $WebAppAuthAppName")
    }
}

if ($WebAppClientId) {
    # Keep redirect URIs aligned for both deployed app and local development.
    Invoke-AzCliSilent -Arguments @('ad','app','update','--id',$WebAppClientId,
            '--web-redirect-uris',$webAppRedirectUri,$localDevRedirectUri,
            '--output','none') | Out-Null
}

if (-not $WebAppClientSecret -and $WebAppClientId) {
    $existingWebCreds = (Invoke-AzCliSilent -Arguments @('ad','app','credential','list','--id',$WebAppClientId,'--query','[0].keyId','-o','tsv')).Output
    if ($existingWebCreds) {
        $kvWebSecret = (Invoke-AzCliSilent -Arguments @('keyvault','secret','show','--vault-name',$KeyVaultName,'--name','WebAppClientSecret','--query','value','-o','tsv')).Output
        if ($kvWebSecret) {
            Write-Host "[OK] Client secret already exists for $WebAppAuthAppName and is stored in Key Vault" -ForegroundColor Green
            $WebAppClientSecret = $kvWebSecret
        } else {
            Write-Host "[WARNING] Web app credential exists in Entra ID but is missing from Key Vault. Rotating credential..." -ForegroundColor Yellow
            $webCredResult = Invoke-AzCliSilent -Arguments @('ad','app','credential','reset','--id',$WebAppClientId,'--display-name','insight-ui-auth-secret','--years','2','--query','password','-o','tsv')
            if ($webCredResult.ExitCode -eq 0 -and $webCredResult.Output) {
                $WebAppClientSecret = $webCredResult.Output
                Write-Host "[SUCCESS] Web app client secret rotated and will be stored in Key Vault" -ForegroundColor Green
            } else {
                Write-Host "[ERROR] Failed to rotate client secret for $WebAppAuthAppName" -ForegroundColor Red
                if ($webCredResult.Error) { Write-Host "  $($webCredResult.Error)" -ForegroundColor Red }
                $script:DeploymentErrors.Add("Web app auth client secret rotation")
            }
        }
    } else {
        $webCredResult = Invoke-AzCliSilent -Arguments @('ad','app','credential','reset','--id',$WebAppClientId,'--display-name','insight-ui-auth-secret','--years','2','--query','password','-o','tsv')
        if ($webCredResult.ExitCode -eq 0 -and $webCredResult.Output) {
            $WebAppClientSecret = $webCredResult.Output
            Write-Host "[SUCCESS] Client secret created for web app auth registration" -ForegroundColor Green
        } else {
            Write-Host "[ERROR] Failed to create client secret for $WebAppAuthAppName" -ForegroundColor Red
            if ($webCredResult.Error) { Write-Host "  $($webCredResult.Error)" -ForegroundColor Red }
            $script:DeploymentErrors.Add("Web app auth client secret creation")
        }
    }
}

if (-not $WebAppClientId) {
    Write-Host "[WARNING] WebAppClientId is empty - the 'WebAppClientId' Key Vault secret will be skipped." -ForegroundColor Yellow
}
if (-not $WebAppClientSecret) {
    Write-Host "[WARNING] WebAppClientSecret is empty - the 'WebAppClientSecret' Key Vault secret will be skipped." -ForegroundColor Yellow
}

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
                     '--tags',"project=$ProjectName","environment=$Environment",$SecurityControlTag,'--output','table')
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
                     '--tags',"project=$ProjectName","environment=$Environment",$SecurityControlTag,'--output','table')
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
                     '--tags',"project=$ProjectName","environment=$Environment",$SecurityControlTag,
                     '--output','table')
    if ($null -ne $result) {
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
# vectorIndexes require the account-level capability and a container vector embedding policy.
$existingCaps = @()
$vectorSearchEnabled = $false
$capsJson = (Invoke-AzCliSilent -Arguments @('cosmosdb','show','--name',$CosmosDbAccountName,'--resource-group',$ResourceGroupName,'--query','capabilities[].name','-o','tsv')).Output
if ($capsJson) { $existingCaps = @($capsJson -split "`n" | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() }) }
if ($existingCaps -contains 'EnableNoSQLVectorSearch') {
    $vectorSearchEnabled = $true
    Write-Host "[OK] Vector search capability already enabled on $CosmosDbAccountName" -ForegroundColor Green
} else {
    # --capabilities replaces the list, so existing ones must be passed through.
    $newCaps = @($existingCaps + 'EnableNoSQLVectorSearch' | Select-Object -Unique)
    $capResult = Invoke-AzCliSilent -Arguments (@('cosmosdb','update','--name',$CosmosDbAccountName,'--resource-group',$ResourceGroupName,'--capabilities') + $newCaps + @('--output','none'))
    if ($capResult.ExitCode -ne 0) {
        Write-Host "[WARNING] Could not enable EnableNoSQLVectorSearch: $($capResult.Error). Vector indexing will be skipped." -ForegroundColor Yellow
    } else {
        # The data plane rejects vector policies until the capability propagates.
        for ($i = 1; $i -le 12; $i++) {
            $check = (Invoke-AzCliSilent -Arguments @('cosmosdb','show','--name',$CosmosDbAccountName,'--resource-group',$ResourceGroupName,'--query',"capabilities[?name=='EnableNoSQLVectorSearch'].name",'-o','tsv')).Output
            if ($check) {
                $vectorSearchEnabled = $true
                Write-Host "[SUCCESS] Vector search capability enabled on $CosmosDbAccountName" -ForegroundColor Green
                break
            }
            Write-Host "[INFO] Waiting for vector search capability to propagate ($i/12)..." -ForegroundColor Cyan
            Start-Sleep -Seconds 10
        }
        if (-not $vectorSearchEnabled) {
            Write-Host "[WARNING] Cosmos vector search is not enabled after the propagation wait. Vector policy will be skipped; full-text indexing remains enabled." -ForegroundColor Yellow
        }
    }
}

$vectorEmbeddingPolicyJson = @{
    vectorEmbeddings = @(
        @{
            path             = "/embedding"
            dataType         = "float32"
            dimensions       = $CosmosDbVectorDimensions
            distanceFunction = "cosine"
        }
    )
} | ConvertTo-Json -Depth 10 -Compress

# Full-text policy enables BM25 keyword scoring for Cosmos-native hybrid (RANK RRF) search.
$fullTextPolicyJson = @{
    defaultLanguage = "en-US"
    fullTextPaths = @(
        @{ path = "/subject";     language = "en-US" }
        @{ path = "/bodyContent"; language = "en-US" }
    )
} | ConvertTo-Json -Depth 10 -Compress

$containerExists = (Invoke-AzCliSilent -Arguments @('cosmosdb','sql','container','show','--account-name',$CosmosDbAccountName,'--resource-group',$ResourceGroupName,'--database-name',$CosmosDbDatabaseName,'--name',$CosmosDbContainerName,'--query','name','-o','tsv')).Output
if ($containerExists) {
    Write-Host "[WARNING] Container $CosmosDbContainerName already exists, skipping creation" -ForegroundColor Yellow
    
    # Update indexing policy for vector + full-text search (safe to run on existing container)
    Write-Host "[INFO] Updating indexing policy (vector + full-text) on $CosmosDbContainerName..." -ForegroundColor Cyan
    $indexingPolicyJson = @{
        indexingMode = "consistent"
        automatic = $true
        includedPaths = @(
            @{ path = "/*" }
        )
        excludedPaths = @(
            @{ path = '/"_etag"/?' }
        )
        fullTextIndexes = @(
            @{ path = "/subject" }
            @{ path = "/bodyContent" }
        )
    } | ConvertTo-Json -Depth 10 -Compress
    if ($vectorSearchEnabled) {
        $indexingPolicy = $indexingPolicyJson | ConvertFrom-Json
        $indexingPolicy | Add-Member -MemberType NoteProperty -Name vectorIndexes -Value @([pscustomobject]@{ path = "/embedding"; type = "quantizedFlat" })
        $indexingPolicyJson = $indexingPolicy | ConvertTo-Json -Depth 10 -Compress
    }
    
    $indexPolicyFile = [System.IO.Path]::GetTempFileName()
    Set-Content -Path $indexPolicyFile -Value $indexingPolicyJson -Encoding utf8
    $fullTextPolicyFile = [System.IO.Path]::GetTempFileName()
    Set-Content -Path $fullTextPolicyFile -Value $fullTextPolicyJson -Encoding utf8
    
    try {
        $updateArgs = @('cosmosdb','sql','container','update',
                         '--account-name',$CosmosDbAccountName,
                         '--resource-group',$ResourceGroupName,
                         '--database-name',$CosmosDbDatabaseName,
                         '--name',$CosmosDbContainerName,
                         '--idx',"@$indexPolicyFile",
                         '--full-text-policy',"@$fullTextPolicyFile"
                         )
        if ($vectorSearchEnabled) {
            $vectorPolicyFile = [System.IO.Path]::GetTempFileName()
            Set-Content -Path $vectorPolicyFile -Value $vectorEmbeddingPolicyJson -Encoding utf8
            $updateArgs += @('--vector-embeddings', "@$vectorPolicyFile")
        }
        $updateArgs += @('--output', 'none')
        $indexResult = Invoke-AzCliSilent -Arguments $updateArgs
        if ($indexResult.ExitCode -eq 0) {
            Write-Host "[SUCCESS] Vector + full-text indexing policy updated on $CosmosDbContainerName" -ForegroundColor Green
        } else {
            Write-Host "[WARNING] Could not update indexing policy: $($indexResult.Error)" -ForegroundColor Yellow
        }
    } finally {
        Remove-Item $indexPolicyFile -Force -ErrorAction SilentlyContinue
        if ($vectorPolicyFile) { Remove-Item $vectorPolicyFile -Force -ErrorAction SilentlyContinue }
        Remove-Item $fullTextPolicyFile -Force -ErrorAction SilentlyContinue
    }
} else {
    # Create container with vector + full-text indexing when enabled; otherwise
    # create a full-text-only container so deployment remains usable.
    $indexingPolicyJson = @{
        indexingMode = "consistent"
        automatic = $true
        includedPaths = @(
            @{ path = "/*" }
        )
        excludedPaths = @(
            @{ path = '/"_etag"/?' }
        )
        fullTextIndexes = @(
            @{ path = "/subject" }
            @{ path = "/bodyContent" }
        )
    } | ConvertTo-Json -Depth 10 -Compress
    if ($vectorSearchEnabled) {
        $indexingPolicy = $indexingPolicyJson | ConvertFrom-Json
        $indexingPolicy | Add-Member -MemberType NoteProperty -Name vectorIndexes -Value @([pscustomobject]@{ path = "/embedding"; type = "quantizedFlat" })
        $indexingPolicyJson = $indexingPolicy | ConvertTo-Json -Depth 10 -Compress
    }
    
    $indexPolicyFile = [System.IO.Path]::GetTempFileName()
    Set-Content -Path $indexPolicyFile -Value $indexingPolicyJson -Encoding utf8
    $fullTextPolicyFile = [System.IO.Path]::GetTempFileName()
    Set-Content -Path $fullTextPolicyFile -Value $fullTextPolicyJson -Encoding utf8
    
    try {
        $createArgs = @('cosmosdb','sql','container','create',
                         '--account-name',$CosmosDbAccountName,
                         '--resource-group',$ResourceGroupName,
                         '--database-name',$CosmosDbDatabaseName,
                         '--name',$CosmosDbContainerName,
                         '--partition-key-path','/id',
                         '--idx',"@$indexPolicyFile",
                         '--full-text-policy',"@$fullTextPolicyFile")
        if ($vectorSearchEnabled) {
            $vectorPolicyFile = [System.IO.Path]::GetTempFileName()
            Set-Content -Path $vectorPolicyFile -Value $vectorEmbeddingPolicyJson -Encoding utf8
            $createArgs += @('--vector-embeddings', "@$vectorPolicyFile")
        }
        $createArgs += @('--output', 'table')
        $containerDescription = if ($vectorSearchEnabled) { "vector + full-text indexing" } else { "full-text indexing; vector search unavailable" }
        $containerResult = Invoke-AzCli -Description "Creating container: $CosmosDbContainerName (partition key: /id, $containerDescription)" `
            -Arguments $createArgs
        if ($null -ne $containerResult) {
            Write-Host "[SUCCESS] Container $CosmosDbContainerName created with $containerDescription policy" -ForegroundColor Green
        }
    } finally {
        Remove-Item $indexPolicyFile -Force -ErrorAction SilentlyContinue
        if ($vectorPolicyFile) { Remove-Item $vectorPolicyFile -Force -ErrorAction SilentlyContinue }
        Remove-Item $fullTextPolicyFile -Force -ErrorAction SilentlyContinue
    }
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
                     '--tags',"project=$ProjectName","environment=$Environment",$SecurityControlTag,
                     '--output','table','--yes')
    if ($null -ne $result) {
        Write-Host "[SUCCESS] Content Understanding $ContentUnderstandingName created" -ForegroundColor Green
        # The custom-domain DNS record takes time to become routable after account creation.
        # Data-plane calls to the endpoint will return 'Subdomain does not map to a resource'
        # until propagation completes. Wait before proceeding.
        Write-Host "[INFO] Waiting 90 seconds for Content Understanding custom domain to propagate..." -ForegroundColor Cyan
        Start-Sleep -Seconds 90
    }
}

# =============================================================================
# STEP 9/12: Azure AI Foundry + LLM Model Deployment
# =============================================================================
Write-Host ""
Write-Host ">>> Step 9/12: Azure AI Foundry + LLM Model Deployment" -ForegroundColor White

# Create AI Foundry resource (Azure AI Services account with project management enabled)
if (Test-AzResource -Arguments @('cognitiveservices','account','show','--name',$AiFoundryName,'--resource-group',$ResourceGroupName,'--query','name','-o','tsv')) {
    Write-Host "[WARNING] AI Foundry resource $AiFoundryName already exists, skipping creation" -ForegroundColor Yellow
} else {
    $result = Invoke-AzCli -Description "Creating Azure AI Foundry resource: $AiFoundryName" `
        -Arguments @('cognitiveservices','account','create','--name',$AiFoundryName,
                     '--resource-group',$ResourceGroupName,'--location',$LocationAiFoundry,
                     '--kind','AIServices','--sku','S0',
                     '--custom-domain',$AiFoundryName,
                     '--assign-identity',
                     '--tags',"project=$ProjectName","environment=$Environment",$SecurityControlTag,
                     '--output','table','--yes')
    if ($null -ne $result) {
        Write-Host "[SUCCESS] AI Foundry resource $AiFoundryName created" -ForegroundColor Green
        # ARM needs time to fully initialise the new account before it can accept
        # project or deployment child-resource PUTs. Without this wait the very
        # next ARM call gets InternalServerError. provisioningState=Succeeded on
        # the control plane does NOT mean the AI Foundry backend service is ready.
        Write-Host "[INFO] Waiting 180 seconds for new AI Foundry account backend to initialise..." -ForegroundColor Cyan
        Start-Sleep -Seconds 180
    }
}

# Ensure the account is Foundry-enabled (allowProjectManagement = true).
# This property is not exposed as a first-class az flag, so we enable it via az resource update.
$AiFoundryAccountId = (Invoke-AzCliSilent -Arguments @('cognitiveservices','account','show','--name',$AiFoundryName,'--resource-group',$ResourceGroupName,'--query','id','-o','tsv')).Output
if ($AiFoundryAccountId) {
    $apmCheck = Invoke-AzCliSilent -Arguments @('resource','show','--ids',$AiFoundryAccountId,'--query','properties.allowProjectManagement','-o','tsv')
    $apmCurrent = if ($apmCheck.Output) { $apmCheck.Output.Trim().ToLower() } else { '' }
    if ($apmCurrent -ne 'true') {
        $apmResult = Invoke-AzCli -Description "Enabling project management on $AiFoundryName" `
            -Arguments @('resource','update','--ids',$AiFoundryAccountId,
                         '--set','properties.allowProjectManagement=true',
                         '--latest-include-preview','--output','none')
        if ($null -ne $apmResult) {
            Write-Host "[SUCCESS] Project management enabled on $AiFoundryName" -ForegroundColor Green
            Write-Host "[INFO] Waiting 90 seconds for allowProjectManagement to propagate..." -ForegroundColor Cyan
            Start-Sleep -Seconds 90
        }
    } else {
        Write-Host "[OK] Project management already enabled on $AiFoundryName" -ForegroundColor Green
    }
} else {
    Write-Host "[ERROR] Could not resolve AI Foundry account id; skipping project setup" -ForegroundColor Red
}

# Create the AI Foundry project (child resource under the AIServices account).
#
# ARM project creation is an async LRO: the PUT returns HTTP 202 Accepted and
# ARM provisions in the background. Some az CLI versions surface the 202 as a
# non-zero exit code even though the operation is in flight. Strategy:
#   1. Poll the account until provisioningState=Succeeded AND allowProjectManagement=true.
#   2. Issue the PUT (up to 5 retries with exponential backoff for genuine transients).
#   3. Detect 202/async indicators in output and treat as accepted.
#   4. Always poll provisioningState for up to 10 min after the PUT.
if ($AiFoundryAccountId) {
    # Poll the account until ARM reports it is fully ready for child-resource operations.
    # 'az cognitiveservices account create' returns as soon as the control-plane record is
    # written, but the backend service layer continues initialising asynchronously.
    Write-Host "[INFO] Polling AI Foundry account readiness (provisioningState=Succeeded + allowProjectManagement=true)..." -ForegroundColor Cyan
    $acctReady = $false
    $acctMaxSec = 600; $acctWaited = 0; $acctInterval = 15
    while ($acctWaited -lt $acctMaxSec) {
        $acctProv = (Invoke-AzCliSilent -Arguments @('resource','show','--ids',$AiFoundryAccountId,
            '--query','properties.provisioningState','-o','tsv')).Output.Trim().ToLower()
        $acctApm  = (Invoke-AzCliSilent -Arguments @('resource','show','--ids',$AiFoundryAccountId,
            '--query','properties.allowProjectManagement','-o','tsv')).Output.Trim().ToLower()
        if ($acctProv -eq 'succeeded' -and $acctApm -eq 'true') {
            Write-Host "[OK] AI Foundry account ready (provisioningState=Succeeded, allowProjectManagement=true) after ${acctWaited}s" -ForegroundColor Green
            $acctReady = $true; break
        }
        $provDisplay = if ($acctProv) { $acctProv } else { '(unknown)' }
        $apmDisplay  = if ($acctApm)  { $acctApm  } else { '(unknown)' }
        Write-Host "[INFO] Account not ready yet (provisioningState=$provDisplay, allowProjectManagement=$apmDisplay), waited ${acctWaited}s / ${acctMaxSec}s..." -ForegroundColor Cyan
        Start-Sleep -Seconds $acctInterval
        $acctWaited += $acctInterval
    }
    if (-not $acctReady) {
        Write-Host "[WARNING] Timed out waiting for AI Foundry account to become ready — proceeding anyway" -ForegroundColor Yellow
    }
    $projectResourceId = "$AiFoundryAccountId/projects/$AiFoundryProjectName"
    $provCheck = Invoke-AzCliSilent -Arguments @('resource','show','--ids',$projectResourceId,
        '--api-version',$AiFoundryProjectApiVersion,'--query','properties.provisioningState','-o','tsv')
    $existingState = $provCheck.Output.Trim().ToLower()
    if ($existingState -eq 'succeeded') {
        Write-Host "[WARNING] AI Foundry project $AiFoundryProjectName already exists (Succeeded), skipping" -ForegroundColor Yellow
    } elseif ($existingState -and $existingState -ne 'none' -and $existingState -ne 'failed') {
        Write-Host "[INFO] AI Foundry project $AiFoundryProjectName exists with state '$existingState', polling..." -ForegroundColor Cyan
        if (Wait-ForArmResource -ResourceId $projectResourceId -ApiVersion $AiFoundryProjectApiVersion -MaxSeconds 600 -IntervalSeconds 15) {
            Write-Host "[SUCCESS] AI Foundry project $AiFoundryProjectName reached Succeeded state" -ForegroundColor Green
        } else {
            $script:DeploymentErrors.Add("Creating AI Foundry project: $AiFoundryProjectName (state stuck at $existingState)")
        }
    } else {
        $projectBody = @{
            location   = $LocationAiFoundry
            identity   = @{ type = 'SystemAssigned' }
            properties = @{
                displayName = $AiFoundryProjectName
                description = "AI Foundry project for $ProjectName ($Environment)"
            }
        } | ConvertTo-Json -Compress -Depth 5
        $projectBodyFile = Join-Path ([System.IO.Path]::GetTempPath()) "foundry-project-$([guid]::NewGuid().ToString('N')).json"
        Set-Content -Path $projectBodyFile -Value $projectBody -Encoding UTF8
        $projectArmUrl = "https://management.azure.com$projectResourceId`?api-version=$AiFoundryProjectApiVersion"
        try {
            $maxPutAttempts = 5
            for ($putAttempt = 1; $putAttempt -le $maxPutAttempts; $putAttempt++) {
                Write-Host "[INFO] Creating AI Foundry project: $AiFoundryProjectName (PUT attempt $putAttempt/$maxPutAttempts)" -ForegroundColor Cyan
                $putResult = Invoke-AzCliSilent -Arguments @('rest','--method','put',
                                 '--url',$projectArmUrl,
                                 '--body',"@$projectBodyFile")
                if ($putResult.ExitCode -eq 0) { break }
                # 202 Accepted surfaces as non-zero in some az CLI builds
                $combined = $putResult.Output + $putResult.Error
                if ($combined -match 'AsyncOperation|Operation-Location|Accepted|creating|202') {
                    Write-Host "[INFO] PUT returned async/202 indicator — treating as accepted" -ForegroundColor Cyan
                    break
                }
                if ($putAttempt -lt $maxPutAttempts) {
                    # Exponential backoff: 15, 30, 60, 60, 60, 60, 60 seconds
                    $delay = [Math]::Min(60, 15 * [Math]::Pow(2, $putAttempt - 1))
                    $isTransient = ($combined -match 'InternalServerError|ServiceUnavailable|GatewayTimeout|429|TooManyRequests|temporar')
                    $label = if ($isTransient) { 'Transient error' } else { 'Error' }
                    Write-Host "[WARNING] $label on attempt $putAttempt, retrying in $delay seconds..." -ForegroundColor Yellow
                    Start-Sleep -Seconds $delay
                }
            }
            # Always poll regardless of PUT exit — ARM may have accepted the LRO
            Write-Host "[INFO] Polling for project provisioning state (up to 10 min)..." -ForegroundColor Cyan
            if (Wait-ForArmResource -ResourceId $projectResourceId -ApiVersion $AiFoundryProjectApiVersion -MaxSeconds 600 -IntervalSeconds 15 -FailedIsTransient) {
                Write-Host "[SUCCESS] AI Foundry project $AiFoundryProjectName created (Succeeded)" -ForegroundColor Green
            } else {
                $finalCheck = Invoke-AzCliSilent -Arguments @('resource','show','--ids',$projectResourceId,
                    '--api-version',$AiFoundryProjectApiVersion,'--query','properties.provisioningState','-o','tsv')
                $finalState = $finalCheck.Output.Trim()
                if ($finalState) {
                    Write-Host "[ERROR] Creating AI Foundry project: $AiFoundryProjectName — stuck in state '$finalState' after all retries" -ForegroundColor Red
                } else {
                    Write-Host "[ERROR] Creating AI Foundry project: $AiFoundryProjectName — resource not found after all PUT attempts" -ForegroundColor Red
                }
                Write-Host "  Verify: az resource show --ids $projectResourceId --api-version $AiFoundryProjectApiVersion" -ForegroundColor Red
                $script:DeploymentErrors.Add("Creating AI Foundry project: $AiFoundryProjectName")
            }
        } finally {
            Remove-Item -Path $projectBodyFile -Force -ErrorAction SilentlyContinue
        }
    }
}

# -----------------------------------------------------------------------------
# Deploy LLM models on the AI Foundry account from deploy-models.csv
# CSV format: <model-name>,<sku-name>,<model-version>
# Deployment name is the same as the model name. If a model is unavailable for
# the requested SKU/version in the chosen region, the user is prompted for an
# alternative model name, deployment type, and version.
# -----------------------------------------------------------------------------

# Cache of available OpenAI models per location: $script:FoundryModelCatalog[$loc] = parsed JSON array
$script:FoundryModelCatalog = @{}

function Get-FoundryModelCatalog {
    param([Parameter(Mandatory=$true)][string]$Location)
    if ($script:FoundryModelCatalog.ContainsKey($Location)) {
        return $script:FoundryModelCatalog[$Location]
    }
    $listResult = Invoke-AzCliSilent -Arguments @('cognitiveservices','model','list','--location',$Location,'-o','json')
    $catalog = @()
    if ($listResult.ExitCode -eq 0 -and $listResult.Output) {
        try {
            $parsed = $listResult.Output | ConvertFrom-Json -ErrorAction Stop
            $catalog = @($parsed | Where-Object { $_.model.format -eq 'OpenAI' -and $_.kind -eq 'AIServices' })
            if (-not $catalog -or $catalog.Count -eq 0) {
                # Fallback: include all OpenAI-format entries regardless of kind
                $catalog = @($parsed | Where-Object { $_.model.format -eq 'OpenAI' })
            }
        } catch {
            Write-Host "[WARNING] Could not parse model catalog for $Location" -ForegroundColor Yellow
        }
    } else {
        Write-Host "[WARNING] Could not list available models in $Location" -ForegroundColor Yellow
    }
    $script:FoundryModelCatalog[$Location] = $catalog
    return $catalog
}

function Get-StringSimilarityScore {
    # Simple case-insensitive similarity: longest common substring length / max(len).
    # Plus a bonus if one is a substring of the other.
    param([string]$A, [string]$B)
    if (-not $A -or -not $B) { return 0.0 }
    $a = $A.ToLower(); $b = $B.ToLower()
    if ($a -eq $b) { return 1.0 }
    if ($a.Contains($b) -or $b.Contains($a)) {
        return 0.85 + (0.15 * ([Math]::Min($a.Length,$b.Length) / [Math]::Max($a.Length,$b.Length)))
    }
    # Longest common substring
    $la = $a.Length; $lb = $b.Length
    $best = 0
    $prev = New-Object 'int[]' ($lb + 1)
    for ($i = 1; $i -le $la; $i++) {
        $curr = New-Object 'int[]' ($lb + 1)
        for ($j = 1; $j -le $lb; $j++) {
            if ($a[$i-1] -eq $b[$j-1]) {
                $curr[$j] = $prev[$j-1] + 1
                if ($curr[$j] -gt $best) { $best = $curr[$j] }
            }
        }
        $prev = $curr
    }
    return $best / [Math]::Max($la, $lb)
}

function Show-ModelSuggestions {
    param(
        [Parameter(Mandatory=$true)][string]$Location,
        [Parameter(Mandatory=$true)][string]$RequestedModel,
        [string]$RequestedSku,
        [int]$Top = 5
    )
    $catalog = Get-FoundryModelCatalog -Location $Location
    if (-not $catalog -or $catalog.Count -eq 0) { return }

    # Score by model name similarity
    $scored = foreach ($entry in $catalog) {
        $name = $entry.model.name
        $score = Get-StringSimilarityScore -A $RequestedModel -B $name
        [PSCustomObject]@{
            Name    = $name
            Version = $entry.model.version
            Skus    = ($entry.model.skus | ForEach-Object { $_.name } | Sort-Object -Unique) -join ', '
            Score   = $score
        }
    }
    # Group by name+version, keep best score
    $grouped = $scored | Group-Object Name, Version | ForEach-Object {
        $_.Group | Sort-Object Score -Descending | Select-Object -First 1
    }
    $topResults = @($grouped | Sort-Object Score -Descending | Select-Object -First $Top)

    if ($topResults.Count -gt 0) {
        Write-Host ""
        Write-Host "[INFO] Closest matches for '$RequestedModel' in $Location :" -ForegroundColor Cyan
        $topResults | ForEach-Object {
            Write-Host ("  - {0,-30} version={1,-15} skus={2}" -f $_.Name, $_.Version, $_.Skus) -ForegroundColor Cyan
        }
    }

    if ($RequestedSku) {
        $skuMatches = $catalog | Where-Object { $_.model.name -eq $RequestedModel } | ForEach-Object {
            [PSCustomObject]@{
                Version = $_.model.version
                Skus    = ($_.model.skus | ForEach-Object { $_.name }) -join ', '
            }
        }
        if ($skuMatches) {
            Write-Host "[INFO] Versions/SKUs available for exact name '$RequestedModel':" -ForegroundColor Cyan
            $skuMatches | ForEach-Object {
                Write-Host ("  - version={0,-15} skus={1}" -f $_.Version, $_.Skus) -ForegroundColor Cyan
            }
        }
    }
}

function Get-AvailableCapacity {
    param(
        [Parameter(Mandatory=$true)][string]$Location,
        [Parameter(Mandatory=$false)][string]$SkuName = "GlobalStandard",
        [Parameter(Mandatory=$false)][int]$DefaultCapacity = 50
    )
    
    try {
        $usageResult = Invoke-AzCliSilent -Arguments @('cognitiveservices','usage','list','--location',$Location,'-o','json')
        if ($usageResult.ExitCode -ne 0 -or -not $usageResult.Output) {
            Write-Host "[WARNING] Could not retrieve quota for '$Location', using default capacity: $DefaultCapacity K TPM" -ForegroundColor Yellow
            return $DefaultCapacity
        }

        $usageData = $usageResult.Output | ConvertFrom-Json -ErrorAction Stop
        $skuQuota = $null
        
        # Look for GlobalStandard quota entry
        foreach ($entry in $usageData) {
            if ($entry.name.value -match "\.${SkuName}$") {
                $skuQuota = @{ Current = [long]$entry.currentValue; Limit = [long]$entry.limit }
                break
            }
        }

        if ($null -eq $skuQuota) {
            Write-Host "[WARNING] No quota data found for '$SkuName' SKU in '$Location', using default: $DefaultCapacity K TPM" -ForegroundColor Yellow
            return $DefaultCapacity
        }

        # Calculate available capacity: 80% of (limit - current), minimum 1, maximum limit
        $available = $skuQuota.Limit - $skuQuota.Current
        if ($available -le 0) {
            Write-Host "[WARNING] No available quota for '$SkuName' in '$Location' (used: $($skuQuota.Current)K / limit: $($skuQuota.Limit)K), using default: $DefaultCapacity K TPM" -ForegroundColor Yellow
            return $DefaultCapacity
        }

        $capacity = [Math]::Max(1, [long][Math]::Floor($available * 0.80))
        Write-Host "[INFO] Available capacity for '$SkuName' in '$Location': $capacity K TPM (used: $($skuQuota.Current)K / limit: $($skuQuota.Limit)K)" -ForegroundColor Cyan
        return $capacity
    } catch {
        Write-Host "[WARNING] Error calculating available capacity: $_`nUsing default: $DefaultCapacity K TPM" -ForegroundColor Yellow
        return $DefaultCapacity
    }
}

function Invoke-FoundryModelDeployment {
    param(
        [Parameter(Mandatory=$true)][string]$AccountName,
        [Parameter(Mandatory=$true)][string]$ResourceGroup,
        [Parameter(Mandatory=$true)][string]$ModelName,
        [Parameter(Mandatory=$true)][string]$SkuName,
        [Parameter(Mandatory=$true)][string]$ModelVersion,
        [Parameter(Mandatory=$true)][string]$Capacity
    )

    $deploymentName = $ModelName
    $existing = Invoke-AzCliSilent -Arguments @('cognitiveservices','account','deployment','show','--name',$AccountName,'--resource-group',$ResourceGroup,'--deployment-name',$deploymentName,'--query','name','-o','tsv')
    if ($existing.ExitCode -eq 0 -and $existing.Output) {
        Write-Host "[WARNING] Model deployment $deploymentName already exists on $AccountName, skipping" -ForegroundColor Yellow
        return $true
    }

    $attempt = Invoke-AzCliSilent -Arguments @('cognitiveservices','account','deployment','create',
                 '--name',$AccountName,'--resource-group',$ResourceGroup,
                 '--deployment-name',$deploymentName,
                 '--model-name',$ModelName,
                 '--model-version',$ModelVersion,
                 '--model-format','OpenAI',
                 '--sku-name',$SkuName,
                 '--sku-capacity',$Capacity,
                 '--output','table')

    if ($attempt.ExitCode -eq 0) {
        Write-Host "[SUCCESS] Deployed $ModelName ($SkuName, version $ModelVersion) on $AccountName" -ForegroundColor Green
        return $true
    }

    Write-Host "[ERROR] Failed to deploy $ModelName ($SkuName, version $ModelVersion) on $AccountName" -ForegroundColor Red
    if ($attempt.Output) { Write-Host $attempt.Output -ForegroundColor Red }
    return $false
}

# Selects a Content Understanding model from those available and deployable
# in the chosen region. Selection is non-interactive so deployment can continue.
# Returns a hashtable: @{ Name; Version; SkuName }
function Select-CuModel {
    param(
        [Parameter(Mandatory=$true)][string]$Location,
        [Parameter(Mandatory=$true)][string]$ModelType,          # 'completion' or 'embedding'
        [Parameter(Mandatory=$true)][string[]]$SupportedModels,  # ordered list of CU-supported model names
        [Parameter(Mandatory=$true)][string]$DefaultModelName,
        [Parameter(Mandatory=$false)][AllowEmptyString()][string]$DefaultModelVersion = '',
        [string]$SkuName = 'GlobalStandard'
    )

    Write-Host ""
    Write-Host "[INFO] Fetching $ModelType model availability for Content Understanding in '$Location'..." -ForegroundColor Cyan

    # Build preference-order lookup for embeddings: lower index = more preferred.
    # Completion selection is version-driven below, not name-driven.
    $preferenceOrder = @{}
    for ($i = 0; $i -lt $SupportedModels.Count; $i++) { $preferenceOrder[$SupportedModels[$i]] = $i }

    # Filter catalog to models that are CU-supported AND offer the required SKU in this region
    $catalog = Get-FoundryModelCatalog -Location $Location
    $rawCandidates = @(foreach ($entry in $catalog) {
        $name    = $entry.model.name
        $version = $entry.model.version
        if (-not $preferenceOrder.ContainsKey($name)) { continue }
        $skuNames = @($entry.model.skus | ForEach-Object { $_.name })
        if ($skuNames -notcontains $SkuName) { continue }
        [PSCustomObject]@{ Name = $name; Version = $version }
    })
    if ($ModelType -eq 'completion') {
        # Model versions are date-like strings for completion deployments, so
        # descending lexical order selects the latest available catalog version.
        $candidates = @($rawCandidates | Sort-Object @{ Expression = 'Version'; Descending = $true },
                                                      @{ Expression = { $preferenceOrder[$_.Name] }; Ascending = $true })
    } else {
        # Embeddings use only the explicit small -> large -> ada-002 order.
        $candidates = @($rawCandidates | Sort-Object @{ Expression = { $preferenceOrder[$_.Name] }; Ascending = $true })
    }

    if ($candidates.Count -eq 0) {
        Write-Host "[WARNING] No supported $ModelType models with '$SkuName' SKU found in '$Location'. Keeping fallback: $DefaultModelName $DefaultModelVersion" -ForegroundColor Yellow
        return @{ Name = $DefaultModelName; Version = $DefaultModelVersion; SkuName = $SkuName }
    }

    # Fetch quota usage for this subscription+location
    # Format: name.value = "OpenAI.GlobalStandard.gpt-4.1", currentValue/limit in K TPM
    $usageMap = @{}
    $usageResult = Invoke-AzCliSilent -Arguments @('cognitiveservices','usage','list','--location',$Location,'-o','json')
    if ($usageResult.ExitCode -eq 0 -and $usageResult.Output) {
        try {
            ($usageResult.Output | ConvertFrom-Json -ErrorAction Stop) | ForEach-Object {
                if ($_.name.value -match '\.([^.]+)$') {
                    $usageMap[$Matches[1].ToLower()] = @{ Current = [long]$_.currentValue; Limit = [long]$_.limit }
                }
            }
        } catch {
            Write-Host "[WARNING] Could not parse quota data — quota will show as unknown" -ForegroundColor Yellow
        }
    } else {
        Write-Host "[WARNING] Could not retrieve quota for '$Location' — proceeding without quota info" -ForegroundColor Yellow
    }

    # Candidates are already ordered by the selection policy above. Keep the
    # first candidate with remaining quota; if none have quota, use the top
    # candidate and let deployment produce the authoritative capacity error.
    $sel = $candidates | Where-Object {
        $q = $usageMap[$_.Name.ToLower()]
        $null -eq $q -or ($q.Limit -gt 0 -and $q.Current -lt $q.Limit)
    } | Select-Object -First 1
    if ($null -eq $sel) { $sel = $candidates | Select-Object -First 1 }

    $q = $usageMap[$sel.Name.ToLower()]
    if ($ModelType -eq 'completion') {
        Write-Host "[INFO] Selected latest available completion model '$($sel.Name)' v$($sel.Version) in '$Location'." -ForegroundColor Green
    } else {
        Write-Host "[INFO] Selected embedding model '$($sel.Name)' v$($sel.Version) using preference order: small, large, ada-002." -ForegroundColor Green
    }
    if ($q -and ($q.Limit -eq 0 -or $q.Current -ge $q.Limit)) {
        Write-Host "[WARNING] '$($sel.Name)' has no remaining quota in '$Location'. Deployment may fail." -ForegroundColor Yellow
    }
    # Allocate 80% of available quota (limit - used). Falls back to the caller's
    # hardcoded default when quota data is unavailable.
    $available = if ($q -and $q.Limit -gt 0) { $q.Limit - $q.Current } else { $null }
    $capacity  = if ($null -ne $available)   { [Math]::Max(1, [long][Math]::Floor($available * 0.80)) } else { $null }
    $capInfo   = if ($null -ne $capacity)    { "${capacity}K TPM  (80% of ${available}K available)" }   else { 'quota unknown — keeping script default' }
    Write-Host "[INFO] Selected $ModelType model: $($sel.Name) v$($sel.Version)" -ForegroundColor Green
    Write-Host "[INFO] Capacity to allocate : $capInfo" -ForegroundColor Green
    return @{ Name = $sel.Name; Version = $sel.Version; SkuName = $SkuName; Capacity = $capacity }
}

if (-not (Test-Path $DeployModelsCsvPath)) {
    Write-Host "[WARNING] $DeployModelsCsvPath not found - skipping model deployments" -ForegroundColor Yellow
} else {
    $modelLines = Get-Content $DeployModelsCsvPath | Where-Object { $_ -and ($_.Trim() -ne '') -and (-not $_.Trim().StartsWith('#')) }
    $llmRowIndex = 0
    foreach ($modelLine in $modelLines) {
        $cols = $modelLine -split ','
        if ($cols.Count -lt 3) {
            Write-Host "[WARNING] Skipping malformed line in deploy-models.csv: $modelLine" -ForegroundColor Yellow
            continue
        }
        $modelName    = $cols[0].Trim()
        $modelSku     = $cols[1].Trim()
        $modelVersion = $cols[2].Trim()
        $modelType    = if ($cols.Count -ge 4) { $cols[3].Trim() } else { "llm" }

        # Skip non-LLM models (embeddings handled separately below)
        if ($modelType -eq "embeddings") {
            continue
        }

        $capacity = Get-AvailableCapacity -Location $LocationAiFoundry -SkuName $modelSku
        $ok = Invoke-FoundryModelDeployment -AccountName $AiFoundryName -ResourceGroup $ResourceGroupName `
                -ModelName $modelName -SkuName $modelSku -ModelVersion $modelVersion -Capacity $capacity

        while (-not $ok) {
            Show-ModelSuggestions -Location $LocationAiFoundry -RequestedModel $modelName -RequestedSku $modelSku
            Write-Host ""
            Write-Host "[INPUT] Model '$modelName' (sku '$modelSku', version '$modelVersion') is unavailable. Provide an alternative or press Enter on model name to skip." -ForegroundColor Yellow
            $altModel = Read-Host "Alternative model name (Enter to skip)"
            if ([string]::IsNullOrWhiteSpace($altModel)) {
                Write-Host "[INFO] Skipping model '$modelName'" -ForegroundColor Cyan
                break
            }
            $altSku = Read-Host "Alternative deployment type / sku-name (default: $modelSku)"
            if ([string]::IsNullOrWhiteSpace($altSku)) { $altSku = $modelSku }
            $altVersion = Read-Host "Alternative model version"
            if ([string]::IsNullOrWhiteSpace($altVersion)) {
                Write-Host "[ERROR] Model version is required" -ForegroundColor Red
                continue
            }
            $modelName    = $altModel.Trim()
            $modelSku     = $altSku.Trim()
            $modelVersion = $altVersion.Trim()
            $capacity = Get-AvailableCapacity -Location $LocationAiFoundry -SkuName $modelSku
            $ok = Invoke-FoundryModelDeployment -AccountName $AiFoundryName -ResourceGroup $ResourceGroupName `
                    -ModelName $modelName -SkuName $modelSku -ModelVersion $modelVersion -Capacity $capacity
        }

        # The first successfully-handled LLM row becomes the "primary" model used by the
        # Java app (its deployment name/model name are stored in Key Vault).
        if ($llmRowIndex -eq 0 -and $ok) {
            $AiFoundryDeploymentName = $modelName
            $AiFoundryModelName      = $modelName
        }
        $llmRowIndex++
    }
    
    # Process embeddings models from CSV
    foreach ($modelLine in $modelLines) {
        $cols = $modelLine -split ','
        if ($cols.Count -lt 3) { continue }
        $modelName    = $cols[0].Trim()
        $modelSku     = $cols[1].Trim()
        $modelVersion = $cols[2].Trim()
        $modelType    = if ($cols.Count -ge 4) { $cols[3].Trim() } else { "llm" }

        # Only process embeddings models
        if ($modelType -ne "embeddings") {
            continue
        }

        Write-Host ""
        Write-Host "[INFO] Processing embeddings model from CSV: $modelName v$modelVersion (SKU: $modelSku)" -ForegroundColor Cyan

        $capacity = Get-AvailableCapacity -Location $LocationAiFoundry -SkuName $modelSku
        $ok = Invoke-FoundryModelDeployment -AccountName $AiFoundryName -ResourceGroup $ResourceGroupName `
                -ModelName $modelName -SkuName $modelSku -ModelVersion $modelVersion -Capacity $capacity

        while (-not $ok) {
            Show-ModelSuggestions -Location $LocationAiFoundry -RequestedModel $modelName -RequestedSku $modelSku
            Write-Host ""
            Write-Host "[INPUT] Embeddings model '$modelName' (sku '$modelSku', version '$modelVersion') is unavailable. Provide an alternative or press Enter to keep default." -ForegroundColor Yellow
            $altModel = Read-Host "Alternative embeddings model name (Enter to keep default)"
            if ([string]::IsNullOrWhiteSpace($altModel)) {
                Write-Host "[INFO] Keeping default embeddings model: $AiFoundryEmbeddingsModelName" -ForegroundColor Cyan
                break
            }
            $altSku = Read-Host "Alternative deployment type / sku-name (default: $modelSku)"
            if ([string]::IsNullOrWhiteSpace($altSku)) { $altSku = $modelSku }
            $altVersion = Read-Host "Alternative model version"
            if ([string]::IsNullOrWhiteSpace($altVersion)) {
                Write-Host "[ERROR] Model version is required" -ForegroundColor Red
                continue
            }
            $modelName    = $altModel.Trim()
            $modelSku     = $altSku.Trim()
            $modelVersion = $altVersion.Trim()
            $capacity = Get-AvailableCapacity -Location $LocationAiFoundry -SkuName $modelSku
            $ok = Invoke-FoundryModelDeployment -AccountName $AiFoundryName -ResourceGroup $ResourceGroupName `
                    -ModelName $modelName -SkuName $modelSku -ModelVersion $modelVersion -Capacity $capacity
        }

        # Update embeddings configuration from CSV
        if ($ok) {
            $AiFoundryEmbeddingsDeploymentName = $modelName
            $AiFoundryEmbeddingsModelName      = $modelName
            $AiFoundryEmbeddingsModelVersion   = $modelVersion
        }
    }
}

# Automatically select the preferred completion and embedding models to deploy
# on the CU resource, falling back to an available regional model when needed.
Write-Host ""
Write-Host ">>> Selecting Content Understanding models for '$LocationContentUnderstanding'" -ForegroundColor White
Write-Host "[INFO] Only models officially supported by Content Understanding are shown." -ForegroundColor DarkCyan
Write-Host "[INFO] Completion selection: latest available catalog version; embedding selection: small, large, ada-002 preference order." -ForegroundColor DarkCyan

$cuCompletionModels = @('gpt-5.2','gpt-4.1','gpt-4.1-mini','gpt-4.1-nano','gpt-4o','gpt-4o-mini')
$cuEmbeddingModels  = @('text-embedding-3-small','text-embedding-3-large','text-embedding-ada-002')

$selCompletion = Select-CuModel `
    -Location $LocationContentUnderstanding -ModelType 'completion' `
    -SupportedModels $cuCompletionModels `
    -DefaultModelName $CuCompletionModelName -DefaultModelVersion $CuCompletionModelVersion
$CuCompletionModelName      = $selCompletion.Name
$CuCompletionModelVersion   = $selCompletion.Version
$CuCompletionDeploymentName = $selCompletion.Name
if ($null -ne $selCompletion.Capacity) { $CuCompletionSkuCapacity = $selCompletion.Capacity }

$selEmbedding = Select-CuModel `
    -Location $LocationContentUnderstanding -ModelType 'embedding' `
    -SupportedModels $cuEmbeddingModels `
    -DefaultModelName $CuEmbeddingModelName -DefaultModelVersion $CuEmbeddingModelVersion
$CuEmbeddingModelName      = $selEmbedding.Name
$CuEmbeddingModelVersion   = $selEmbedding.Version
$CuEmbeddingDeploymentName = $selEmbedding.Name
if ($null -ne $selEmbedding.Capacity) { $CuEmbeddingSkuCapacity = $selEmbedding.Capacity }

Write-Host ""
Write-Host "[INFO] Content Understanding models selected:" -ForegroundColor Cyan
Write-Host "  Completion : $CuCompletionModelName v$CuCompletionModelVersion" -ForegroundColor Cyan
Write-Host "  Embedding  : $CuEmbeddingModelName v$CuEmbeddingModelVersion" -ForegroundColor Cyan

# Deploy the selected completion model on the CU resource.
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
    if ($null -ne $result) {
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
    if ($null -ne $result) {
        Write-Host "[SUCCESS] CU embedding model $CuEmbeddingModelName deployed as $CuEmbeddingDeploymentName on $ContentUnderstandingName" -ForegroundColor Green
    }
}

# Deploy AI Foundry embeddings model for email and attachment vector search.
# This deployment is separate from Content Understanding and used by the Java
# orchestration functions for generating embeddings for semantic search.
Write-Host ""
Write-Host ">>> Deploying AI Foundry embeddings model for email/attachment search" -ForegroundColor White

$aiFoundryEmbedDeploymentExists = (Invoke-AzCliSilent -Arguments @('cognitiveservices','account','deployment','show','--name',$AiFoundryName,'--resource-group',$ResourceGroupName,'--deployment-name',$AiFoundryEmbeddingsDeploymentName,'--query','name','-o','tsv')).Output
if ($aiFoundryEmbedDeploymentExists) {
    Write-Host "[WARNING] AI Foundry embeddings model deployment $AiFoundryEmbeddingsDeploymentName already exists on $AiFoundryName, skipping" -ForegroundColor Yellow
} else {
    $result = Invoke-AzCli -Description "Deploying AI Foundry embeddings model $AiFoundryEmbeddingsModelName on $AiFoundryName ($AiFoundrySkuName, ${AiFoundryEmbeddingsSkuCapacity}K TPM)" `
        -Arguments @('cognitiveservices','account','deployment','create',
                     '--name',$AiFoundryName,'--resource-group',$ResourceGroupName,
                     '--deployment-name',$AiFoundryEmbeddingsDeploymentName,
                     '--model-name',$AiFoundryEmbeddingsModelName,
                     '--model-version',$AiFoundryEmbeddingsModelVersion,
                     '--model-format','OpenAI',
                     '--sku-name',$AiFoundrySkuName,
                     '--sku-capacity',$AiFoundryEmbeddingsSkuCapacity,
                     '--output','table')
    if ($null -ne $result) {
        Write-Host "[SUCCESS] AI Foundry embeddings model $AiFoundryEmbeddingsModelName deployed as $AiFoundryEmbeddingsDeploymentName on $AiFoundryName" -ForegroundColor Green
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
    if ($CurrentUserId -and $CuResourceId) {
        $cuRoleAlready = Set-RoleAssignment -Assignee $CurrentUserId -Role 'Cognitive Services User' -Scope $CuResourceId
        if (-not $cuRoleAlready) {
            Write-Host "[INFO] Granted Cognitive Services User to current user on $ContentUnderstandingName" -ForegroundColor Cyan
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

        # Retry up to 5 times in case RBAC propagation or custom-domain DNS is still in-flight
        $cuDefaultsSet = $false
        $maxRetries = 5
        for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
            $setResult = Invoke-AzCliSilent -Arguments @('rest','--method','PATCH','--url',$cuDefaultsUrl,'--resource','https://cognitiveservices.azure.com','--body',"@$tempDefaultsFile",'--headers','Content-Type=application/json')
            if ($setResult.ExitCode -eq 0) {
                Write-Host "[SUCCESS] Content Understanding defaults set ($CuCompletionModelName -> $CuCompletionDeploymentName on $ContentUnderstandingName)" -ForegroundColor Green
                $cuDefaultsSet = $true
                break
            }
            if ($attempt -lt $maxRetries) {
                if ($setResult.Error -match 'PermissionDenied') {
                    Write-Host "[INFO] Permission not yet propagated, retrying in 30 seconds (attempt $attempt/$maxRetries)..." -ForegroundColor Cyan
                    Start-Sleep -Seconds 30
                } elseif ($setResult.Error -match 'ResourceNotFound|Subdomain does not map') {
                    Write-Host "[INFO] Endpoint not yet reachable (custom domain propagating), retrying in 30 seconds (attempt $attempt/$maxRetries)..." -ForegroundColor Cyan
                    Start-Sleep -Seconds 30
                } else {
                    break  # Non-retryable error
                }
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
                     '--tags',"project=$ProjectName","environment=$Environment",$SecurityControlTag,
                     '--output','table')
    if ($null -ne $result) {
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
                     '--tags',"project=$ProjectName","environment=$Environment","app=spring-boot-web",$SecurityControlTag,
                     '--output','table')
    if ($null -ne $result) {
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
                     '--tags',"project=$ProjectName","environment=$Environment","function=mailbox-to-queue",$SecurityControlTag,
                     '--output','table'))
    if ($null -ne $result) {
        Write-Host "[SUCCESS] Function app $FuncMailboxName created" -ForegroundColor Green
    }
}

# Queue-to-DB function
if (Test-AzResource -Arguments @('functionapp','show','--name',$FuncQueueDbName,'--resource-group',$ResourceGroupName,'--query','name','-o','tsv')) {
    Write-Host "[WARNING] Function app $FuncQueueDbName already exists, skipping" -ForegroundColor Yellow
} else {
    $result = Invoke-AzCli -Description "Creating function app: $FuncQueueDbName" `
        -Arguments (@('functionapp','create','--name',$FuncQueueDbName) + $CommonFuncArgs + @(
                     '--tags',"project=$ProjectName","environment=$Environment","function=queue-to-db",$SecurityControlTag,
                     '--output','table'))
    if ($null -ne $result) {
        Write-Host "[SUCCESS] Function app $FuncQueueDbName created" -ForegroundColor Green
    }
}

# CU-Queue-to-DB function
if (Test-AzResource -Arguments @('functionapp','show','--name',$FuncCuQueueDbName,'--resource-group',$ResourceGroupName,'--query','name','-o','tsv')) {
    Write-Host "[WARNING] Function app $FuncCuQueueDbName already exists, skipping" -ForegroundColor Yellow
} else {
    $result = Invoke-AzCli -Description "Creating function app: $FuncCuQueueDbName" `
        -Arguments (@('functionapp','create','--name',$FuncCuQueueDbName) + $CommonFuncArgs + @(
                     '--tags',"project=$ProjectName","environment=$Environment","function=cu-queue-to-db",$SecurityControlTag,
                     '--output','table'))
    if ($null -ne $result) {
        Write-Host "[SUCCESS] Function app $FuncCuQueueDbName created" -ForegroundColor Green
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
$CuQueueDbExists = Test-AzResource -Arguments @('functionapp','show','--name',$FuncCuQueueDbName,'--resource-group',$ResourceGroupName,'--query','name','-o','tsv')
$WebAppExists  = Test-AzResource -Arguments @('webapp','show','--name',$WebAppName,'--resource-group',$ResourceGroupName,'--query','name','-o','tsv')

if (-not $MailboxExists -or -not $QueueDbExists -or -not $CuQueueDbExists) {
    Write-Host "[ERROR] One or more function apps do not exist. Cannot configure managed identities." -ForegroundColor Red
    if (-not $MailboxExists) { Write-Host "  Missing: $FuncMailboxName" -ForegroundColor Red }
    if (-not $QueueDbExists) { Write-Host "  Missing: $FuncQueueDbName" -ForegroundColor Red }
    if (-not $CuQueueDbExists) { Write-Host "  Missing: $FuncCuQueueDbName" -ForegroundColor Red }
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

$CuQueueDbIdentity = (Invoke-AzCliSilent -Arguments @('functionapp','identity','show','--name',$FuncCuQueueDbName,'--resource-group',$ResourceGroupName,'--query','principalId','-o','tsv')).Output
if ($CuQueueDbIdentity) {
    Write-Host "[OK] Managed identity already enabled for $FuncCuQueueDbName" -ForegroundColor Green
} else {
    Write-Host "[INFO] Enabling managed identity for $FuncCuQueueDbName" -ForegroundColor Cyan
    Invoke-AzCliSilent -Arguments @('functionapp','identity','assign','--name',$FuncCuQueueDbName,'--resource-group',$ResourceGroupName,'--output','none') | Out-Null
    $CuQueueDbIdentity = (Invoke-AzCliSilent -Arguments @('functionapp','identity','show','--name',$FuncCuQueueDbName,'--resource-group',$ResourceGroupName,'--query','principalId','-o','tsv')).Output
    Write-Host "[SUCCESS] Managed identity enabled for $FuncCuQueueDbName" -ForegroundColor Green
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

if (-not $MailboxIdentity -or -not $QueueDbIdentity -or -not $CuQueueDbIdentity -or -not $WebAppIdentity) {
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
    foreach ($identity in @($MailboxIdentity, $QueueDbIdentity, $CuQueueDbIdentity)) {
        if (-not (Set-RoleAssignment -Assignee $identity -Role 'Key Vault Secrets User' -Scope $KeyVaultId -PrincipalType 'ServicePrincipal')) { $newAssignments++ }
    }

    Write-Host "[INFO] Key Vault Secrets Officer role for web app profile updates" -ForegroundColor Cyan
    if (-not (Set-RoleAssignment -Assignee $WebAppIdentity -Role 'Key Vault Secrets Officer' -Scope $KeyVaultId -PrincipalType 'ServicePrincipal')) { $newAssignments++ }
}

# Service Bus access
$ServiceBusId = (Invoke-AzCliSilent -Arguments @('servicebus','namespace','show','--name',$ServiceBusNamespace,'--resource-group',$ResourceGroupName,'--query','id','-o','tsv')).Output

Write-Host "[INFO] Service Bus roles for function apps" -ForegroundColor Cyan
if (-not (Set-RoleAssignment -Assignee $MailboxIdentity   -Role 'Azure Service Bus Data Sender'   -Scope $ServiceBusId -PrincipalType 'ServicePrincipal')) { $newAssignments++ }
if (-not (Set-RoleAssignment -Assignee $QueueDbIdentity   -Role 'Azure Service Bus Data Receiver' -Scope $ServiceBusId -PrincipalType 'ServicePrincipal')) { $newAssignments++ }
if (-not (Set-RoleAssignment -Assignee $CuQueueDbIdentity -Role 'Azure Service Bus Data Receiver' -Scope $ServiceBusId -PrincipalType 'ServicePrincipal')) { $newAssignments++ }

# Storage account access (managed identity for AzureWebJobsStorage)
$StorageAccountId = (Invoke-AzCliSilent -Arguments @('storage','account','show','--name',$StorageAccountName,'--resource-group',$ResourceGroupName,'--query','id','-o','tsv')).Output

Write-Host "[INFO] Storage account roles for function apps" -ForegroundColor Cyan
foreach ($identity in @($MailboxIdentity, $QueueDbIdentity, $CuQueueDbIdentity)) {
    foreach ($role in @('Storage Blob Data Owner','Storage Account Contributor','Storage Queue Data Contributor','Storage Table Data Contributor')) {
        if (-not (Set-RoleAssignment -Assignee $identity -Role $role -Scope $StorageAccountId -PrincipalType 'ServicePrincipal')) { $newAssignments++ }
    }
}

Write-Host "[INFO] Storage roles for web app" -ForegroundColor Cyan
if (-not (Set-RoleAssignment -Assignee $WebAppIdentity -Role 'Storage Blob Data Reader'        -Scope $StorageAccountId -PrincipalType 'ServicePrincipal')) { $newAssignments++ }
if (-not (Set-RoleAssignment -Assignee $WebAppIdentity -Role 'Storage Table Data Contributor' -Scope $StorageAccountId -PrincipalType 'ServicePrincipal')) { $newAssignments++ }

# Admin user needs blob access for container creation and direct blob operations
if ($CurrentUserId) {
    Write-Host "[INFO] Storage Blob Data Contributor for admin user" -ForegroundColor Cyan
    if (-not (Set-RoleAssignment -Assignee $CurrentUserId -Role 'Storage Blob Data Contributor' -Scope $StorageAccountId -PrincipalType 'User')) { $newAssignments++ }
}

# Content Understanding needs to read blobs from Storage when given a blob URL
if ($CuIdentity) {
    Write-Host "[INFO] Storage Blob Data Reader for Content Understanding" -ForegroundColor Cyan
    if (-not (Set-RoleAssignment -Assignee $CuIdentity -Role 'Storage Blob Data Reader' -Scope $StorageAccountId -PrincipalType 'ServicePrincipal')) { $newAssignments++ }
}

# Cosmos DB access (data plane RBAC - Built-in Data Contributor)
$CosmosDbAccountId = (Invoke-AzCliSilent -Arguments @('cosmosdb','show','--name',$CosmosDbAccountName,'--resource-group',$ResourceGroupName,'--query','id','-o','tsv')).Output
$CosmosDataContributorRoleId = "00000000-0000-0000-0000-000000000002"

Write-Host "[INFO] Cosmos DB Data Contributor role for function apps and web app" -ForegroundColor Cyan
foreach ($identity in @($MailboxIdentity, $QueueDbIdentity, $CuQueueDbIdentity, $WebAppIdentity)) {
    if (-not (Set-CosmosRoleAssignment -AccountName $CosmosDbAccountName -ResourceGroup $ResourceGroupName -RoleDefinitionId $CosmosDataContributorRoleId -PrincipalId $identity -Scope $CosmosDbAccountId)) { $newAssignments++ }
}

# Content Understanding access (Cognitive Services User)
$ContentUnderstandingId = (Invoke-AzCliSilent -Arguments @('cognitiveservices','account','show','--name',$ContentUnderstandingName,'--resource-group',$ResourceGroupName,'--query','id','-o','tsv')).Output

Write-Host "[INFO] Cognitive Services User role for function apps and web app" -ForegroundColor Cyan
foreach ($identity in @($MailboxIdentity, $QueueDbIdentity, $CuQueueDbIdentity, $WebAppIdentity)) {
    if (-not (Set-RoleAssignment -Assignee $identity -Role 'Cognitive Services User' -Scope $ContentUnderstandingId -PrincipalType 'ServicePrincipal')) { $newAssignments++ }
}

# AI Foundry access
# - Cognitive Services OpenAI User : chat completions / embeddings (function apps + web app)
# - Azure AI Developer (account)    : Agents API — account-level grant
# - Azure AI Developer (project)    : Agents API — project-level grant (required by Foundry portal RBAC)
$AiFoundryId      = (Invoke-AzCliSilent -Arguments @('cognitiveservices','account','show','--name',$AiFoundryName,'--resource-group',$ResourceGroupName,'--query','id','-o','tsv')).Output
$AiFoundryProjectId = "$AiFoundryId/projects/$AiFoundryProjectName"

Write-Host "[INFO] Cognitive Services OpenAI User role for function apps and web app" -ForegroundColor Cyan
foreach ($identity in @($MailboxIdentity, $QueueDbIdentity, $CuQueueDbIdentity, $WebAppIdentity)) {
    if (-not (Set-RoleAssignment -Assignee $identity -Role 'Cognitive Services OpenAI User' -Scope $AiFoundryId -PrincipalType 'ServicePrincipal')) { $newAssignments++ }
}

Write-Host "[INFO] Azure AI Developer role for web app — account scope" -ForegroundColor Cyan
if (-not (Set-RoleAssignment -Assignee $WebAppIdentity -Role 'Azure AI Developer' -Scope $AiFoundryId        -PrincipalType 'ServicePrincipal')) { $newAssignments++ }
Write-Host "[INFO] Azure AI Developer role for web app — project scope" -ForegroundColor Cyan
if (-not (Set-RoleAssignment -Assignee $WebAppIdentity -Role 'Azure AI Developer' -Scope $AiFoundryProjectId -PrincipalType 'ServicePrincipal')) { $newAssignments++ }

# The Responses API for project-scoped Prompt Agents also requires the AIServices
# data-plane permission supplied by the custom role created by 3.deploy-agents.ps1.
$EiaAgentWriterRoleName = "EIA AI Foundry Agent Writer $Environment $Suffix"
$EiaAgentWriterRoleId = (Invoke-AzCliSilent -Arguments @('role','definition','list','--name',$EiaAgentWriterRoleName,'--query','[0].id','-o','tsv')).Output
if ($EiaAgentWriterRoleId) {
    Write-Host "[INFO] Custom Foundry agent writer role for web app — account and project scope" -ForegroundColor Cyan
    if (-not (Set-RoleAssignment -Assignee $WebAppIdentity -Role $EiaAgentWriterRoleId -Scope $AiFoundryId -PrincipalType 'ServicePrincipal')) { $newAssignments++ }
    if (-not (Set-RoleAssignment -Assignee $WebAppIdentity -Role $EiaAgentWriterRoleId -Scope $AiFoundryProjectId -PrincipalType 'ServicePrincipal')) { $newAssignments++ }
} else {
    Write-Host "[WARNING] Custom Foundry agent writer role '$EiaAgentWriterRoleName' is not present; run 3.deploy-agents.ps1 before deploying the UI." -ForegroundColor Yellow
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
    $purgeResult = Invoke-AzCliSilent -Arguments @('keyvault','secret','purge','--vault-name',$KeyVaultName,'--name','deployment-test')
}

# Secret recovery and purge are asynchronous. Do not race the data plane with
# secret set; wait until the previous deleted-state operation has settled.
if ($purgeResult.ExitCode -eq 0) {
    for ($recoveryAttempt = 1; $recoveryAttempt -le 12; $recoveryAttempt++) {
        $secretState = Invoke-AzCliSilent -Arguments @('keyvault','secret','show',
            '--vault-name',$KeyVaultName,'--name','deployment-test','--query','id','-o','tsv')
        if ($secretState.ExitCode -eq 0 -and $secretState.Output) {
            Write-Host "[INFO] Temporary Key Vault secret recovery completed." -ForegroundColor DarkCyan
            break
        }
        Write-Host "[INFO] Waiting for Key Vault secret recovery/purge to settle ($recoveryAttempt/12)..." -ForegroundColor DarkCyan
        Start-Sleep -Seconds 5
    }
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
# Project endpoint required by the Azure AI Agents SDK (AgentsClient)
$AiFoundryProjectEndpoint = "https://$AiFoundryName.services.ai.azure.com/api/projects/$AiFoundryProjectName"

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
    "WebAppTenantId"             = $TenantId
    "WebAppClientId"             = $WebAppClientId
    "WebAppClientSecret"         = $WebAppClientSecret
    "CosmosDbEndpoint"           = $CosmosDbEndpoint
    "CosmosDbDatabaseName"       = $CosmosDbDatabaseName
    "CosmosDbContainerName"               = $CosmosDbContainerName
    "ContentUnderstandingEndpoint"          = $ContentUnderstandingEndpoint
    "ContentUnderstandingCompletionModel"     = $CuCompletionModelName
    "ContentUnderstandingEmbeddingModel"      = $CuEmbeddingModelName
    "AiFoundryEndpoint"                     = $AiFoundryEndpoint
    "AiFoundryProjectEndpoint"              = $AiFoundryProjectEndpoint
    "AiFoundryDeploymentName"               = $AiFoundryDeploymentName
    "AiFoundryModelName"                    = $AiFoundryModelName
    "AiFoundryApiVersion"                   = $AiFoundryApiVersion
    "AiFoundryEmbeddingsDeploymentName"     = $AiFoundryEmbeddingsDeploymentName
    "AiFoundryEmbeddingsModelName"          = $AiFoundryEmbeddingsModelName
    "StorageEndpoint"                       = $StorageBlobEndpoint
    "StorageTableEndpoint"                  = $StorageTableEndpoint
    "StorageContainerName"                  = $StorageContainerName
    "StorageQueueName"                      = $StorageQueueName
    "StorageQueuePollingSchedule"            = $StorageQueuePollingSchedule
    "UserEmailAddress"                       = $UserEmailAddress
    "PollingMailboxName"                     = $PollingMailboxName
    "ReadMailboxForPastNSeconds"             = $ReadMailboxForPastNSeconds
}
foreach ($entry in $kvSecrets.GetEnumerator()) {
    if ([string]::IsNullOrWhiteSpace([string]$entry.Value)) {
        Write-Host "[WARNING] Skipping Key Vault secret '$($entry.Key)' - value is empty" -ForegroundColor Yellow
        continue
    }
    $secretRetries = 6
    $secretSucceeded = $false
    for ($secretAttempt = 1; $secretAttempt -le $secretRetries; $secretAttempt++) {
        $secretFile = [System.IO.Path]::GetTempFileName()
        try {
            Set-Content -Path $secretFile -Value $entry.Value -NoNewline -Encoding utf8
            $r = Invoke-AzCliSilent -Arguments @('keyvault','secret','set','--vault-name',$KeyVaultName,'--name',$entry.Key,'--file',$secretFile,'--encoding','utf-8','--output','none')
        } finally {
            Remove-Item $secretFile -Force -ErrorAction SilentlyContinue
        }
        if ($r.ExitCode -eq 0) {
            $secretSucceeded = $true
            break
        }
        if ($secretAttempt -lt $secretRetries) {
            Write-Host "[INFO] Key Vault secret '$($entry.Key)' is not ready (attempt $secretAttempt/$secretRetries). Retrying in 5 seconds..." -ForegroundColor DarkCyan
            Start-Sleep -Seconds 5
        }
    }
    if (-not $secretSucceeded) {
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

# Switch function apps from key-based to identity-based storage access.
# The platform auto-provisions AzureWebJobsStorage (connection string) and
# DEPLOYMENT_STORAGE_CONNECTION_STRING (account key) at creation time, but the
# storage account has allowSharedKeyAccess=false.  We must:
#   1. Delete the key-based AzureWebJobsStorage and DEPLOYMENT_STORAGE_CONNECTION_STRING app settings
#   2. Update functionAppConfig.deployment.storage.authentication to SystemAssignedIdentity via ARM
Write-Host "[INFO] Switching function apps to identity-based storage (runtime + deployment)" -ForegroundColor Cyan
foreach ($funcName in @($FuncMailboxName, $FuncQueueDbName, $FuncCuQueueDbName)) {
    # Remove key-based app settings (idempotent — silently succeeds if already absent)
    Invoke-AzCliSilent -Arguments @('functionapp','config','appsettings','delete','--name',$funcName,'--resource-group',$ResourceGroupName,'--setting-names','AzureWebJobsStorage','DEPLOYMENT_STORAGE_CONNECTION_STRING','--output','none') | Out-Null

    # Ensure deployment storage uses SystemAssignedIdentity (not StorageAccountConnectionString)
    $siteJson = Invoke-AzCliSilent -Arguments @('rest','--method','GET',
        '--url',"/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$funcName`?api-version=2024-04-01",
        '-o','json')
    if ($siteJson.ExitCode -ne 0) {
        Write-Host "[WARNING] Could not read site config for $funcName – skipping deployment storage switch" -ForegroundColor Yellow
        continue
    }
    $site = $siteJson.Output | ConvertFrom-Json
    $currentAuth = $site.properties.functionAppConfig.deployment.storage.authentication.type
    if ($currentAuth -eq 'SystemAssignedIdentity') {
        Write-Host "[OK] Already identity-based for $funcName" -ForegroundColor Green
        continue
    }
    $site.properties.functionAppConfig.deployment.storage.authentication.type = 'SystemAssignedIdentity'
    $site.properties.functionAppConfig.deployment.storage.authentication.storageAccountConnectionStringName = $null
    $patchBody = $site | ConvertTo-Json -Depth 20 -Compress
    $patchFile = [System.IO.Path]::GetTempFileName()
    [System.IO.File]::WriteAllText($patchFile, $patchBody, [System.Text.Encoding]::UTF8)
    $patchResult = Invoke-AzCliSilent -Arguments @('rest','--method','PUT',
        '--url',"/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$funcName`?api-version=2024-04-01",
        '--body',"@$patchFile",'--output','none')
    Remove-Item $patchFile -Force -ErrorAction SilentlyContinue
    if ($patchResult.ExitCode -ne 0) {
        Write-Host "[ERROR] Failed to switch deployment storage for $funcName" -ForegroundColor Red
        $script:DeploymentErrors.Add("Deployment storage: $funcName")
    } else {
        Write-Host "[SUCCESS] Switched to identity-based for $funcName" -ForegroundColor Green
    }
}

# Note: FUNCTIONS_WORKER_RUNTIME and FUNCTIONS_EXTENSION_VERSION are managed by the platform
# on Flex Consumption plans and must NOT be set as app settings.
$mailboxSettings = @{
    "AzureWebJobsStorage__accountName" = $StorageAccountName
    "AzureWebJobsStorage__credential"  = "managedidentity"
    "AZURE_KEY_VAULT_URL"              = $KvUrl
    "MailboxPollingSchedule"           = "@Microsoft.KeyVault(VaultName=$KeyVaultName;SecretName=MailboxPollingSchedule)"
}
$r1 = Set-FunctionAppSettings -FunctionAppName $FuncMailboxName -ResourceGroup $ResourceGroupName -Settings $mailboxSettings
if ($r1.ExitCode -ne 0) {
    Write-Host "[ERROR] Failed to configure settings for $FuncMailboxName" -ForegroundColor Red
    if ($r1.Error) { Write-Host "  $($r1.Error)" -ForegroundColor Red }
    $script:DeploymentErrors.Add("Function app settings: $FuncMailboxName")
} elseif (Test-ContainsKeyVaultReferences -Settings $mailboxSettings) {
    $mailboxResourceId = (Invoke-AzCliSilent -Arguments @('functionapp','show','--name',$FuncMailboxName,'--resource-group',$ResourceGroupName,'--query','id','-o','tsv')).Output
    if ($mailboxResourceId) {
        Invoke-ConfigReferenceRefresh -ResourceId $mailboxResourceId -DisplayName $FuncMailboxName | Out-Null
    }
}

$ServiceBusHostname = "$ServiceBusNamespace.servicebus.windows.net"
$queueDbSettings = @{
    "AzureWebJobsStorage__accountName"              = $StorageAccountName
    "AzureWebJobsStorage__credential"               = "managedidentity"
    "AZURE_KEY_VAULT_URL"                           = $KvUrl
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

$cuQueueDbSettings = @{
    "AzureWebJobsStorage__accountName"          = $StorageAccountName
    "AzureWebJobsStorage__credential"           = "managedidentity"
    "AZURE_KEY_VAULT_URL"                       = $KvUrl
    "StorageQueuePollingSchedule"               = "@Microsoft.KeyVault(VaultName=$KeyVaultName;SecretName=StorageQueuePollingSchedule)"
}
$r3cu = Set-FunctionAppSettings -FunctionAppName $FuncCuQueueDbName -ResourceGroup $ResourceGroupName -Settings $cuQueueDbSettings
if ($r3cu.ExitCode -ne 0) {
    Write-Host "[ERROR] Failed to configure settings for $FuncCuQueueDbName" -ForegroundColor Red
    if ($r3cu.Error) { Write-Host "  $($r3cu.Error)" -ForegroundColor Red }
    $script:DeploymentErrors.Add("Function app settings: $FuncCuQueueDbName")
} elseif (Test-ContainsKeyVaultReferences -Settings $cuQueueDbSettings) {
    $cuQueueResourceId = (Invoke-AzCliSilent -Arguments @('functionapp','show','--name',$FuncCuQueueDbName,'--resource-group',$ResourceGroupName,'--query','id','-o','tsv')).Output
    if ($cuQueueResourceId) {
        Invoke-ConfigReferenceRefresh -ResourceId $cuQueueResourceId -DisplayName $FuncCuQueueDbName | Out-Null
    }
}

Write-Host "[SUCCESS] Function App settings configured" -ForegroundColor Green

# =============================================================================
# Configure Web App Settings
# =============================================================================
Write-Host "[INFO] Configuring Web App settings..." -ForegroundColor Cyan

$webAppSettingsPayload = @{
    properties = @{
        "AZURE_KEY_VAULT_URL"      = $KvUrl
        "USER_PROFILE_SECRET_NAME"  = "UserProfiles"
        # OIDC sign-in for end users (Spring Security). Renamed away from AZURE_* so
        # DefaultAzureCredential.EnvironmentCredential does NOT pick them up — the
        # app's system-assigned managed identity is used for Azure data-plane access.
        "TENANT_ID"                = "@Microsoft.KeyVault(VaultName=$KeyVaultName;SecretName=WebAppTenantId)"
        "WEBAPP_CLIENT_ID"         = "@Microsoft.KeyVault(VaultName=$KeyVaultName;SecretName=WebAppClientId)"
        "WEBAPP_CLIENT_SECRET"     = "@Microsoft.KeyVault(VaultName=$KeyVaultName;SecretName=WebAppClientSecret)"
        # Concrete data-plane endpoints (avoid KV-reference resolution issues).
        "COSMOS_ENDPOINT"          = "https://$CosmosDbAccountName.documents.azure.com:443/"
        "COSMOS_DATABASE_NAME"     = $CosmosDbDatabaseName
        "COSMOS_CONTAINER_NAME"    = $CosmosDbContainerName
        "STORAGE_ENDPOINT"         = "https://$StorageAccountName.blob.core.windows.net/"
        "STORAGE_CONTAINER_NAME"   = $StorageContainerName
        # Reasoning effort for the o-series model: low / medium / high / xhigh (default: medium)
        "AI_FOUNDRY_REASONING_EFFORT" = "medium"
        # Sliding TTL (hours) for agent conversations — reset on each access (default: 168 = 7 days)
        "AGENT_CONVERSATION_TTL_HOURS" = "168"
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
    Invoke-ConfigReferenceRefresh -ResourceId $webAppResourceId -DisplayName $WebAppName | Out-Null
}

# =============================================================================
# STEP 13: Multi-Agent Orchestrator Service (agent-service)
# =============================================================================
# Isolated VNet + Flex Consumption function app for the multi-agent framework's
# orchestrator endpoint, kept separate from extract/functions/* per
# MULTIAGENT_FRAMEWORK_DESIGN.md "Implementation & Deployment Plan" item 4.
Write-Host ""
Write-Host ">>> Step 13: Multi-Agent Orchestrator Service (agent-service)" -ForegroundColor White

# Dedicated VNet + subnet (outbound VNet integration), isolated from other workloads
if (Test-AzResource -Arguments @('network','vnet','show','--name',$AgentServiceVNetName,'--resource-group',$ResourceGroupName,'--query','name','-o','tsv')) {
    Write-Host "[WARNING] VNet $AgentServiceVNetName already exists, skipping" -ForegroundColor Yellow
} else {
    $result = Invoke-AzCli -Description "Creating VNet: $AgentServiceVNetName" `
        -Arguments @('network','vnet','create','--name',$AgentServiceVNetName,
                     '--resource-group',$ResourceGroupName,'--location',$LocationFunctionApp,
                     '--address-prefix',$AgentServiceVNetAddressSpace,
                     '--subnet-name',$AgentServiceSubnetName,'--subnet-prefix',$AgentServiceSubnetAddressSpace,
                     '--tags',"project=$ProjectName","environment=$Environment","app=agent-service",$SecurityControlTag,
                     '--output','table')
    if ($null -ne $result) {
        Write-Host "[SUCCESS] VNet $AgentServiceVNetName created" -ForegroundColor Green
    }
}

# Delegate the subnet to Microsoft.Web/serverFarms so a function app can VNet-integrate into it
Invoke-AzCliSilent -Arguments @('network','vnet','subnet','update','--name',$AgentServiceSubnetName,
                     '--vnet-name',$AgentServiceVNetName,'--resource-group',$ResourceGroupName,
                     '--delegations','Microsoft.Web/serverFarms','--output','none') | Out-Null

# Flex Consumption function app — its own isolated compute (Flex Consumption is
# per-app serverless, so no shared App Service Plan resource is needed for isolation)
if (Test-AzResource -Arguments @('functionapp','show','--name',$FuncAgentServiceName,'--resource-group',$ResourceGroupName,'--query','name','-o','tsv')) {
    Write-Host "[WARNING] Function app $FuncAgentServiceName already exists, skipping" -ForegroundColor Yellow
} else {
    $result = Invoke-AzCli -Description "Creating function app: $FuncAgentServiceName" `
        -Arguments (@('functionapp','create','--name',$FuncAgentServiceName) + $CommonFuncArgs + @(
                     '--tags',"project=$ProjectName","environment=$Environment","app=agent-service",$SecurityControlTag,
                     '--output','table'))
    if ($null -ne $result) {
        Write-Host "[SUCCESS] Function app $FuncAgentServiceName created" -ForegroundColor Green
    }
}

# Attach outbound VNet integration to the dedicated subnet
Invoke-AzCliSilent -Arguments @('functionapp','vnet-integration','add','--name',$FuncAgentServiceName,
                     '--resource-group',$ResourceGroupName,
                     '--vnet',$AgentServiceVNetName,'--subnet',$AgentServiceSubnetName,'--output','none') | Out-Null

# Managed identity
$AgentServiceIdentity = (Invoke-AzCliSilent -Arguments @('functionapp','identity','show','--name',$FuncAgentServiceName,'--resource-group',$ResourceGroupName,'--query','principalId','-o','tsv')).Output
if ($AgentServiceIdentity) {
    Write-Host "[OK] Managed identity already enabled for $FuncAgentServiceName" -ForegroundColor Green
} else {
    Write-Host "[INFO] Enabling managed identity for $FuncAgentServiceName" -ForegroundColor Cyan
    Invoke-AzCliSilent -Arguments @('functionapp','identity','assign','--name',$FuncAgentServiceName,'--resource-group',$ResourceGroupName,'--output','none') | Out-Null
    $AgentServiceIdentity = (Invoke-AzCliSilent -Arguments @('functionapp','identity','show','--name',$FuncAgentServiceName,'--resource-group',$ResourceGroupName,'--query','principalId','-o','tsv')).Output
    Write-Host "[SUCCESS] Managed identity enabled for $FuncAgentServiceName" -ForegroundColor Green
}

if (-not $AgentServiceIdentity) {
    Write-Host "[ERROR] Could not retrieve managed identity for $FuncAgentServiceName. Skipping its RBAC assignments." -ForegroundColor Red
    $script:DeploymentErrors.Add("Managed identity: $FuncAgentServiceName")
} else {
    # Key Vault: read framework config/tunables
    if ($KeyVaultId) {
        Write-Host "[INFO] Key Vault Secrets User role for agent-service" -ForegroundColor Cyan
        Set-RoleAssignment -Assignee $AgentServiceIdentity -Role 'Key Vault Secrets User' -Scope $KeyVaultId -PrincipalType 'ServicePrincipal' | Out-Null
    }

    # Storage: AgentCatalog / OrchestrationState / OrchestratorConversations tables
    Write-Host "[INFO] Storage roles for agent-service" -ForegroundColor Cyan
    foreach ($role in @('Storage Blob Data Owner','Storage Queue Data Contributor','Storage Table Data Contributor')) {
        Set-RoleAssignment -Assignee $AgentServiceIdentity -Role $role -Scope $StorageAccountId -PrincipalType 'ServicePrincipal' | Out-Null
    }

    # AI Foundry: invoking the orchestrator/worker/jury prompt agents (Responses API)
    Write-Host "[INFO] Cognitive Services OpenAI User role for agent-service" -ForegroundColor Cyan
    Set-RoleAssignment -Assignee $AgentServiceIdentity -Role 'Cognitive Services OpenAI User' -Scope $AiFoundryId -PrincipalType 'ServicePrincipal' | Out-Null
    Write-Host "[INFO] Azure AI Developer role for agent-service — account scope" -ForegroundColor Cyan
    Set-RoleAssignment -Assignee $AgentServiceIdentity -Role 'Azure AI Developer' -Scope $AiFoundryId -PrincipalType 'ServicePrincipal' | Out-Null
    Write-Host "[INFO] Azure AI Developer role for agent-service — project scope" -ForegroundColor Cyan
    Set-RoleAssignment -Assignee $AgentServiceIdentity -Role 'Azure AI Developer' -Scope $AiFoundryProjectId -PrincipalType 'ServicePrincipal' | Out-Null
}

# Create the Entra application used as the agent-service API audience. The UI's
# managed identity receives a token for this audience; Easy Auth below restricts
# accepted callers to that identity.
$AgentServiceApiClientId = (Invoke-AzCliSilent -Arguments @('ad','app','list','--display-name',$AgentServiceApiAppName,'--query','[0].appId','-o','tsv')).Output
if (-not $AgentServiceApiClientId) {
    $AgentServiceApiClientId = (Invoke-AzCliSilent -Arguments @('ad','app','create','--display-name',$AgentServiceApiAppName,'--sign-in-audience','AzureADMyOrg','--query','appId','-o','tsv')).Output
    if (-not $AgentServiceApiClientId) {
        Write-Host "[ERROR] Could not create Entra API application $AgentServiceApiAppName" -ForegroundColor Red
        $script:DeploymentErrors.Add("Entra API application: $AgentServiceApiAppName")
    }
}
if ($AgentServiceApiClientId) {
    Invoke-AzCliSilent -Arguments @('ad','app','update','--id',$AgentServiceApiClientId,
        '--identifier-uris',"api://$AgentServiceApiClientId") | Out-Null
    $AgentServiceApiObjectId = (Invoke-AzCliSilent -Arguments @('ad','app','show','--id',$AgentServiceApiClientId,'--query','id','-o','tsv')).Output
    $AgentServiceApiSpId = (Invoke-AzCliSilent -Arguments @('ad','sp','list','--filter',"appId eq '$AgentServiceApiClientId'",'--query','[0].id','-o','tsv')).Output
    if (-not $AgentServiceApiSpId) {
        $AgentServiceApiSpId = (Invoke-AzCliSilent -Arguments @('ad','sp','create','--id',$AgentServiceApiClientId,'--query','id','-o','tsv')).Output
    }

    # Add one application permission so the UI managed identity can request
    # api://<client-id>/.default without a static secret.
    $AgentServiceInvokeRoleId = '6f8f7d7e-0ef8-4f34-9ea4-6f0d0f2ab301'
    if ($AgentServiceApiObjectId) {
        $existingApp = Invoke-AzCliSilent -Arguments @('rest','--method','GET',
            '--url',"https://graph.microsoft.com/v1.0/applications/$AgentServiceApiObjectId`?`$select=appRoles",'--output','json')
        $existingRoles = @()
        if ($existingApp.ExitCode -eq 0 -and $existingApp.Output) {
            try { $existingRoles = @((($existingApp.Output | ConvertFrom-Json).appRoles)) } catch { $existingRoles = @() }
        }
        if (-not ($existingRoles | Where-Object { [string]$_.id -eq $AgentServiceInvokeRoleId })) {
            $invokeRole = [pscustomobject]@{
                allowedMemberTypes = @('Application')
                description = 'Allows the EIA web app managed identity to invoke the multi-agent service.'
                displayName = 'Invoke multi-agent service'
                id = $AgentServiceInvokeRoleId
                isEnabled = $true
                value = 'agent.service.invoke'
            }
            $appRoleBody = @{ appRoles = @($existingRoles) + @($invokeRole) } | ConvertTo-Json -Depth 10 -Compress
            $appRoleFile = [System.IO.Path]::GetTempFileName()
            Set-Content -Path $appRoleFile -Value $appRoleBody -Encoding UTF8
            $roleResult = Invoke-AzCliSilent -Arguments @('rest','--method','PATCH',
                '--url',"https://graph.microsoft.com/v1.0/applications/$AgentServiceApiObjectId",
                '--body',"@$appRoleFile",'--output','none')
            Remove-Item $appRoleFile -Force -ErrorAction SilentlyContinue
            if ($roleResult.ExitCode -ne 0) {
                Write-Host "[ERROR] Failed to configure agent-service application role" -ForegroundColor Red
                $script:DeploymentErrors.Add("Entra API application role: $AgentServiceApiAppName")
            }
        }
    }
}

# Configure App Service Authentication (Easy Auth) on agent-service. The function
# bindings remain anonymous because Easy Auth validates the bearer token first.
$WebAppIdentityClientId = (Invoke-AzCliSilent -Arguments @('webapp','identity','show','--name',$WebAppName,'--resource-group',$ResourceGroupName,'--query','clientId','-o','tsv')).Output
if ($AgentServiceApiClientId -and $WebAppIdentityClientId) {
    if ($AgentServiceApiSpId -and $WebAppIdentity -and $AgentServiceInvokeRoleId) {
        $assignmentBody = @{
            principalId = $WebAppIdentity
            resourceId = $AgentServiceApiSpId
            appRoleId = $AgentServiceInvokeRoleId
        } | ConvertTo-Json -Compress
        $assignmentFile = [System.IO.Path]::GetTempFileName()
        Set-Content -Path $assignmentFile -Value $assignmentBody -Encoding UTF8
        $assignmentResult = Invoke-AzCliSilent -Arguments @('rest','--method','POST',
            '--url',"https://graph.microsoft.com/v1.0/servicePrincipals/$AgentServiceApiSpId/appRoleAssignedTo",
            '--body',"@$assignmentFile",'--output','none')
        Remove-Item $assignmentFile -Force -ErrorAction SilentlyContinue
        if ($assignmentResult.ExitCode -ne 0 -and $assignmentResult.Error -notmatch 'already exist|already assigned') {
            Write-Host "[ERROR] Failed to assign agent-service application role to the UI identity" -ForegroundColor Red
            $script:DeploymentErrors.Add("Entra API role assignment: UI -> agent-service")
        }
    }
    $authPayload = @{
        properties = @{
            platform = @{ enabled = $true }
            globalValidation = @{
                unauthenticatedClientAction = 'Return401'
                redirectToProvider = $null
            }
            identityProviders = @{
                azureActiveDirectory = @{
                    enabled = $true
                    registration = @{
                        clientId = $AgentServiceApiClientId
                        openIdIssuer = "https://login.microsoftonline.com/$TenantId/v2.0"
                    }
                    validation = @{
                        allowedAudiences = @("api://$AgentServiceApiClientId")
                        allowedApplications = @($WebAppIdentityClientId)
                    }
                }
            }
            login = @{ tokenStore = @{ enabled = $false } }
        }
    } | ConvertTo-Json -Depth 20 -Compress
    $authFile = [System.IO.Path]::GetTempFileName()
    Set-Content -Path $authFile -Value $authPayload -Encoding UTF8
    $authResult = Invoke-AzCliSilent -Arguments @('rest','--method','PUT',
        '--url',"https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$FuncAgentServiceName/config/authsettingsV2?api-version=2022-03-01",
        '--body',"@$authFile",'--output','none')
    Remove-Item $authFile -Force -ErrorAction SilentlyContinue
    if ($authResult.ExitCode -ne 0) {
        Write-Host "[ERROR] Failed to configure Entra authentication for $FuncAgentServiceName" -ForegroundColor Red
        $script:DeploymentErrors.Add("Easy Auth: $FuncAgentServiceName")
    } else {
        Write-Host "[SUCCESS] Entra authentication configured for $FuncAgentServiceName" -ForegroundColor Green
    }
}

# App settings: KeyVaultUrl (read by OrchestratorHolder.get() via System.getenv), plus
# identity-based storage for the Functions host itself.
$agentServiceSettings = @{
    "AzureWebJobsStorage__accountName" = $StorageAccountName
    "AzureWebJobsStorage__credential"  = "managedidentity"
    "KeyVaultUrl"                      = $KvUrl
}
$rAgentSvc = Set-FunctionAppSettings -FunctionAppName $FuncAgentServiceName -ResourceGroup $ResourceGroupName -Settings $agentServiceSettings
if ($rAgentSvc.ExitCode -ne 0) {
    Write-Host "[ERROR] Failed to configure settings for $FuncAgentServiceName" -ForegroundColor Red
    if ($rAgentSvc.Error) { Write-Host "  $($rAgentSvc.Error)" -ForegroundColor Red }
    $script:DeploymentErrors.Add("Function app settings: $FuncAgentServiceName")
} else {
    Write-Host "[SUCCESS] agent-service settings configured" -ForegroundColor Green
}

# Multi-agent framework config/tunables (see MULTIAGENT_FRAMEWORK_DESIGN.md "Configuration (Key Vault)").
# Seeded here so OrchestratorAgent.fromKeyVault() works even before 3.deploy-agents.ps1 runs;
# agent name secrets are overwritten by createAgent() with the same default values.
$multiAgentSecrets = @{
    "MultiAgentOrchestratorAgentName" = $MultiAgentOrchestratorAgentName
    "MultiAgentJuryAgentName"         = $MultiAgentJuryAgentName
    "MultiAgentJuryTieMargin"         = $MultiAgentJuryTieMargin
    "MultiAgentJuryMinDispatchScore"  = $MultiAgentJuryMinDispatchScore
    "MultiAgentJuryMaxCandidates"     = $MultiAgentJuryMaxCandidates
    "MultiAgentTaskMaxRetries"        = $MultiAgentTaskMaxRetries
    "MultiAgentTaskMaxTotalCalls"     = $MultiAgentTaskMaxTotalCalls
    "MultiAgentAsyncStateTtlDays"     = $MultiAgentAsyncStateTtlDays
}
foreach ($entry in $multiAgentSecrets.GetEnumerator()) {
    $r = Invoke-AzCliSilent -Arguments @('keyvault','secret','set','--vault-name',$KeyVaultName,'--name',$entry.Key,'--value',$entry.Value,'--output','none')
    if ($r.ExitCode -ne 0) {
        Write-Host "[ERROR] Failed to set Key Vault secret: $($entry.Key)" -ForegroundColor Red
        $script:DeploymentErrors.Add("Key Vault secret: $($entry.Key)")
    }
}
Write-Host "[SUCCESS] Multi-agent framework config seeded in Key Vault" -ForegroundColor Green

# The URL and API client ID are configuration, not credentials. The UI obtains
# its bearer token through its own managed identity at request time.
$agentServiceUrl = "https://$FuncAgentServiceName.azurewebsites.net/api/orchestrate"
if ($AgentServiceApiClientId) {
    $uiAgentSettings = @{
        "MULTI_AGENT_SERVICE_URL" = $agentServiceUrl
        "MULTI_AGENT_SERVICE_API_CLIENT_ID" = $AgentServiceApiClientId
    }
    $uiAgentSettingsResult = Invoke-AzCliSilent -Arguments @('webapp','config','appsettings','set',
        '--name',$WebAppName,'--resource-group',$ResourceGroupName,
        '--settings',"MULTI_AGENT_SERVICE_URL=$agentServiceUrl","MULTI_AGENT_SERVICE_API_CLIENT_ID=$AgentServiceApiClientId",
        '--output','none')
    if ($uiAgentSettingsResult.ExitCode -ne 0) {
        Write-Host "[ERROR] Failed to configure UI multi-agent settings" -ForegroundColor Red
        $script:DeploymentErrors.Add("UI multi-agent settings")
    } else {
        Write-Host "[SUCCESS] UI configured for Managed Identity access to agent-service" -ForegroundColor Green
    }
}

# =============================================================================
# Final Cosmos vector-search completion phase
# =============================================================================
# Cosmos vector capability propagation can take about 15 minutes. All other
# infrastructure is provisioned before this blocking phase begins. If the
# capability becomes ready, finish EmailExtracts with the vector policy/index.
if (-not $vectorSearchEnabled) {
    Write-Host ""
    Write-Host ">>> Final phase: waiting for Cosmos vector search capability" -ForegroundColor White
    Write-Host "[INFO] Other infrastructure is complete. Keeping this script running while Cosmos vector search propagates (up to 15 minutes)..." -ForegroundColor Cyan

    for ($i = 1; $i -le 90 -and -not $vectorSearchEnabled; $i++) {
        $check = (Invoke-AzCliSilent -Arguments @('cosmosdb','show','--name',$CosmosDbAccountName,
            '--resource-group',$ResourceGroupName,
            '--query',"capabilities[?name=='EnableNoSQLVectorSearch'].name",'-o','tsv')).Output
        if ($check) {
            $vectorSearchEnabled = $true
            Write-Host "[SUCCESS] Cosmos vector search capability is ready." -ForegroundColor Green
            break
        }
        Write-Host "[INFO] Vector capability not ready yet ($i/90). Checking again in 10 seconds..." -ForegroundColor DarkCyan
        Start-Sleep -Seconds 10
    }

    if ($vectorSearchEnabled) {
        $finalIndexingPolicyJson = @{
            indexingMode = "consistent"
            automatic = $true
            includedPaths = @(@{ path = "/*" })
            excludedPaths = @(@{ path = '/"_etag"/?' })
            vectorIndexes = @(@{ path = "/embedding"; type = "quantizedFlat" })
            fullTextIndexes = @(
                @{ path = "/subject" }
                @{ path = "/bodyContent" }
            )
        } | ConvertTo-Json -Depth 10 -Compress
        $finalIndexPolicyFile = [System.IO.Path]::GetTempFileName()
        $finalVectorPolicyFile = [System.IO.Path]::GetTempFileName()
        $finalFullTextPolicyFile = [System.IO.Path]::GetTempFileName()
        Set-Content -Path $finalIndexPolicyFile -Value $finalIndexingPolicyJson -Encoding utf8
        Set-Content -Path $finalVectorPolicyFile -Value $vectorEmbeddingPolicyJson -Encoding utf8
        Set-Content -Path $finalFullTextPolicyFile -Value $fullTextPolicyJson -Encoding utf8
        try {
            $finalVectorResult = Invoke-AzCliSilent -Arguments @('cosmosdb','sql','container','update',
                '--account-name',$CosmosDbAccountName,
                '--resource-group',$ResourceGroupName,
                '--database-name',$CosmosDbDatabaseName,
                '--name',$CosmosDbContainerName,
                '--idx',"@$finalIndexPolicyFile",
                '--vector-embeddings',"@$finalVectorPolicyFile",
                '--full-text-policy',"@$finalFullTextPolicyFile",
                '--output','none')
            if ($finalVectorResult.ExitCode -eq 0) {
                Write-Host "[SUCCESS] EmailExtracts vector embedding policy and index completed." -ForegroundColor Green
            } else {
                Write-Host "[ERROR] Cosmos vector capability is ready, but the EmailExtracts vector policy update failed: $($finalVectorResult.Error)" -ForegroundColor Red
                $script:DeploymentErrors.Add("Cosmos vector policy finalization: $CosmosDbContainerName")
            }
        } finally {
            Remove-Item $finalIndexPolicyFile, $finalVectorPolicyFile, $finalFullTextPolicyFile -Force -ErrorAction SilentlyContinue
        }
    } else {
        Write-Host "[WARNING] Cosmos vector search was not ready after 15 minutes. EmailExtracts remains full-text-only; rerun this deployment later to complete vector indexing." -ForegroundColor Yellow
    }
}

# =============================================================================
# Cleanup: remove the temporary deployment-test secret used for KV access validation
# =============================================================================
Write-Host "[INFO] Cleaning up temporary Key Vault secrets..." -ForegroundColor Cyan
$delResult = Invoke-AzCliSilent -Arguments @('keyvault','secret','delete','--vault-name',$KeyVaultName,'--name','deployment-test','--output','none')
if ($delResult.ExitCode -eq 0) {
    # Wait briefly, then purge so it doesn't linger in soft-delete
    Start-Sleep -Seconds 5
    Invoke-AzCliSilent -Arguments @('keyvault','secret','purge','--vault-name',$KeyVaultName,'--name','deployment-test','--output','none') | Out-Null
    Write-Host "[OK] Temporary secret 'deployment-test' removed" -ForegroundColor Green
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
    Write-Host "  Function (CU-Queue) : $FuncCuQueueDbName"
    Write-Host "  Function (Agent Svc): $FuncAgentServiceName"
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
    Write-Host "  Function (CU-Queue) : $FuncCuQueueDbName"
    Write-Host "  Function (Agent Svc): $FuncAgentServiceName"
    Write-Host "  Graph API App ID    : $GraphClientId"
    Write-Host "  Content Understanding: $ContentUnderstandingName"
    Write-Host "  AI Foundry          : $AiFoundryName"
    Write-Host "  AI Foundry Model    : $AiFoundryDeploymentName"
    Write-Host "  App Insights        : $AppInsightsName"
    Write-Host "[SUCCESS] ==========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "[INFO] Next Steps:" -ForegroundColor Cyan
    Write-Host "  1. Grant Graph API admin consent (requires tenant admin role):"
    Write-Host "       .\2.grant-graph-consent.ps1 -Suffix $Suffix"
    Write-Host "  2. Build and provision the Azure AI Foundry agents:"
    Write-Host "       .\3.deploy-agents.ps1 -Suffix $Suffix"
    Write-Host "  3. Register Content Understanding analyzer schemas:"
    Write-Host "       .\4.content-understanding-add-schema.ps1 -Suffix $Suffix"
    Write-Host "  4. Build and deploy application code (functions + web app):"
    Write-Host "       .\5.deploy-code.ps1 -Suffix $Suffix"
    Write-Host "  5. Choose the environment posture (run last, after everything is deployed):"
    Write-Host "       - Dev  : open access + grant the signed-in user data-plane RBAC for local testing"
    Write-Host "                .\6.operation-dev.ps1 -Suffix $Suffix"
    Write-Host "       - Prod : harden the network (private endpoints, disable public access)"
    Write-Host "                .\6.operation-prod.ps1 -Suffix $Suffix"
    Write-Host "  6. Test the deployment with sample data"
}

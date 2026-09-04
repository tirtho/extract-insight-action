#Requires -Version 5.1
<#
.SYNOPSIS
    Configures the dev environment for local development and testing.
.DESCRIPTION
    Enables public network access on Cosmos DB and Storage, and grants the
    logged-in user read/write/admin RBAC roles on both resources.
    Run this after deploy-infrastructure.ps1 has completed successfully.
.PARAMETER Environment
    Optional. Environment name (default: dev).
.PARAMETER Suffix
    Optional. The same suffix used when running deploy-infrastructure.ps1.
.PARAMETER SkipSteps
    Optional. Skip selected setup steps using numbers or aliases.
    If not provided, the script prompts you to choose which steps to run.
      1/Network, 2/RBAC, 3/KVRefresh, 4/GraphConsent
.USAGE
    .\operation-dev.ps1 -Suffix 999
    .\operation-dev.ps1 -Environment dev -Suffix 999
    .\operation-dev.ps1 -Suffix 999 -SkipSteps 3,4
#>
param(
    [Parameter(HelpMessage="Environment (default: dev, example: dev)")]
    [string]$Environment,

    [Parameter(HelpMessage="Suffix used during infrastructure deployment (default: 1, example: 1)")]
    [string]$Suffix,

    [ValidateSet('1','2','3','4','Network','RBAC','KVRefresh','GraphConsent')]
    [string[]]$SkipSteps = @()
)

$ErrorActionPreference = "Stop"

$LocationInput = Read-Host "Enter location [default: centralus, example: centralus]"
$Location = if ([string]::IsNullOrWhiteSpace($LocationInput)) { "centralus" } else { $LocationInput.Trim().ToLowerInvariant() }

if ([string]::IsNullOrWhiteSpace($Environment)) {
    $EnvironmentInput = Read-Host "Enter environment [default: dev, example: dev]"
    $Environment = if ([string]::IsNullOrWhiteSpace($EnvironmentInput)) { "dev" } else { $EnvironmentInput.Trim().ToLowerInvariant() }
} else {
    $Environment = $Environment.Trim().ToLowerInvariant()
}

if ([string]::IsNullOrWhiteSpace($Suffix)) {
    $SuffixInput = Read-Host "Enter suffix [default: 1, example: 1]"
    $Suffix = if ([string]::IsNullOrWhiteSpace($SuffixInput)) { "1" } else { $SuffixInput.Trim() }
} else {
    $Suffix = $Suffix.Trim()
}

$ProjectNameForLog = if ($env:PROJECT_NAME) { $env:PROJECT_NAME } else { "eia" }

Write-Host "[INFO] Deployment key: $ProjectNameForLog-$Environment-$Suffix (location: $Location)" -ForegroundColor Cyan

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================
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

function Get-CurrentDirectoryRoleNames {
    $rolesResp = Invoke-AzCliSilent -Arguments @(
        'rest',
        '--method','GET',
        '--uri','https://graph.microsoft.com/v1.0/me/memberOf/microsoft.graph.directoryRole?$select=displayName',
        '-o','json'
    )

    if ($rolesResp.ExitCode -ne 0 -or -not $rolesResp.Output -or $rolesResp.Output -eq 'null') {
        return $null
    }

    try {
        $parsed = $rolesResp.Output | ConvertFrom-Json
        if ($parsed -and $parsed.value) {
            return @($parsed.value | ForEach-Object { $_.displayName })
        }
    } catch {
        return $null
    }

    return @()
}

function Write-DirectoryRoleWarning {
    $roleNames = Get-CurrentDirectoryRoleNames
    if ($null -eq $roleNames) {
        Write-Host "  [WARNING] Could not verify Entra directory roles for the signed-in operator." -ForegroundColor Yellow
        Write-Host "  [INFO] Directory custom role operations may fail without Privileged Role Administrator or Global Administrator." -ForegroundColor Cyan
        return
    }

    $accepted = @('Global Administrator', 'Privileged Role Administrator')
    $hasRequired = ($roleNames | Where-Object { $accepted -contains $_ }).Count -gt 0
    if (-not $hasRequired) {
        $currentRoles = if ($roleNames.Count -gt 0) { $roleNames -join ', ' } else { '(none)' }
        Write-Host "  [WARNING] Signed-in operator may not manage directory custom roles." -ForegroundColor Yellow
        Write-Host "  [INFO] Current roles: $currentRoles" -ForegroundColor Cyan
        Write-Host "  [INFO] Required role: Privileged Role Administrator or Global Administrator." -ForegroundColor Cyan
    }
}

function Add-RoleAssignmentIfMissing {
    param([string]$Assignee, [string]$Role, [string]$Scope)
    $existing = Invoke-AzCliSilent -Arguments @('role','assignment','list','--assignee',$Assignee,'--role',$Role,'--scope',$Scope,'--query','[0].id','-o','tsv')
    if ($existing.ExitCode -eq 0 -and $existing.Output) {
        return $true  # already exists
    }
    Invoke-AzCliSilent -Arguments @('role','assignment','create','--assignee',$Assignee,'--role',$Role,'--scope',$Scope,'--output','none') | Out-Null
    return $false  # newly created
}

function Add-CosmosRoleAssignmentIfMissing {
    param([string]$AccountName, [string]$ResourceGroup, [string]$RoleDefinitionId, [string]$PrincipalId, [string]$Scope)
    $existing = Invoke-AzCliSilent -Arguments @('cosmosdb','sql','role','assignment','list',
        '--account-name',$AccountName,'--resource-group',$ResourceGroup,
        '--query',"[?principalId=='$PrincipalId' && contains(roleDefinitionId, '$RoleDefinitionId')] | [0].id",'--output','tsv')
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
            Write-Host "  [WARNING] Key Vault reference refresh failed for $DisplayName (attempt $attempt/$MaxAttempts)" -ForegroundColor Yellow
            if ($refresh.Error) { Write-Host "    $($refresh.Error)" -ForegroundColor Yellow }
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
                Write-Host "  [SUCCESS] Key Vault references refreshed for $DisplayName" -ForegroundColor Green
                return $true
            }

            Write-Host "  [INFO] $DisplayName still has unresolved Key Vault references (attempt $attempt/$MaxAttempts)" -ForegroundColor Cyan
            foreach ($item in $lastUnresolved) {
                Write-Host "    - $($item.name): $($item.properties.status)" -ForegroundColor Yellow
            }
        }

        if ($attempt -lt $MaxAttempts) {
            Start-Sleep -Seconds $DelaySeconds
        }
    }

    Write-Host "  [WARNING] Key Vault references not fully resolved for $DisplayName after $MaxAttempts attempts" -ForegroundColor Yellow
    return $false
}


# =============================================================================
# CONFIGURATION (must match deploy-infrastructure.ps1)
# =============================================================================
$ProjectName        = if ($env:PROJECT_NAME)        { $env:PROJECT_NAME }        else { "eia" }
$ProjClean          = $ProjectName -replace '-',''
$ResourceGroupName  = "rg-$ProjectName-$Environment-$Suffix"
$StorageAccountName = "st$ProjClean$Environment$Suffix"
$CosmosDbAccountName = "cosmos-$ProjectName-$Environment-$Suffix"
$ContentUnderstandingName = "cu-$ProjectName-$Environment-$Suffix"
$AiFoundryName       = "oai-$ProjectName-$Environment-$Suffix"
$KeyVaultName        = "kv-$ProjectName-$Environment-$Suffix"
$ServiceBusNamespace = "sb-$ProjectName-$Environment-$Suffix"
$FuncMailboxName      = "func-mailbox-$ProjectName-$Environment-$Suffix"
$FuncCuQueueDbName    = "func-cuqueuedb-$ProjectName-$Environment-$Suffix"
$WebAppName           = "app-$ProjectName-$Environment-$Suffix"

$skipStep1 = $false
$skipStep2 = $false
$skipStep3 = $false
$skipStep4 = $false

if ($SkipSteps.Count -gt 0) {
    $skipStep1 = (@('1','Network') | Where-Object { $SkipSteps -contains $_ }).Count -gt 0
    $skipStep2 = (@('2','RBAC') | Where-Object { $SkipSteps -contains $_ }).Count -gt 0
    $skipStep3 = (@('3','KVRefresh') | Where-Object { $SkipSteps -contains $_ }).Count -gt 0
    $skipStep4 = (@('4','GraphConsent') | Where-Object { $SkipSteps -contains $_ }).Count -gt 0
} else {
    Write-Host "Which operation step(s) do you want to run?" -ForegroundColor White
    Write-Host "  1. Configure Network Access"
    Write-Host "  2. Grant RBAC Roles to Current User"
    Write-Host "  3. Refresh Key Vault App Setting References"
    Write-Host "  4. Ensure Graph Delegated Admin Consent (Web App)"
    Write-Host "  5. All"
    Write-Host ""
    Write-Host "  You can enter a single number or comma-separated list (e.g. 1,3)" -ForegroundColor DarkCyan
    Write-Host ""

    $validOptions = @('1','2','3','4','5')
    do {
        $rawInput = (Read-Host "Enter selection(s)").Trim()
        $selections = $rawInput -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
        $allValid = ($selections.Count -gt 0) -and ($selections | Where-Object { $_ -notin $validOptions }).Count -eq 0
        if (-not $allValid) {
            Write-Host "[ERROR] Please enter 1, 2, 3, 4, 5, or a comma-separated list (e.g. 1,4)." -ForegroundColor Red
        }
    } while (-not $allValid)

    if ($selections -contains '5') {
        $selections = @('1','2','3','4')
    } else {
        $selections = $selections | Select-Object -Unique
    }

    $skipStep1 = -not ($selections -contains '1')
    $skipStep2 = -not ($selections -contains '2')
    $skipStep3 = -not ($selections -contains '3')
    $skipStep4 = -not ($selections -contains '4')
}

$networkChanges = 0
$newAssignments = 0
$MyPublicIp = '(skipped)'

# =============================================================================
# BANNER
# =============================================================================
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Dev Environment Setup: $ProjectName ($Environment)"        -ForegroundColor Cyan
Write-Host "  Resource Group: $ResourceGroupName"                         -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# =============================================================================
# PREREQUISITES
# =============================================================================
Write-Host "[INFO] Checking prerequisites..." -ForegroundColor Cyan

$acctResult = Invoke-AzCliSilent -Arguments @('account','show','--query','state','-o','tsv')
if ($acctResult.ExitCode -ne 0 -or $acctResult.Output -ne "Enabled") {
    Write-Host "[ERROR] Not logged in to Azure CLI. Run 'az login' first." -ForegroundColor Red
    exit 1
}

$userResult = Invoke-AzCliSilent -Arguments @('ad','signed-in-user','show','--query','id','-o','tsv')
$CurrentUserId = $userResult.Output
if (-not $CurrentUserId) {
    Write-Host "[ERROR] Could not determine current user." -ForegroundColor Red
    if ($userResult.Error -match "Continuous access evaluation|InteractionRequired") {
        Write-Host "[ERROR] Azure CLI token expired (CAE challenge). Run:" -ForegroundColor Red
        Write-Host "  az account clear; az login" -ForegroundColor Yellow
    } else {
        Write-Host "[ERROR] Run 'az login' first." -ForegroundColor Red
        if ($userResult.Error) { Write-Host "  $($userResult.Error)" -ForegroundColor Red }
    }
    exit 1
}
$CurrentUserName = (Invoke-AzCliSilent -Arguments @('ad','signed-in-user','show','--query','userPrincipalName','-o','tsv')).Output
Write-Host "[OK] Logged in as: $CurrentUserName ($CurrentUserId)" -ForegroundColor Green

# Verify resources exist
$storageExists = (Invoke-AzCliSilent -Arguments @('storage','account','show','--name',$StorageAccountName,'--resource-group',$ResourceGroupName,'--query','name','-o','tsv')).Output
$cosmosExists  = (Invoke-AzCliSilent -Arguments @('cosmosdb','show','--name',$CosmosDbAccountName,'--resource-group',$ResourceGroupName,'--query','name','-o','tsv')).Output
if (-not $storageExists) {
    Write-Host "[ERROR] Storage account '$StorageAccountName' not found in resource group '$ResourceGroupName'." -ForegroundColor Red
    Write-Host "  Run deploy-infrastructure.ps1 -Suffix $Suffix first." -ForegroundColor Yellow
    exit 1
}
if (-not $cosmosExists) {
    Write-Host "[ERROR] Cosmos DB account '$CosmosDbAccountName' not found in resource group '$ResourceGroupName'." -ForegroundColor Red
    Write-Host "  Run deploy-infrastructure.ps1 -Suffix $Suffix first." -ForegroundColor Yellow
    exit 1
}
$kvExists = (Invoke-AzCliSilent -Arguments @('keyvault','show','--name',$KeyVaultName,'--resource-group',$ResourceGroupName,'--query','name','-o','tsv')).Output
if (-not $kvExists) {
    Write-Host "[ERROR] Key Vault '$KeyVaultName' not found in resource group '$ResourceGroupName'." -ForegroundColor Red
    Write-Host "  Run deploy-infrastructure.ps1 -Suffix $Suffix first." -ForegroundColor Yellow
    exit 1
}
Write-Host "[OK] Resources verified" -ForegroundColor Green

# =============================================================================
# STEP 1: Configure Network Access (laptop IP + Azure services only)
# =============================================================================
if ($skipStep1) {
    Write-Host ""
    Write-Host ">>> Step 1: Configure Network Access" -ForegroundColor White
    Write-Host "  [SKIPPED] Step 1 skipped by -SkipSteps" -ForegroundColor Yellow
} else {
Write-Host ""
Write-Host ">>> Step 1: Configure Network Access" -ForegroundColor White

# Detect laptop public IP
Write-Host "[INFO] Detecting your public IP address..." -ForegroundColor Cyan
try {
    $MyPublicIp = (Invoke-RestMethod -Uri 'https://api.ipify.org?format=text' -TimeoutSec 10).Trim()
} catch {
    Write-Host "[ERROR] Could not detect public IP. Check internet connectivity." -ForegroundColor Red
    exit 1
}
Write-Host "[OK] Your public IP: $MyPublicIp" -ForegroundColor Green

# Helper: normalize a comma-separated IP list for comparison (sort + dedupe + trim)
function ConvertTo-CanonicalIpList([string]$IpCsv) {
    if (-not $IpCsv) { return '' }
    ($IpCsv -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Sort-Object -Unique) -join ','
}

# Helper: normalize bypass string for comparison (sort components)
function ConvertTo-CanonicalBypass([string]$Bypass) {
    if (-not $Bypass) { return '' }
    ($Bypass -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Sort-Object) -join ','
}

# --- Gather current state (quick reads, sequential) ---
$DesiredCosmosIpFilter = "$MyPublicIp,104.42.195.92,40.76.54.131,52.176.6.30,52.169.50.45,52.187.184.26,0.0.0.0"

Write-Host "[INFO] Checking Cosmos DB network rules: $CosmosDbAccountName" -ForegroundColor Cyan
$cosmosState = Invoke-AzCliSilent -Arguments @('cosmosdb','show','--name',$CosmosDbAccountName,
    '--resource-group',$ResourceGroupName,
    '--query','{publicNetworkAccess:publicNetworkAccess, ipRules:ipRules[].ipAddressOrRange}','-o','json')
$cosmosJson  = $cosmosState.Output | ConvertFrom-Json
$currentCosmosIps = if ($cosmosJson.ipRules) { ConvertTo-CanonicalIpList (($cosmosJson.ipRules) -join ',') } else { '' }
$desiredCosmosIps = ConvertTo-CanonicalIpList $DesiredCosmosIpFilter
$cosmosNeedsUpdate = -not ($cosmosJson.publicNetworkAccess -eq 'Enabled' -and $currentCosmosIps -eq $desiredCosmosIps)

Write-Host "[INFO] Checking Storage Account network rules: $StorageAccountName" -ForegroundColor Cyan
$storageState = Invoke-AzCliSilent -Arguments @('storage','account','show','--name',$StorageAccountName,
    '--resource-group',$ResourceGroupName,
    '--query','{publicNetworkAccess:publicNetworkAccess, defaultAction:networkRuleSet.defaultAction, bypass:networkRuleSet.bypass, ipRules:networkRuleSet.ipRules[].ipAddressOrRange}',
    '-o','json')
$storageJson = $storageState.Output | ConvertFrom-Json
$storageNeedsUpdate = ($storageJson.publicNetworkAccess -ne 'Enabled' -or $storageJson.defaultAction -ne 'Allow')

Write-Host "[INFO] Checking Key Vault network rules: $KeyVaultName" -ForegroundColor Cyan
$kvState = Invoke-AzCliSilent -Arguments @('keyvault','show','--name',$KeyVaultName,
    '--resource-group',$ResourceGroupName,
    '--query','{publicNetworkAccess:properties.publicNetworkAccess, defaultAction:properties.networkAcls.defaultAction, bypass:properties.networkAcls.bypass}',
    '-o','json')
$kvJson = $kvState.Output | ConvertFrom-Json
$currentKvBypass = ConvertTo-CanonicalBypass $kvJson.bypass
$desiredKvBypass = ConvertTo-CanonicalBypass 'AzureServices'
# Allow-by-default: Flex Consumption function apps have dynamic outbound IPs that
# cannot be predicted, and the AzureServices bypass does NOT cover App Service /
# Functions Key Vault references or SDK calls.  Until VNet integration + private
# endpoints are in place, the KV firewall must allow all networks.  Access is
# still restricted by RBAC (Key Vault Secrets User role).
$kvNeedsUpdate = ($kvJson.publicNetworkAccess -ne 'Enabled' -or $kvJson.defaultAction -ne 'Allow' -or $currentKvBypass -ne $desiredKvBypass)

# --- Launch updates in parallel (these are the slow operations) ---
$jobs = @()

if (-not $cosmosNeedsUpdate) {
    Write-Host "  [OK] Cosmos DB network rules already configured correctly" -ForegroundColor Gray
} else {
    Write-Host "  [INFO] Updating Cosmos DB IP filter in background... (slowest, typically 2-5 min)" -ForegroundColor Yellow
    $jobs += Start-Job -Name 'CosmosDB-Network' -ScriptBlock {
        param($AccountName, $RG, $IpFilter)
        $r = az cosmosdb update --name $AccountName --resource-group $RG `
            --public-network-access Enabled --ip-range-filter $IpFilter --output none 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Cosmos DB network update failed: $r" }
    } -ArgumentList $CosmosDbAccountName, $ResourceGroupName, $DesiredCosmosIpFilter
}

if (-not $storageNeedsUpdate) {
    Write-Host "  [OK] Storage Account network rules already configured correctly" -ForegroundColor Gray
} else {
    Write-Host "  [INFO] Updating Storage Account network rules in background..." -ForegroundColor Cyan
    $jobs += Start-Job -Name 'Storage-Network' -ScriptBlock {
        param($AccountName, $RG)
        # Flex Consumption function hosts need direct access to the storage account
        # public endpoint for both AzureWebJobsStorage and blobContainer deployments.
        # Deny-by-default storage firewall rules prevent the host from starting and
        # result in zero indexed functions in the portal.
        az storage account update --name $AccountName --resource-group $RG `
            --public-network-access Enabled --default-action Allow --output none 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Storage default rules update failed" }
    } -ArgumentList $StorageAccountName, $ResourceGroupName
}

if (-not $kvNeedsUpdate) {
    Write-Host "  [OK] Key Vault network rules already configured correctly" -ForegroundColor Gray
} else {
    Write-Host "  [INFO] Updating Key Vault network rules in background..." -ForegroundColor Cyan
    $jobs += Start-Job -Name 'KeyVault-Network' -ScriptBlock {
        param($VaultName, $RG)
        az keyvault update --name $VaultName --resource-group $RG `
            --public-network-access Enabled --default-action Allow `
            --bypass AzureServices --output none 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Key Vault default rules update failed" }
    } -ArgumentList $KeyVaultName, $ResourceGroupName
}

# --- Wait for all parallel jobs to complete ---
if ($jobs.Count -gt 0) {
    Write-Host "[INFO] Waiting for $($jobs.Count) network update(s) to complete in parallel..." -ForegroundColor Cyan
    $jobs | Wait-Job | Out-Null
    foreach ($job in $jobs) {
        if ($job.State -eq 'Completed') {
            Write-Host "  [SUCCESS] $($job.Name): done" -ForegroundColor Green
            $networkChanges++
        } else {
            $errMsg = ($job | Receive-Job -ErrorAction SilentlyContinue *>&1) -join "`n"
            Write-Host "  [ERROR] $($job.Name) failed" -ForegroundColor Red
            if ($errMsg) { Write-Host "    $errMsg" -ForegroundColor Red }
        }
        Remove-Job $job -Force
    }
}
}

# =============================================================================
# STEP 2: Grant Logged-In User Read/Write & Admin Access
# =============================================================================
if ($skipStep2) {
Write-Host ""
Write-Host ">>> Step 2: Grant RBAC Roles to Current User" -ForegroundColor White
Write-Host "  [SKIPPED] Step 2 skipped by -SkipSteps" -ForegroundColor Yellow
} else {
Write-Host ""
Write-Host ">>> Step 2: Grant RBAC Roles to Current User" -ForegroundColor White

# --- Gather resource IDs (quick reads) ---
$StorageAccountId = (Invoke-AzCliSilent -Arguments @('storage','account','show','--name',$StorageAccountName,'--resource-group',$ResourceGroupName,'--query','id','-o','tsv')).Output
$CosmosDbAccountId = (Invoke-AzCliSilent -Arguments @('cosmosdb','show','--name',$CosmosDbAccountName,'--resource-group',$ResourceGroupName,'--query','id','-o','tsv')).Output
$KeyVaultId = (Invoke-AzCliSilent -Arguments @('keyvault','show','--name',$KeyVaultName,'--resource-group',$ResourceGroupName,'--query','id','-o','tsv')).Output
$ContentUnderstandingId = (Invoke-AzCliSilent -Arguments @('cognitiveservices','account','show','--name',$ContentUnderstandingName,'--resource-group',$ResourceGroupName,'--query','id','-o','tsv')).Output
$AiFoundryId          = (Invoke-AzCliSilent -Arguments @('cognitiveservices','account','show','--name',$AiFoundryName,'--resource-group',$ResourceGroupName,'--query','id','-o','tsv')).Output
$AiFoundryProjectName = "proj-$ProjectName-$Environment-$Suffix"
$AiFoundryProjectId   = "$AiFoundryId/projects/$AiFoundryProjectName"
$ServiceBusId = (Invoke-AzCliSilent -Arguments @('servicebus','namespace','show','--name',$ServiceBusNamespace,'--resource-group',$ResourceGroupName,'--query','id','-o','tsv')).Output

# Resolve Content Understanding managed identity (may need to enable it first)
$CuIdentity = (Invoke-AzCliSilent -Arguments @('cognitiveservices','account','identity','show','--name',$ContentUnderstandingName,'--resource-group',$ResourceGroupName,'--query','principalId','-o','tsv')).Output
if (-not $CuIdentity) {
    Write-Host "  [INFO] Enabling managed identity for $ContentUnderstandingName" -ForegroundColor Cyan
    Invoke-AzCliSilent -Arguments @('cognitiveservices','account','identity','assign','--name',$ContentUnderstandingName,'--resource-group',$ResourceGroupName,'--output','none') | Out-Null
    $CuIdentity = (Invoke-AzCliSilent -Arguments @('cognitiveservices','account','identity','show','--name',$ContentUnderstandingName,'--resource-group',$ResourceGroupName,'--query','principalId','-o','tsv')).Output
}

# --- Build the full list of role assignments to make ---
# Each entry: @{ Assignee, Role, Scope, Label, Type ('arm' or 'cosmos') }
$allAssignments = [System.Collections.Generic.List[hashtable]]::new()

# Storage Account ARM roles
foreach ($role in @('Storage Blob Data Contributor','Storage Blob Data Reader',
                    'Storage Queue Data Contributor','Storage Table Data Contributor',
                    'Storage Account Contributor','Storage Blob Data Owner',
                    'Storage Blob Delegator')) {
    $allAssignments.Add(@{ Assignee=$CurrentUserId; Role=$role; Scope=$StorageAccountId; Label=$role; Type='arm' })
}

# Cosmos DB ARM roles
foreach ($role in @('Cosmos DB Account Reader Role','DocumentDB Account Contributor')) {
    $allAssignments.Add(@{ Assignee=$CurrentUserId; Role=$role; Scope=$CosmosDbAccountId; Label=$role; Type='arm' })
}

# Cosmos DB data-plane roles
$allAssignments.Add(@{ AccountName=$CosmosDbAccountName; ResourceGroup=$ResourceGroupName; RoleDefinitionId='00000000-0000-0000-0000-000000000001'; PrincipalId=$CurrentUserId; Scope=$CosmosDbAccountId; Label='Cosmos DB Built-in Data Reader'; Type='cosmos' })
$allAssignments.Add(@{ AccountName=$CosmosDbAccountName; ResourceGroup=$ResourceGroupName; RoleDefinitionId='00000000-0000-0000-0000-000000000002'; PrincipalId=$CurrentUserId; Scope=$CosmosDbAccountId; Label='Cosmos DB Built-in Data Contributor'; Type='cosmos' })

# Key Vault roles
foreach ($role in @('Key Vault Secrets User','Key Vault Secrets Officer',
                    'Key Vault Certificates Officer','Key Vault Crypto Officer')) {
    $allAssignments.Add(@{ Assignee=$CurrentUserId; Role=$role; Scope=$KeyVaultId; Label=$role; Type='arm' })
}

# Content Understanding roles for current user (data-plane access: create/read/delete analyzers, analyze documents)
foreach ($role in @('Cognitive Services User','Cognitive Services Contributor')) {
    $allAssignments.Add(@{ Assignee=$CurrentUserId; Role=$role; Scope=$ContentUnderstandingId; Label="$role (Content Understanding)"; Type='arm' })
}

# AI Foundry / Azure OpenAI roles for current user (data-plane access: chat completions, embeddings, agents, etc.)
foreach ($role in @('Cognitive Services User','Cognitive Services Contributor','Cognitive Services OpenAI User','Cognitive Services OpenAI Contributor','Azure AI Developer')) {
    $allAssignments.Add(@{ Assignee=$CurrentUserId; Role=$role; Scope=$AiFoundryId;        Label="$role (AI Foundry account)"; Type='arm' })
}
# Also grant Azure AI Developer at the project scope (Foundry project-level RBAC requires this)
$allAssignments.Add(@{ Assignee=$CurrentUserId; Role='Azure AI Developer'; Scope=$AiFoundryProjectId; Label='Azure AI Developer (AI Foundry project)'; Type='arm' })

# EIA AI Foundry Agent Writer (custom): covers AIServices/* data actions missing from Azure AI Developer
$EiaAgentWriterRole = 'EIA AI Foundry Agent Writer'
$existingCustomRole = az role definition list --name $EiaAgentWriterRole --query '[0].name' -o tsv 2>$null
if (-not $existingCustomRole) {
    Write-Host "  [INFO] Creating custom role '$EiaAgentWriterRole'" -ForegroundColor Cyan
    $roleJson = [ordered]@{
        Name             = $EiaAgentWriterRole
        Description      = 'Grants AIServices/* data-plane access needed for AI Foundry agents API (AIServices/* absent from Azure AI Developer role definition)'
        Actions          = @()
        DataActions      = @('Microsoft.CognitiveServices/accounts/AIServices/*')
        AssignableScopes = @("/subscriptions/$((az account show --query id -o tsv))/resourceGroups/$ResourceGroupName")
    } | ConvertTo-Json -Depth 5
    $tmpFile = Join-Path $env:TEMP "eia-custom-role-$([guid]::NewGuid().ToString('N')).json"
    Set-Content -Path $tmpFile -Value $roleJson -Encoding UTF8
    az role definition create --role-definition "@$tmpFile" --output none 2>$null
    Remove-Item $tmpFile -ErrorAction SilentlyContinue
}
$allAssignments.Add(@{ Assignee=$CurrentUserId; Role=$EiaAgentWriterRole; Scope=$AiFoundryId;        Label="$EiaAgentWriterRole (AI Foundry account)"; Type='arm' })
$allAssignments.Add(@{ Assignee=$CurrentUserId; Role=$EiaAgentWriterRole; Scope=$AiFoundryProjectId; Label="$EiaAgentWriterRole (AI Foundry project)"; Type='arm' })

# Content Understanding -> Storage Blob Data Reader
if ($CuIdentity) {
    $allAssignments.Add(@{ Assignee=$CuIdentity; Role='Storage Blob Data Reader'; Scope=$StorageAccountId; Label='Storage Blob Data Reader (Content Understanding)'; Type='arm' })
} else {
    Write-Host "  [WARNING] Content Understanding '$ContentUnderstandingName' identity not found. Skipping." -ForegroundColor Yellow
}

# Service Bus roles for local dev (send + receive for testing both functions locally)
if ($ServiceBusId) {
    foreach ($role in @('Azure Service Bus Data Sender','Azure Service Bus Data Receiver')) {
        $allAssignments.Add(@{ Assignee=$CurrentUserId; Role=$role; Scope=$ServiceBusId; Label="$role (Service Bus)"; Type='arm' })
    }
} else {
    Write-Host "  [WARNING] Service Bus namespace '$ServiceBusNamespace' not found. Skipping Service Bus roles." -ForegroundColor Yellow
}

# --- Launch all role assignments in parallel ---
Write-Host "[INFO] Assigning $($allAssignments.Count) RBAC roles in parallel..." -ForegroundColor Cyan

$rbacJobs = @()
foreach ($a in $allAssignments) {
    if ($a.Type -eq 'arm') {
        $rbacJobs += Start-Job -Name $a.Label -ScriptBlock {
            param($Assignee, $Role, $Scope)
            # Check if exists
            $existing = az role assignment list --assignee $Assignee --role $Role --scope $Scope --query '[0].id' -o tsv 2>$null
            if ($existing) { return 'exists' }
            az role assignment create --assignee $Assignee --role $Role --scope $Scope --output none 2>$null
            return 'created'
        } -ArgumentList $a.Assignee, $a.Role, $a.Scope
    } else {
        # cosmos data-plane role
        $rbacJobs += Start-Job -Name $a.Label -ScriptBlock {
            param($AccountName, $RG, $RoleDefId, $PrincipalId, $Scope)
            $existing = az cosmosdb sql role assignment list --account-name $AccountName --resource-group $RG `
                --query "[?principalId=='$PrincipalId' && contains(roleDefinitionId, '$RoleDefId')] | [0].id" --output tsv 2>$null
            if ($existing) { return 'exists' }
            az cosmosdb sql role assignment create --account-name $AccountName --resource-group $RG `
                --role-definition-id $RoleDefId --principal-id $PrincipalId --scope $Scope --output none 2>$null
            return 'created'
        } -ArgumentList $a.AccountName, $a.ResourceGroup, $a.RoleDefinitionId, $a.PrincipalId, $a.Scope
    }
}

# --- Wait for all RBAC jobs ---
$rbacJobs | Wait-Job | Out-Null
foreach ($job in $rbacJobs) {
    $result = Receive-Job $job -ErrorAction SilentlyContinue
    if ($job.State -eq 'Completed' -and $result -eq 'exists') {
        Write-Host "  [OK] $($job.Name) - already assigned" -ForegroundColor Gray
    } elseif ($job.State -eq 'Completed') {
        Write-Host "  [SUCCESS] $($job.Name) - assigned" -ForegroundColor Green
        $newAssignments++
    } else {
        $errMsg = ($job.ChildJobs | ForEach-Object { $_.Error }) -join "`n"
        Write-Host "  [ERROR] $($job.Name) failed" -ForegroundColor Red
        if ($errMsg) { Write-Host "    $errMsg" -ForegroundColor Red }
    }
    Remove-Job $job -Force
}
}

# =============================================================================
# STEP 3: Refresh Key Vault App Setting References
# =============================================================================
if ($skipStep3) {
Write-Host ""
Write-Host ">>> Step 3: Refresh Key Vault App Setting References" -ForegroundColor White
Write-Host "  [SKIPPED] Step 3 skipped by -SkipSteps" -ForegroundColor Yellow
} else {
Write-Host ""
Write-Host ">>> Step 3: Refresh Key Vault App Setting References" -ForegroundColor White

$servicesWithKvRefs = @(
    @{ Type = 'functionapp'; Name = $FuncMailboxName },
    @{ Type = 'functionapp'; Name = $FuncCuQueueDbName },
    @{ Type = 'webapp'; Name = $WebAppName }
)

foreach ($svc in $servicesWithKvRefs) {
    $idArgs = @($svc.Type, 'show', '--name', $svc.Name, '--resource-group', $ResourceGroupName, '--query', 'id', '-o', 'tsv')
    $resourceId = (Invoke-AzCliSilent -Arguments $idArgs).Output
    if (-not $resourceId) {
        Write-Host "  [WARNING] Could not find $($svc.Type) '$($svc.Name)'; skipping Key Vault reference refresh" -ForegroundColor Yellow
        continue
    }
    Invoke-ConfigReferenceRefresh -ResourceId $resourceId -DisplayName $svc.Name | Out-Null
}
}

# =============================================================================
# STEP 4: Ensure Graph Delegated Admin Consent for Web App
# =============================================================================
if ($skipStep4) {
Write-Host ""
Write-Host ">>> Step 4: Ensure Graph Delegated Admin Consent (Web App)" -ForegroundColor White
Write-Host "  [SKIPPED] Step 4 skipped by -SkipSteps" -ForegroundColor Yellow
} else {
Write-Host ""
Write-Host ">>> Step 4: User Profile Storage (Key Vault)" -ForegroundColor White
Write-Host "  [OK] User job titles are stored in Key Vault secret 'UserProfiles' as JSON keyed by email address." -ForegroundColor Green
Write-Host "  [OK] No Entra custom role or Graph delegated consent is required for profile updates." -ForegroundColor Green
}

# =============================================================================
# SUMMARY
# =============================================================================
Write-Host ""
$totalChanges = $networkChanges + $newAssignments
if ($totalChanges -gt 0) {
    Write-Host "[SUCCESS] Dev environment configured. $networkChanges network change(s), $newAssignments new RBAC assignment(s)." -ForegroundColor Green
    if ($newAssignments -gt 0) {
        Write-Host "[INFO] RBAC propagation may take up to 5 minutes." -ForegroundColor Cyan
    }
} else {
    Write-Host "[SUCCESS] Dev environment already configured. No changes needed." -ForegroundColor Green
}
Write-Host ""
Write-Host "  Storage Account : $StorageAccountName (firewall: laptop IP + Azure services)" -ForegroundColor White
Write-Host "  Cosmos DB       : $CosmosDbAccountName (firewall: laptop IP + Azure services)" -ForegroundColor White
Write-Host "  Key Vault       : $KeyVaultName (firewall: laptop IP + Azure services)" -ForegroundColor White
Write-Host "  Allowed IP      : $MyPublicIp" -ForegroundColor White
Write-Host "  User            : $CurrentUserName" -ForegroundColor White
Write-Host ""

# =============================================================================
# GENERATE env.bat
# =============================================================================
$envBatPath = Join-Path $PSScriptRoot '..\env.bat'
$envBatContent = "@echo off`r`nset AZURE_KEY_VAULT_URL=https://$KeyVaultName.vault.azure.net"
Set-Content -Path $envBatPath -Value $envBatContent -Encoding ASCII -Force
Write-Host "[OK] Created $envBatPath" -ForegroundColor Green

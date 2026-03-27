#Requires -Version 5.1
<#
.SYNOPSIS
    Configures the dev environment for local development and testing.
.DESCRIPTION
    Enables public network access on Cosmos DB and Storage, and grants the
    logged-in user read/write/admin RBAC roles on both resources.
    Run this after deploy-infrastructure.ps1 has completed successfully.
.PARAMETER Suffix
    Required. The same suffix used when running deploy-infrastructure.ps1.
.USAGE
    .\operation-dev.ps1 -Suffix 999
#>
param(
    [Parameter(Mandatory=$true, HelpMessage="Suffix used during infrastructure deployment (e.g. 999)")]
    [ValidateNotNullOrEmpty()]
    [string]$Suffix
)

$ErrorActionPreference = "Stop"

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

function Ensure-RoleAssignment {
    param([string]$Assignee, [string]$Role, [string]$Scope)
    $existing = Invoke-AzCliSilent -Arguments @('role','assignment','list','--assignee',$Assignee,'--role',$Role,'--scope',$Scope,'--query','[0].id','-o','tsv')
    if ($existing.ExitCode -eq 0 -and $existing.Output) {
        return $true  # already exists
    }
    Invoke-AzCliSilent -Arguments @('role','assignment','create','--assignee',$Assignee,'--role',$Role,'--scope',$Scope,'--output','none') | Out-Null
    return $false  # newly created
}

function Ensure-CosmosRoleAssignment {
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

# =============================================================================
# CONFIGURATION (must match deploy-infrastructure.ps1)
# =============================================================================
$ProjectName        = if ($env:PROJECT_NAME)        { $env:PROJECT_NAME }        else { "eia" }
$Environment        = if ($env:ENVIRONMENT)         { $env:ENVIRONMENT }         else { "dev" }
$ProjClean          = $ProjectName -replace '-',''
$ResourceGroupName  = if ($env:RESOURCE_GROUP_NAME) { $env:RESOURCE_GROUP_NAME } else { "rg-$ProjectName-$Environment-$Suffix" }
$StorageAccountName = if ($env:STORAGE_ACCOUNT_NAME){ $env:STORAGE_ACCOUNT_NAME }else { "st$ProjClean$Environment$Suffix" }
$CosmosDbAccountName = if ($env:COSMOS_DB_ACCOUNT_NAME) { $env:COSMOS_DB_ACCOUNT_NAME } else { "cosmos-$ProjectName-$Environment-$Suffix" }
$ContentUnderstandingName = if ($env:CONTENT_UNDERSTANDING_NAME) { $env:CONTENT_UNDERSTANDING_NAME } else { "cu-$ProjectName-$Environment-$Suffix" }
$AiFoundryName       = if ($env:AI_FOUNDRY_NAME)     { $env:AI_FOUNDRY_NAME }     else { "oai-$ProjectName-$Environment-$Suffix" }
$KeyVaultName        = if ($env:KEY_VAULT_NAME)      { $env:KEY_VAULT_NAME }      else { "kv-$ProjectName-$Environment-$Suffix" }

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
function Normalize-IpList([string]$IpCsv) {
    if (-not $IpCsv) { return '' }
    ($IpCsv -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Sort-Object -Unique) -join ','
}

# Helper: normalize bypass string for comparison (sort components)
function Normalize-Bypass([string]$Bypass) {
    if (-not $Bypass) { return '' }
    ($Bypass -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Sort-Object) -join ','
}

$networkChanges = 0

# --- Gather current state (quick reads, sequential) ---
$DesiredCosmosIpFilter = "$MyPublicIp,104.42.195.92,40.76.54.131,52.176.6.30,52.169.50.45,52.187.184.26,0.0.0.0"

Write-Host "[INFO] Checking Cosmos DB network rules: $CosmosDbAccountName" -ForegroundColor Cyan
$cosmosState = Invoke-AzCliSilent -Arguments @('cosmosdb','show','--name',$CosmosDbAccountName,
    '--resource-group',$ResourceGroupName,
    '--query','{publicNetworkAccess:publicNetworkAccess, ipRules:ipRules[].ipAddressOrRange}','-o','json')
$cosmosJson  = $cosmosState.Output | ConvertFrom-Json
$currentCosmosIps = if ($cosmosJson.ipRules) { Normalize-IpList (($cosmosJson.ipRules) -join ',') } else { '' }
$desiredCosmosIps = Normalize-IpList $DesiredCosmosIpFilter
$cosmosNeedsUpdate = -not ($cosmosJson.publicNetworkAccess -eq 'Enabled' -and $currentCosmosIps -eq $desiredCosmosIps)

Write-Host "[INFO] Checking Storage Account network rules: $StorageAccountName" -ForegroundColor Cyan
$storageState = Invoke-AzCliSilent -Arguments @('storage','account','show','--name',$StorageAccountName,
    '--resource-group',$ResourceGroupName,
    '--query','{publicNetworkAccess:publicNetworkAccess, defaultAction:networkRuleSet.defaultAction, bypass:networkRuleSet.bypass, ipRules:networkRuleSet.ipRules[].ipAddressOrRange}',
    '-o','json')
$storageJson = $storageState.Output | ConvertFrom-Json
$currentBypass = Normalize-Bypass $storageJson.bypass
$desiredBypass = Normalize-Bypass 'AzureServices,Logging,Metrics'
$currentStorageIps = if ($storageJson.ipRules) { ($storageJson.ipRules | Sort-Object -Unique) -join ',' } else { '' }
$storageNeedsUpdate = ($storageJson.publicNetworkAccess -ne 'Enabled' -or $storageJson.defaultAction -ne 'Deny' -or $currentBypass -ne $desiredBypass -or $currentStorageIps -ne $MyPublicIp)

Write-Host "[INFO] Checking Key Vault network rules: $KeyVaultName" -ForegroundColor Cyan
$kvState = Invoke-AzCliSilent -Arguments @('keyvault','show','--name',$KeyVaultName,
    '--resource-group',$ResourceGroupName,
    '--query','{publicNetworkAccess:properties.publicNetworkAccess, defaultAction:properties.networkAcls.defaultAction, bypass:properties.networkAcls.bypass, ipRules:properties.networkAcls.ipRules[].value}',
    '-o','json')
$kvJson = $kvState.Output | ConvertFrom-Json
$currentKvBypass = Normalize-Bypass $kvJson.bypass
$desiredKvBypass = Normalize-Bypass 'AzureServices'
$currentKvIps = if ($kvJson.ipRules) { ($kvJson.ipRules | Sort-Object -Unique) -join ',' } else { '' }
$desiredKvIp = "$MyPublicIp/32"
$kvNeedsUpdate = ($kvJson.publicNetworkAccess -ne 'Enabled' -or $kvJson.defaultAction -ne 'Deny' -or $currentKvBypass -ne $desiredKvBypass -or $currentKvIps -ne $desiredKvIp)

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
        param($AccountName, $RG, $MyIp, $NeedDefaultUpdate, $NeedIpUpdate, $CurrentIps)
        if ($NeedDefaultUpdate) {
            az storage account update --name $AccountName --resource-group $RG `
                --public-network-access Enabled --default-action Deny `
                --bypass AzureServices Logging Metrics --output none 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Storage default rules update failed" }
        }
        if ($NeedIpUpdate) {
            # Remove stale IPs
            if ($CurrentIps) {
                foreach ($ip in ($CurrentIps -split ',')) {
                    if ($ip -ne $MyIp) {
                        az storage account network-rule remove --account-name $AccountName --resource-group $RG --ip-address $ip --output none 2>&1 | Out-Null
                    }
                }
            }
            # Add laptop IP if not present
            if (-not ($CurrentIps -and ($CurrentIps -split ',' | Where-Object { $_ -eq $MyIp }))) {
                az storage account network-rule add --account-name $AccountName --resource-group $RG --ip-address $MyIp --output none 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "Storage IP rule add failed" }
            }
        }
    } -ArgumentList $StorageAccountName, $ResourceGroupName, $MyPublicIp, `
        ($storageJson.publicNetworkAccess -ne 'Enabled' -or $storageJson.defaultAction -ne 'Deny' -or $currentBypass -ne $desiredBypass), `
        ($currentStorageIps -ne $MyPublicIp), `
        $currentStorageIps
}

if (-not $kvNeedsUpdate) {
    Write-Host "  [OK] Key Vault network rules already configured correctly" -ForegroundColor Gray
} else {
    Write-Host "  [INFO] Updating Key Vault network rules in background..." -ForegroundColor Cyan
    $jobs += Start-Job -Name 'KeyVault-Network' -ScriptBlock {
        param($VaultName, $RG, $DesiredIp, $NeedDefaultUpdate, $NeedIpUpdate, $CurrentIps)
        if ($NeedDefaultUpdate) {
            az keyvault update --name $VaultName --resource-group $RG `
                --public-network-access Enabled --default-action Deny `
                --bypass AzureServices --output none 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Key Vault default rules update failed" }
        }
        if ($NeedIpUpdate) {
            # Remove stale IPs
            if ($CurrentIps) {
                foreach ($ip in ($CurrentIps -split ',')) {
                    if ($ip -ne $DesiredIp) {
                        az keyvault network-rule remove --name $VaultName --resource-group $RG --ip-address $ip --output none 2>&1 | Out-Null
                    }
                }
            }
            # Add laptop IP if not present
            if (-not ($CurrentIps -and ($CurrentIps -split ',' | Where-Object { $_ -eq $DesiredIp }))) {
                az keyvault network-rule add --name $VaultName --resource-group $RG --ip-address $DesiredIp --output none 2>&1 | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "Key Vault IP rule add failed" }
            }
        }
    } -ArgumentList $KeyVaultName, $ResourceGroupName, $desiredKvIp, `
        ($kvJson.publicNetworkAccess -ne 'Enabled' -or $kvJson.defaultAction -ne 'Deny' -or $currentKvBypass -ne $desiredKvBypass), `
        ($currentKvIps -ne $desiredKvIp), `
        $currentKvIps
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

# =============================================================================
# STEP 2: Grant Logged-In User Read/Write & Admin Access
# =============================================================================
Write-Host ""
Write-Host ">>> Step 2: Grant RBAC Roles to Current User" -ForegroundColor White

# --- Gather resource IDs (quick reads) ---
$StorageAccountId = (Invoke-AzCliSilent -Arguments @('storage','account','show','--name',$StorageAccountName,'--resource-group',$ResourceGroupName,'--query','id','-o','tsv')).Output
$CosmosDbAccountId = (Invoke-AzCliSilent -Arguments @('cosmosdb','show','--name',$CosmosDbAccountName,'--resource-group',$ResourceGroupName,'--query','id','-o','tsv')).Output
$KeyVaultId = (Invoke-AzCliSilent -Arguments @('keyvault','show','--name',$KeyVaultName,'--resource-group',$ResourceGroupName,'--query','id','-o','tsv')).Output
$ContentUnderstandingId = (Invoke-AzCliSilent -Arguments @('cognitiveservices','account','show','--name',$ContentUnderstandingName,'--resource-group',$ResourceGroupName,'--query','id','-o','tsv')).Output
$AiFoundryId = (Invoke-AzCliSilent -Arguments @('cognitiveservices','account','show','--name',$AiFoundryName,'--resource-group',$ResourceGroupName,'--query','id','-o','tsv')).Output

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
                    'Storage Account Contributor','Storage Blob Data Owner')) {
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

# AI Foundry / Azure OpenAI roles for current user (data-plane access: chat completions, embeddings, etc.)
foreach ($role in @('Cognitive Services User','Cognitive Services Contributor','Cognitive Services OpenAI User','Cognitive Services OpenAI Contributor')) {
    $allAssignments.Add(@{ Assignee=$CurrentUserId; Role=$role; Scope=$AiFoundryId; Label="$role (AI Foundry)"; Type='arm' })
}

# Content Understanding -> Storage Blob Data Reader
if ($CuIdentity) {
    $allAssignments.Add(@{ Assignee=$CuIdentity; Role='Storage Blob Data Reader'; Scope=$StorageAccountId; Label='Storage Blob Data Reader (Content Understanding)'; Type='arm' })
} else {
    Write-Host "  [WARNING] Content Understanding '$ContentUnderstandingName' identity not found. Skipping." -ForegroundColor Yellow
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
$newAssignments = 0
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
$envBatContent = "@echo off`r`nset KEY_VAULT_URL=https://$KeyVaultName.vault.azure.net"
Set-Content -Path $envBatPath -Value $envBatContent -Encoding ASCII -Force
Write-Host "[OK] Created $envBatPath" -ForegroundColor Green

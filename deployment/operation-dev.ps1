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

$networkChanges = 0

# --- Cosmos DB ---
# Desired: public-network-access=Enabled, ip-range-filter = laptop + Azure portal + Azure DCs
$DesiredCosmosIpFilter = "$MyPublicIp,104.42.195.92,40.76.54.131,52.176.6.30,52.169.50.45,52.187.184.26,0.0.0.0"

Write-Host "[INFO] Checking Cosmos DB network rules: $CosmosDbAccountName" -ForegroundColor Cyan
$cosmosState = Invoke-AzCliSilent -Arguments @('cosmosdb','show','--name',$CosmosDbAccountName,
    '--resource-group',$ResourceGroupName,
    '--query','{publicNetworkAccess:publicNetworkAccess, ipRules:ipRules[].ipAddressOrRange}','-o','json')
$cosmosJson  = $cosmosState.Output | ConvertFrom-Json
$currentCosmosIps = if ($cosmosJson.ipRules) { Normalize-IpList (($cosmosJson.ipRules) -join ',') } else { '' }
$desiredCosmosIps = Normalize-IpList $DesiredCosmosIpFilter

if ($cosmosJson.publicNetworkAccess -eq 'Enabled' -and $currentCosmosIps -eq $desiredCosmosIps) {
    Write-Host "  [OK] Cosmos DB network rules already configured correctly" -ForegroundColor Gray
} else {
    Write-Host "  [INFO] Updating Cosmos DB IP filter..." -ForegroundColor Cyan
    $r = Invoke-AzCliSilent -Arguments @('cosmosdb','update','--name',$CosmosDbAccountName,
        '--resource-group',$ResourceGroupName,
        '--public-network-access','Enabled',
        '--ip-range-filter',$DesiredCosmosIpFilter,
        '--output','none')
    if ($r.ExitCode -eq 0) {
        Write-Host "  [SUCCESS] Cosmos DB: access restricted to laptop IP + Azure services" -ForegroundColor Green
        $networkChanges++
    } else {
        Write-Host "  [ERROR] Failed to configure Cosmos DB network rules" -ForegroundColor Red
        if ($r.Error) { Write-Host "    $($r.Error)" -ForegroundColor Red }
    }
}

# --- Storage Account ---
# Desired: publicNetworkAccess=Enabled, defaultAction=Deny, bypass=AzureServices+Logging+Metrics, ipRules=[laptop IP only]
Write-Host "[INFO] Checking Storage Account network rules: $StorageAccountName" -ForegroundColor Cyan
$storageState = Invoke-AzCliSilent -Arguments @('storage','account','show','--name',$StorageAccountName,
    '--resource-group',$ResourceGroupName,
    '--query','{publicNetworkAccess:publicNetworkAccess, defaultAction:networkRuleSet.defaultAction, bypass:networkRuleSet.bypass, ipRules:networkRuleSet.ipRules[].ipAddressOrRange}',
    '-o','json')
$storageJson = $storageState.Output | ConvertFrom-Json

# Normalize bypass for comparison (Azure may return with varying whitespace)
function Normalize-Bypass([string]$Bypass) {
    if (-not $Bypass) { return '' }
    ($Bypass -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Sort-Object) -join ','
}
$currentBypass = Normalize-Bypass $storageJson.bypass
$desiredBypass = Normalize-Bypass 'AzureServices,Logging,Metrics'
$currentStorageIps = if ($storageJson.ipRules) { ($storageJson.ipRules | Sort-Object -Unique) -join ',' } else { '' }

$storageNeedsUpdate = $false
if ($storageJson.publicNetworkAccess -ne 'Enabled') { $storageNeedsUpdate = $true }
if ($storageJson.defaultAction -ne 'Deny')          { $storageNeedsUpdate = $true }
if ($currentBypass -ne $desiredBypass)               { $storageNeedsUpdate = $true }
if ($currentStorageIps -ne $MyPublicIp)              { $storageNeedsUpdate = $true }

if (-not $storageNeedsUpdate) {
    Write-Host "  [OK] Storage Account network rules already configured correctly" -ForegroundColor Gray
} else {
    $storageFailed = $false

    # Update default-action / bypass / public-network-access if any differ
    if ($storageJson.publicNetworkAccess -ne 'Enabled' -or $storageJson.defaultAction -ne 'Deny' -or $currentBypass -ne $desiredBypass) {
        Write-Host "  [INFO] Updating Storage Account default rules..." -ForegroundColor Cyan
        $r = Invoke-AzCliSilent -Arguments @('storage','account','update','--name',$StorageAccountName,
            '--resource-group',$ResourceGroupName,
            '--public-network-access','Enabled',
            '--default-action','Deny',
            '--bypass','AzureServices','Logging','Metrics',
            '--output','json')
        if ($r.ExitCode -ne 0) {
            Write-Host "  [ERROR] Failed to set Storage Account default deny rule" -ForegroundColor Red
            if ($r.Error) { Write-Host "    $($r.Error)" -ForegroundColor Red }
            if ($r.Output) { Write-Host "    $($r.Output)" -ForegroundColor Red }
            $storageFailed = $true
        }
    }

    # Update IP rules only if the current set doesn't already match
    if ($currentStorageIps -ne $MyPublicIp) {
        # Remove stale IP rules that aren't the laptop IP
        if ($storageJson.ipRules) {
            foreach ($ip in $storageJson.ipRules) {
                if ($ip -ne $MyPublicIp) {
                    Invoke-AzCliSilent -Arguments @('storage','account','network-rule','remove',
                        '--account-name',$StorageAccountName,'--resource-group',$ResourceGroupName,
                        '--ip-address',$ip,'--output','none') | Out-Null
                }
            }
        }
        # Add laptop IP if not already present
        $hasMyIp = $storageJson.ipRules -and ($storageJson.ipRules -contains $MyPublicIp)
        if (-not $hasMyIp) {
            $r = Invoke-AzCliSilent -Arguments @('storage','account','network-rule','add',
                '--account-name',$StorageAccountName,'--resource-group',$ResourceGroupName,
                '--ip-address',$MyPublicIp,'--output','none')
            if ($r.ExitCode -ne 0) {
                Write-Host "  [ERROR] Failed to add laptop IP to Storage Account" -ForegroundColor Red
                if ($r.Error) { Write-Host "    $($r.Error)" -ForegroundColor Red }
                $storageFailed = $true
            }
        }
    }

    if (-not $storageFailed) {
        Write-Host "  [SUCCESS] Storage Account: access restricted to laptop IP + Azure services" -ForegroundColor Green
        $networkChanges++
    } else {
        Write-Host "  [WARNING] Storage Account network rules may be partially configured" -ForegroundColor Yellow
    }
}

# --- Key Vault ---
# Desired: publicNetworkAccess=Enabled, defaultAction=Deny, bypass=AzureServices, ipRules=[laptop IP only]
Write-Host "[INFO] Checking Key Vault network rules: $KeyVaultName" -ForegroundColor Cyan
$kvState = Invoke-AzCliSilent -Arguments @('keyvault','show','--name',$KeyVaultName,
    '--resource-group',$ResourceGroupName,
    '--query','{publicNetworkAccess:properties.publicNetworkAccess, defaultAction:properties.networkAcls.defaultAction, bypass:properties.networkAcls.bypass, ipRules:properties.networkAcls.ipRules[].value}',
    '-o','json')
$kvJson = $kvState.Output | ConvertFrom-Json

$currentKvBypass = Normalize-Bypass $kvJson.bypass
$desiredKvBypass = Normalize-Bypass 'AzureServices'
$currentKvIps = if ($kvJson.ipRules) { ($kvJson.ipRules | Sort-Object -Unique) -join ',' } else { '' }
# Key Vault IP rules use CIDR notation — append /32 for single IPs
$desiredKvIp = "$MyPublicIp/32"

$kvNeedsUpdate = $false
if ($kvJson.publicNetworkAccess -ne 'Enabled') { $kvNeedsUpdate = $true }
if ($kvJson.defaultAction -ne 'Deny')          { $kvNeedsUpdate = $true }
if ($currentKvBypass -ne $desiredKvBypass)      { $kvNeedsUpdate = $true }
if ($currentKvIps -ne $desiredKvIp)             { $kvNeedsUpdate = $true }

if (-not $kvNeedsUpdate) {
    Write-Host "  [OK] Key Vault network rules already configured correctly" -ForegroundColor Gray
} else {
    # Update default-action / bypass / public-network-access
    if ($kvJson.publicNetworkAccess -ne 'Enabled' -or $kvJson.defaultAction -ne 'Deny' -or $currentKvBypass -ne $desiredKvBypass) {
        Write-Host "  [INFO] Updating Key Vault default rules..." -ForegroundColor Cyan
        $r = Invoke-AzCliSilent -Arguments @('keyvault','update','--name',$KeyVaultName,
            '--resource-group',$ResourceGroupName,
            '--public-network-access','Enabled',
            '--default-action','Deny',
            '--bypass','AzureServices',
            '--output','none')
        if ($r.ExitCode -ne 0) {
            Write-Host "  [ERROR] Failed to set Key Vault default deny rule" -ForegroundColor Red
            if ($r.Error) { Write-Host "    $($r.Error)" -ForegroundColor Red }
        }
    }

    # Update IP rules only if the current set doesn't match
    if ($currentKvIps -ne $desiredKvIp) {
        # Remove stale IP rules
        if ($kvJson.ipRules) {
            foreach ($ip in $kvJson.ipRules) {
                if ($ip -ne $desiredKvIp) {
                    Invoke-AzCliSilent -Arguments @('keyvault','network-rule','remove','--name',$KeyVaultName,
                        '--resource-group',$ResourceGroupName,
                        '--ip-address',$ip,'--output','none') | Out-Null
                }
            }
        }
        # Add laptop IP if not already present
        $hasMyIp = $kvJson.ipRules -and ($kvJson.ipRules -contains $desiredKvIp)
        if (-not $hasMyIp) {
            $r = Invoke-AzCliSilent -Arguments @('keyvault','network-rule','add','--name',$KeyVaultName,
                '--resource-group',$ResourceGroupName,
                '--ip-address',$desiredKvIp,'--output','none')
            if ($r.ExitCode -ne 0) {
                Write-Host "  [ERROR] Failed to add laptop IP to Key Vault" -ForegroundColor Red
                if ($r.Error) { Write-Host "    $($r.Error)" -ForegroundColor Red }
            }
        }
    }

    Write-Host "  [SUCCESS] Key Vault: access restricted to laptop IP + Azure services" -ForegroundColor Green
    $networkChanges++
}

# =============================================================================
# STEP 2: Grant Logged-In User Read/Write & Admin Access
# =============================================================================
Write-Host ""
Write-Host ">>> Step 2: Grant RBAC Roles to Current User" -ForegroundColor White

$newAssignments = 0

# --- Storage Account roles ---
$StorageAccountId = (Invoke-AzCliSilent -Arguments @('storage','account','show','--name',$StorageAccountName,'--resource-group',$ResourceGroupName,'--query','id','-o','tsv')).Output

$storageRoles = @(
    'Storage Blob Data Contributor',
    'Storage Blob Data Reader',
    'Storage Queue Data Contributor',
    'Storage Table Data Contributor',
    'Storage Account Contributor',
    'Storage Blob Data Owner'
)

Write-Host "[INFO] Assigning Storage Account roles to current user..." -ForegroundColor Cyan
foreach ($role in $storageRoles) {
    $alreadyAssigned = Ensure-RoleAssignment -Assignee $CurrentUserId -Role $role -Scope $StorageAccountId
    if ($alreadyAssigned) {
        Write-Host "  [OK] $role - already assigned" -ForegroundColor Gray
    } else {
        Write-Host "  [SUCCESS] $role - assigned" -ForegroundColor Green
        $newAssignments++
    }
}

# --- Cosmos DB roles ---
$CosmosDbAccountId = (Invoke-AzCliSilent -Arguments @('cosmosdb','show','--name',$CosmosDbAccountName,'--resource-group',$ResourceGroupName,'--query','id','-o','tsv')).Output

# ARM-level Cosmos DB roles (portal/management access)
$cosmosArmRoles = @(
    'Cosmos DB Account Reader Role',
    'DocumentDB Account Contributor'
)

Write-Host "[INFO] Assigning Cosmos DB ARM roles to current user..." -ForegroundColor Cyan
foreach ($role in $cosmosArmRoles) {
    $alreadyAssigned = Ensure-RoleAssignment -Assignee $CurrentUserId -Role $role -Scope $CosmosDbAccountId
    if ($alreadyAssigned) {
        Write-Host "  [OK] $role - already assigned" -ForegroundColor Gray
    } else {
        Write-Host "  [SUCCESS] $role - assigned" -ForegroundColor Green
        $newAssignments++
    }
}

# Cosmos DB data-plane roles (read/write data)
# 00000000-0000-0000-0000-000000000001 = Built-in Data Reader
# 00000000-0000-0000-0000-000000000002 = Built-in Data Contributor
$cosmosDataRoles = @(
    @{ Id = "00000000-0000-0000-0000-000000000001"; Name = "Cosmos DB Built-in Data Reader" },
    @{ Id = "00000000-0000-0000-0000-000000000002"; Name = "Cosmos DB Built-in Data Contributor" }
)

Write-Host "[INFO] Assigning Cosmos DB data-plane roles to current user..." -ForegroundColor Cyan
foreach ($role in $cosmosDataRoles) {
    $alreadyAssigned = Ensure-CosmosRoleAssignment -AccountName $CosmosDbAccountName `
        -ResourceGroup $ResourceGroupName `
        -RoleDefinitionId $role.Id `
        -PrincipalId $CurrentUserId `
        -Scope $CosmosDbAccountId
    if ($alreadyAssigned) {
        Write-Host "  [OK] $($role.Name) - already assigned" -ForegroundColor Gray
    } else {
        Write-Host "  [SUCCESS] $($role.Name) - assigned" -ForegroundColor Green
        $newAssignments++
    }
}

# --- Content Understanding: Storage Blob Data Reader ---
# CU needs to read blobs from Storage when given a blob URL
Write-Host "[INFO] Ensuring Content Understanding has Storage Blob Data Reader..." -ForegroundColor Cyan
$CuIdentity = (Invoke-AzCliSilent -Arguments @('cognitiveservices','account','identity','show','--name',$ContentUnderstandingName,'--resource-group',$ResourceGroupName,'--query','principalId','-o','tsv')).Output
if (-not $CuIdentity) {
    Write-Host "  [INFO] Enabling managed identity for $ContentUnderstandingName" -ForegroundColor Cyan
    Invoke-AzCliSilent -Arguments @('cognitiveservices','account','identity','assign','--name',$ContentUnderstandingName,'--resource-group',$ResourceGroupName,'--output','none') | Out-Null
    $CuIdentity = (Invoke-AzCliSilent -Arguments @('cognitiveservices','account','identity','show','--name',$ContentUnderstandingName,'--resource-group',$ResourceGroupName,'--query','principalId','-o','tsv')).Output
}
if ($CuIdentity) {
    $alreadyAssigned = Ensure-RoleAssignment -Assignee $CuIdentity -Role 'Storage Blob Data Reader' -Scope $StorageAccountId
    if ($alreadyAssigned) {
        Write-Host "  [OK] Storage Blob Data Reader (Content Understanding) - already assigned" -ForegroundColor Gray
    } else {
        Write-Host "  [SUCCESS] Storage Blob Data Reader (Content Understanding) - assigned" -ForegroundColor Green
        $newAssignments++
    }
} else {
    Write-Host "  [WARNING] Content Understanding '$ContentUnderstandingName' identity not found. Skipping." -ForegroundColor Yellow
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

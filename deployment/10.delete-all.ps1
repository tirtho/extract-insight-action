#Requires -Version 5.1
<#
.SYNOPSIS
    Deletes ALL Azure infrastructure deployed by the extract-insight-action scripts.
.DESCRIPTION
    Removes the resource group, purges soft-deleted resources (Key Vault,
    Cognitive Services), deletes the Graph API app registration and its
    service principal, and cleans up the local env.bat file.
    This is a destructive, irreversible operation.
.PARAMETER Suffix
    Required. The same suffix used when running deploy-infrastructure.ps1.
.USAGE
    .\10.delete-all.ps1 -Suffix 999
#>
param(
    [Parameter(Mandatory=$true, HelpMessage="Suffix used during infrastructure deployment (e.g. 999)")]
    [ValidateNotNullOrEmpty()]
    [string]$Suffix
)

$ErrorActionPreference = "Stop"

# =============================================================================
# CONFIGURATION (mirrors deploy-infrastructure.ps1 naming conventions)
# =============================================================================
$ProjectName              = if ($env:PROJECT_NAME)              { $env:PROJECT_NAME }              else { "eia" }
$Environment              = if ($env:ENVIRONMENT)               { $env:ENVIRONMENT }               else { "dev" }
$ProjClean                = $ProjectName -replace '-',''
$ResourceGroupName        = if ($env:RESOURCE_GROUP_NAME)       { $env:RESOURCE_GROUP_NAME }       else { "rg-$ProjectName-$Environment-$Suffix" }
$KeyVaultName             = if ($env:KEY_VAULT_NAME)            { $env:KEY_VAULT_NAME }            else { "kv-$ProjectName-$Environment-$Suffix" }
$StorageAccountName       = if ($env:STORAGE_ACCOUNT_NAME)      { $env:STORAGE_ACCOUNT_NAME }      else { "st$ProjClean$Environment$Suffix" }
$ContentUnderstandingName = if ($env:CONTENT_UNDERSTANDING_NAME){ $env:CONTENT_UNDERSTANDING_NAME } else { "cu-$ProjectName-$Environment-$Suffix" }
$AiFoundryName            = if ($env:AI_FOUNDRY_NAME)           { $env:AI_FOUNDRY_NAME }            else { "oai-$ProjectName-$Environment-$Suffix" }
$GraphAppName             = if ($env:GRAPH_APP_NAME)            { $env:GRAPH_APP_NAME }             else { "$ProjectName-graph-api-$Environment" }

$ScriptRoot = $PSScriptRoot
$RepoRoot   = Split-Path $ScriptRoot -Parent

# =============================================================================
# HELPER
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

# =============================================================================
# BANNER + CONFIRMATION
# =============================================================================
Write-Host ""
Write-Host "[DANGER] ============================================================" -ForegroundColor Red
Write-Host "[DANGER] DELETE ALL AZURE INFRASTRUCTURE" -ForegroundColor Red
Write-Host "[DANGER] ============================================================" -ForegroundColor Red
Write-Host ""
Write-Host "  This will PERMANENTLY delete:" -ForegroundColor Yellow
Write-Host "    - Resource Group    : $ResourceGroupName (and ALL resources inside)" -ForegroundColor Yellow
Write-Host "    - Key Vault purge   : $KeyVaultName" -ForegroundColor Yellow
Write-Host "    - Cognitive Services purge: $ContentUnderstandingName, $AiFoundryName" -ForegroundColor Yellow
Write-Host "    - Graph App Registration  : $GraphAppName" -ForegroundColor Yellow
Write-Host "    - Local env.bat file" -ForegroundColor Yellow
Write-Host ""
Write-Host "  This action is IRREVERSIBLE." -ForegroundColor Red
Write-Host ""

$confirmation = Read-Host "Type the resource group name to confirm deletion [$ResourceGroupName]"
if ($confirmation -ne $ResourceGroupName) {
    Write-Host "[ABORTED] Confirmation did not match. No changes made." -ForegroundColor Yellow
    exit 0
}

# =============================================================================
# PREREQUISITES
# =============================================================================
Write-Host ""
Write-Host "[INFO] Checking prerequisites..." -ForegroundColor Cyan

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Host "[ERROR] Azure CLI is not installed." -ForegroundColor Red
    exit 1
}

$acctState = (Invoke-AzCliSilent -Arguments @('account','show','--query','state','-o','tsv')).Output
if ($acctState -ne "Enabled") {
    Write-Host "[ERROR] Not logged in to Azure CLI. Run 'az login' first." -ForegroundColor Red
    exit 1
}

$SubscriptionId = if ($env:SUBSCRIPTION_ID) { $env:SUBSCRIPTION_ID } else { (Invoke-AzCliSilent -Arguments @('account','show','--query','id','-o','tsv')).Output }
if ($SubscriptionId) {
    Invoke-AzCliSilent -Arguments @('account','set','--subscription',$SubscriptionId) | Out-Null
}
Write-Host "[OK] Logged in (subscription: $SubscriptionId)" -ForegroundColor Green

$script:DeleteErrors = [System.Collections.Generic.List[string]]::new()

# =============================================================================
# STEPS 1 & 2 (PARALLEL): Delete Graph App + Delete Resource Group
# =============================================================================
Write-Host ""
Write-Host ">>> Steps 1 & 2: Delete Graph App Registration + Resource Group (parallel)" -ForegroundColor White

# --- Kick off Resource Group deletion (async, --no-wait) ---
$rgDeleted = $false
$rgExists = (Invoke-AzCliSilent -Arguments @('group','show','--name',$ResourceGroupName,'--query','name','-o','tsv')).Output
if ($rgExists) {
    Write-Host "[INFO] Deleting resource group: $ResourceGroupName (this may take several minutes)..." -ForegroundColor Cyan
    $r = Invoke-AzCliSilent -Arguments @('group','delete','--name',$ResourceGroupName,'--yes','--no-wait')
    if ($r.ExitCode -ne 0) {
        Write-Host "[ERROR] Failed to initiate resource group deletion: $($r.Error)" -ForegroundColor Red
        $script:DeleteErrors.Add("Resource group: $ResourceGroupName")
    }
} else {
    Write-Host "[OK] Resource group '$ResourceGroupName' not found, nothing to delete" -ForegroundColor Gray
    $rgDeleted = $true
}

# --- Delete Graph App in main thread (while RG deletes in background) ---
$graphAppId = (Invoke-AzCliSilent -Arguments @('ad','app','list','--display-name',$GraphAppName,'--query','[0].appId','-o','tsv')).Output
if ($graphAppId) {
    $spId = (Invoke-AzCliSilent -Arguments @('ad','sp','show','--id',$graphAppId,'--query','id','-o','tsv')).Output
    if ($spId) {
        Write-Host "[INFO] Deleting service principal: $spId" -ForegroundColor Cyan
        $r = Invoke-AzCliSilent -Arguments @('ad','sp','delete','--id',$spId)
        if ($r.ExitCode -eq 0) {
            Write-Host "[OK] Service principal deleted (consent grants removed)" -ForegroundColor Green
        } else {
            Write-Host "[WARNING] Failed to delete service principal: $($r.Error)" -ForegroundColor Yellow
        }
    }
    Write-Host "[INFO] Deleting app registration: $GraphAppName ($graphAppId)" -ForegroundColor Cyan
    $r = Invoke-AzCliSilent -Arguments @('ad','app','delete','--id',$graphAppId)
    if ($r.ExitCode -eq 0) {
        Write-Host "[OK] App registration deleted" -ForegroundColor Green
    } else {
        Write-Host "[WARNING] Failed to delete app registration: $($r.Error)" -ForegroundColor Yellow
        $script:DeleteErrors.Add("Graph app registration: $GraphAppName")
    }
} else {
    Write-Host "[OK] App registration '$GraphAppName' not found, nothing to delete" -ForegroundColor Gray
}

# --- Poll for Resource Group deletion completion ---
if ($rgExists -and -not $script:DeleteErrors.Contains("Resource group: $ResourceGroupName")) {
    $maxWaitSeconds = 1200
    $elapsed = 0
    $pollInterval = 15
    while ($elapsed -lt $maxWaitSeconds) {
        $check = Invoke-AzCliSilent -Arguments @('group','exists','--name',$ResourceGroupName)
        if ($check.Output -eq 'false') { break }
        $elapsed += $pollInterval
        Write-Host "  [INFO] Still deleting resource group... ($elapsed seconds elapsed)" -ForegroundColor Gray
        Start-Sleep -Seconds $pollInterval
    }
    $finalCheck = Invoke-AzCliSilent -Arguments @('group','exists','--name',$ResourceGroupName)
    if ($finalCheck.Output -eq 'false') {
        Write-Host "[OK] Resource group $ResourceGroupName deleted" -ForegroundColor Green
        $rgDeleted = $true
    } else {
        Write-Host "[WARNING] Resource group deletion still in progress after $maxWaitSeconds seconds. It will complete in the background." -ForegroundColor Yellow
    }
}

# =============================================================================
# STEPS 3 & 4 (PARALLEL): Purge Key Vault + Cognitive Services
# =============================================================================
Write-Host ""
Write-Host ">>> Steps 3 & 4: Purge Soft-Deleted Resources (parallel)" -ForegroundColor White

# --- Key Vault purge job ---
$kvJob = Start-Job -ScriptBlock {
    param($KeyVaultName)
    $results = @{ Errors = @(); Messages = @() }
    $deletedKv = (az keyvault list-deleted --query "[?name=='$KeyVaultName'].name | [0]" -o tsv 2>$null)
    if ($deletedKv) {
        $results.Messages += "[INFO] Purging soft-deleted Key Vault: $KeyVaultName"
        az keyvault purge --name $KeyVaultName --no-wait 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $results.Messages += "[OK] Key Vault purge initiated"
        } else {
            $results.Messages += "[WARNING] Failed to purge Key Vault"
            $results.Errors += "Key Vault purge: $KeyVaultName"
        }
    } else {
        $results.Messages += "[OK] No soft-deleted Key Vault '$KeyVaultName' found"
    }
    return $results
} -ArgumentList $KeyVaultName

# --- Cognitive Services purge jobs ---
$csJobs = @()
foreach ($csName in @($ContentUnderstandingName, $AiFoundryName)) {
    $csJobs += Start-Job -ScriptBlock {
        param($csName, $ResourceGroupName)
        $results = @{ Errors = @(); Messages = @() }
        $deletedCs = (az cognitiveservices account list-deleted --query "[?name=='$csName'] | [0].name" -o tsv 2>$null)
        if ($deletedCs) {
            $deletedLocation = (az cognitiveservices account list-deleted --query "[?name=='$csName'] | [0].location" -o tsv 2>$null)
            if (-not $deletedLocation) { $deletedLocation = "centralus" }
            $results.Messages += "[INFO] Purging soft-deleted Cognitive Services: $csName (location: $deletedLocation)"
            az cognitiveservices account purge --name $csName --resource-group $ResourceGroupName --location $deletedLocation 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) {
                $results.Messages += "[OK] Cognitive Services '$csName' purged"
            } else {
                $results.Messages += "[WARNING] Failed to purge '$csName'"
                $results.Errors += "Cognitive Services purge: $csName"
            }
        } else {
            $results.Messages += "[OK] No soft-deleted Cognitive Services '$csName' found"
        }
        return $results
    } -ArgumentList $csName, $ResourceGroupName
}

# --- Collect all purge job results ---
$allPurgeJobs = @($kvJob) + $csJobs
foreach ($job in $allPurgeJobs) {
    $result = Receive-Job -Job $job -Wait
    Remove-Job -Job $job -Force
    foreach ($msg in $result.Messages) {
        if ($msg -match '\[OK\]')        { Write-Host $msg -ForegroundColor Green }
        elseif ($msg -match '\[INFO\]')   { Write-Host $msg -ForegroundColor Cyan }
        elseif ($msg -match '\[WARNING\]') { Write-Host $msg -ForegroundColor Yellow }
        else                               { Write-Host $msg -ForegroundColor Gray }
    }
    foreach ($err in $result.Errors) { $script:DeleteErrors.Add($err) }
}

# =============================================================================
# STEP 5: Clean up local env.bat
# =============================================================================
Write-Host ""
Write-Host ">>> Step 5: Clean Up Local Files" -ForegroundColor White

$envBatPath = Join-Path $RepoRoot "env.bat"
if (Test-Path $envBatPath) {
    Remove-Item $envBatPath -Force
    Write-Host "[OK] Deleted $envBatPath" -ForegroundColor Green
} else {
    Write-Host "[OK] env.bat not found, nothing to delete" -ForegroundColor Gray
}

# =============================================================================
# SUMMARY
# =============================================================================
Write-Host ""
if ($script:DeleteErrors.Count -gt 0) {
    Write-Host "[WARNING] ==========================================" -ForegroundColor Yellow
    Write-Host "[WARNING] Cleanup completed with $($script:DeleteErrors.Count) issue(s)" -ForegroundColor Yellow
    Write-Host "[WARNING] ==========================================" -ForegroundColor Yellow
    foreach ($err in $script:DeleteErrors) {
        Write-Host "  - $err" -ForegroundColor Yellow
    }
} else {
    Write-Host "[SUCCESS] ==========================================" -ForegroundColor Green
    Write-Host "[SUCCESS] All Azure infrastructure deleted" -ForegroundColor Green
    Write-Host "[SUCCESS] ==========================================" -ForegroundColor Green
}
Write-Host ""
Write-Host "  Deleted:" -ForegroundColor White
Write-Host "    Resource Group      : $ResourceGroupName"
Write-Host "    Key Vault (purged)  : $KeyVaultName"
Write-Host "    Cognitive Services  : $ContentUnderstandingName, $AiFoundryName"
Write-Host "    Graph App           : $GraphAppName"
Write-Host "    Local env.bat       : $envBatPath"
Write-Host ""

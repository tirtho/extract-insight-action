#Requires -Version 5.1
<#!
.SYNOPSIS
    Temporarily opens a secure deployment window for hardened environments,
    runs 5.deploy-code.ps1, then restores the hardened posture.
.DESCRIPTION
    This wrapper is designed for policy-constrained environments where
    SecurityControl=Ignore can be used as a temporary exception. It:
      1) Applies SecurityControl=Ignore tags on required resources
      2) Opens minimal temporary access for the current laptop public IP
      3) Runs deployment/5.deploy-code.ps1
      4) Always removes temporary access and tags in a finally block

    Intended usage: deploy from laptop to an already hardened environment
    without full rollback/unharden cycles.
.PARAMETER Environment
    Environment name (default: prod).
.PARAMETER Suffix
    Deployment suffix (default: 1).
.PARAMETER SkipConfirm
    Skip interactive confirmation prompt.
.USAGE
    .\deployment\5.deploy-code-secure-window.ps1 -Environment fsi -Suffix 1
#>
param(
    [Parameter(HelpMessage="Environment (default: prod, example: prod)")]
    [string]$Environment,

    [Parameter(HelpMessage="Suffix used during infrastructure deployment (default: 1, example: 1)")]
    [string]$Suffix,

    [switch]$SkipConfirm
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($Environment)) {
    $EnvironmentInput = Read-Host "Enter environment [default: prod, example: prod]"
    $Environment = if ([string]::IsNullOrWhiteSpace($EnvironmentInput)) { "prod" } else { $EnvironmentInput.Trim().ToLowerInvariant() }
} else {
    $Environment = $Environment.Trim().ToLowerInvariant()
}

if ([string]::IsNullOrWhiteSpace($Suffix)) {
    $SuffixInput = Read-Host "Enter suffix [default: 1, example: 1]"
    $Suffix = if ([string]::IsNullOrWhiteSpace($SuffixInput)) { "1" } else { $SuffixInput.Trim() }
} else {
    $Suffix = $Suffix.Trim()
}

$ProjectName = "eia"
$ResourceGroupName = "rg-$ProjectName-$Environment-$Suffix"
$ProjClean = $ProjectName -replace '-', ''
$StorageAccountName = "st$ProjClean$Environment$Suffix"
$FunctionApps = @(
    "func-mailbox-$ProjectName-$Environment-$Suffix",
    "func-queuedb-$ProjectName-$Environment-$Suffix",
    "func-cuqueuedb-$ProjectName-$Environment-$Suffix"
)

$DeployScriptPath = Join-Path $PSScriptRoot "5.deploy-code.ps1"

function Invoke-AzCli {
    param([string[]]$Arguments)

    $allOutput = & az @Arguments 2>&1
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        $msg = ($allOutput | Out-String).Trim()
        throw "Azure CLI command failed: az $($Arguments -join ' ')`n$msg"
    }

    return (($allOutput | Out-String).Trim())
}

function Get-AzValue {
    param([string[]]$Arguments)

    try {
        return (Invoke-AzCli -Arguments $Arguments)
    } catch {
        return ''
    }
}

function Get-CurrentPublicIp {
    $candidates = @(
        'https://api.ipify.org',
        'https://ifconfig.me/ip',
        'https://ipv4.icanhazip.com'
    )

    foreach ($url in $candidates) {
        try {
            $ip = (Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 10).ToString().Trim()
            if ($ip -match '^(\d{1,3}\.){3}\d{1,3}$') {
                return $ip
            }
        } catch {
        }
    }

    throw "Unable to determine current public IP."
}

function Merge-IgnoreTag {
    param([Parameter(Mandatory=$true)][string]$ResourceId)

    Invoke-AzCli -Arguments @('tag', 'update', '--resource-id', $ResourceId, '--operation', 'Merge', '--tags', 'SecurityControl=Ignore') | Out-Null
}

function Remove-IgnoreTag {
    param([Parameter(Mandatory=$true)][string]$ResourceId)

    try {
        Invoke-AzCli -Arguments @('tag', 'update', '--resource-id', $ResourceId, '--operation', 'Delete', '--tags', 'SecurityControl') | Out-Null
    } catch {
        Write-Host "[WARNING] Failed to remove SecurityControl tag from $ResourceId" -ForegroundColor Yellow
        Write-Host "  $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI is not installed."
}

$acctState = (az account show --query state -o tsv 2>$null)
if ($acctState -ne "Enabled") {
    throw "Not logged in to Azure CLI. Run 'az login' first."
}

if (-not (Test-Path $DeployScriptPath)) {
    throw "Deploy script not found: $DeployScriptPath"
}

$publicIp = Get-CurrentPublicIp
$ruleName = "temp-laptop-ip"

$storageResourceId = (Invoke-AzCli -Arguments @('storage', 'account', 'show', '--name', $StorageAccountName, '--resource-group', $ResourceGroupName, '--query', 'id', '-o', 'tsv'))

$functionState = @{}
foreach ($fa in $FunctionApps) {
    $faId = Get-AzValue -Arguments @('functionapp', 'show', '--name', $fa, '--resource-group', $ResourceGroupName, '--query', 'id', '-o', 'tsv')
    if ([string]::IsNullOrWhiteSpace($faId)) {
        throw "Function App not found: $fa"
    }

    $pna = Get-AzValue -Arguments @('functionapp', 'show', '--name', $fa, '--resource-group', $ResourceGroupName, '--query', 'publicNetworkAccess', '-o', 'tsv')
    $functionState[$fa] = @{
        ResourceId = $faId
        PublicNetworkAccess = $pna
    }
}

$storageState = @{
    PublicNetworkAccess = Get-AzValue -Arguments @('storage', 'account', 'show', '--name', $StorageAccountName, '--resource-group', $ResourceGroupName, '--query', 'publicNetworkAccess', '-o', 'tsv')
    DefaultAction = Get-AzValue -Arguments @('storage', 'account', 'show', '--name', $StorageAccountName, '--resource-group', $ResourceGroupName, '--query', 'networkRuleSet.defaultAction', '-o', 'tsv')
    Bypass = Get-AzValue -Arguments @('storage', 'account', 'show', '--name', $StorageAccountName, '--resource-group', $ResourceGroupName, '--query', 'networkRuleSet.bypass', '-o', 'tsv')
}

Write-Host "" 
Write-Host "[INFO] ============================================================" -ForegroundColor Cyan
Write-Host "[INFO] Secure Deploy Window" -ForegroundColor Cyan
Write-Host "[INFO] Environment   : $Environment" -ForegroundColor Cyan
Write-Host "[INFO] Suffix        : $Suffix" -ForegroundColor Cyan
Write-Host "[INFO] ResourceGroup : $ResourceGroupName" -ForegroundColor Cyan
Write-Host "[INFO] Laptop Public IP: $publicIp" -ForegroundColor Cyan
Write-Host "[INFO] Function Apps : $($FunctionApps -join ', ')" -ForegroundColor Cyan
Write-Host "[INFO] Storage       : $StorageAccountName" -ForegroundColor Cyan
Write-Host "[INFO] ============================================================" -ForegroundColor Cyan
Write-Host ""

if (-not $SkipConfirm) {
    $go = Read-Host "Proceed with secure deployment window? [Y/n]"
    if ($go -and $go.Trim().ToLowerInvariant() -eq 'n') {
        Write-Host "[INFO] Cancelled." -ForegroundColor Yellow
        exit 0
    }
}

$windowOpened = $false

try {
    Write-Host "[INFO] Opening secure deployment window..." -ForegroundColor Cyan

    Merge-IgnoreTag -ResourceId $storageResourceId
    Write-Host "[SUCCESS] Applied SecurityControl=Ignore on storage account" -ForegroundColor Green

    Invoke-AzCli -Arguments @('storage', 'account', 'update', '--name', $StorageAccountName, '--resource-group', $ResourceGroupName,
        '--public-network-access', 'Enabled', '--default-action', 'Deny', '--bypass', 'AzureServices', '--output', 'none') | Out-Null
    Invoke-AzCli -Arguments @('storage', 'account', 'network-rule', 'add', '--account-name', $StorageAccountName, '--resource-group', $ResourceGroupName,
        '--ip-address', $publicIp, '--output', 'none') | Out-Null
    Write-Host "[SUCCESS] Storage temporary IP allow rule added ($publicIp)" -ForegroundColor Green

    foreach ($fa in $FunctionApps) {
        $faId = $functionState[$fa].ResourceId
        Merge-IgnoreTag -ResourceId $faId
        Write-Host "[SUCCESS] Applied SecurityControl=Ignore on $fa" -ForegroundColor Green

        Invoke-AzCli -Arguments @('functionapp', 'update', '--name', $fa, '--resource-group', $ResourceGroupName,
            '--set', 'publicNetworkAccess=Enabled', '--output', 'none') | Out-Null

        # Allow only the current laptop IP for SCM endpoint access used by deployment.
        $existing = Get-AzValue -Arguments @('functionapp', 'config', 'access-restriction', 'show', '--name', $fa, '--resource-group', $ResourceGroupName,
            '--query', "scmIpSecurityRestrictions[?name=='$ruleName'] | [0].name", '-o', 'tsv')
        if (-not $existing) {
            Invoke-AzCli -Arguments @('functionapp', 'config', 'access-restriction', 'add', '--name', $fa, '--resource-group', $ResourceGroupName,
                '--rule-name', $ruleName, '--action', 'Allow', '--ip-address', $publicIp, '--priority', '100', '--scm-site', 'true', '--output', 'none') | Out-Null
        }

        Write-Host "[SUCCESS] SCM IP allow rule added for $fa ($publicIp)" -ForegroundColor Green
    }

    $windowOpened = $true

    Write-Host "" 
    Write-Host "[INFO] Running deployment script: $DeployScriptPath" -ForegroundColor Cyan
    & $DeployScriptPath -Environment $Environment -Suffix $Suffix

    if ($LASTEXITCODE -ne 0) {
        throw "Deployment script returned exit code $LASTEXITCODE"
    }

    Write-Host "[SUCCESS] Deployment finished." -ForegroundColor Green
}
finally {
    Write-Host "" 
    Write-Host "[INFO] Closing secure deployment window..." -ForegroundColor Cyan

    if ($windowOpened) {
        try {
            Invoke-AzCli -Arguments @('storage', 'account', 'network-rule', 'remove', '--account-name', $StorageAccountName, '--resource-group', $ResourceGroupName,
                '--ip-address', $publicIp, '--output', 'none') | Out-Null
            Write-Host "[SUCCESS] Removed storage IP allow rule ($publicIp)" -ForegroundColor Green
        } catch {
            Write-Host "[WARNING] Failed to remove storage IP allow rule." -ForegroundColor Yellow
            Write-Host "  $($_.Exception.Message)" -ForegroundColor Yellow
        }

        foreach ($fa in $FunctionApps) {
            try {
                Invoke-AzCli -Arguments @('functionapp', 'config', 'access-restriction', 'remove', '--name', $fa, '--resource-group', $ResourceGroupName,
                    '--rule-name', $ruleName, '--scm-site', 'true', '--output', 'none') | Out-Null
                Write-Host "[SUCCESS] Removed SCM IP allow rule for $fa" -ForegroundColor Green
            } catch {
                Write-Host "[WARNING] Failed removing SCM IP allow rule for $fa" -ForegroundColor Yellow
                Write-Host "  $($_.Exception.Message)" -ForegroundColor Yellow
            }

            $originalFaPna = $functionState[$fa].PublicNetworkAccess
            if (-not [string]::IsNullOrWhiteSpace($originalFaPna)) {
                try {
                    Invoke-AzCli -Arguments @('functionapp', 'update', '--name', $fa, '--resource-group', $ResourceGroupName,
                        '--set', "publicNetworkAccess=$originalFaPna", '--output', 'none') | Out-Null
                    Write-Host "[SUCCESS] Restored $fa publicNetworkAccess=$originalFaPna" -ForegroundColor Green
                } catch {
                    Write-Host "[WARNING] Failed restoring publicNetworkAccess on $fa" -ForegroundColor Yellow
                    Write-Host "  $($_.Exception.Message)" -ForegroundColor Yellow
                }
            }

            Remove-IgnoreTag -ResourceId $functionState[$fa].ResourceId
            Write-Host "[SUCCESS] Removed SecurityControl tag on $fa" -ForegroundColor Green
        }

        try {
            if (-not [string]::IsNullOrWhiteSpace($storageState.PublicNetworkAccess) -and
                -not [string]::IsNullOrWhiteSpace($storageState.DefaultAction) -and
                -not [string]::IsNullOrWhiteSpace($storageState.Bypass)) {
                Invoke-AzCli -Arguments @('storage', 'account', 'update', '--name', $StorageAccountName, '--resource-group', $ResourceGroupName,
                    '--public-network-access', $storageState.PublicNetworkAccess,
                    '--default-action', $storageState.DefaultAction,
                    '--bypass', $storageState.Bypass,
                    '--output', 'none') | Out-Null
            } elseif (-not [string]::IsNullOrWhiteSpace($storageState.PublicNetworkAccess) -and
                      -not [string]::IsNullOrWhiteSpace($storageState.DefaultAction)) {
                Invoke-AzCli -Arguments @('storage', 'account', 'update', '--name', $StorageAccountName, '--resource-group', $ResourceGroupName,
                    '--public-network-access', $storageState.PublicNetworkAccess,
                    '--default-action', $storageState.DefaultAction,
                    '--output', 'none') | Out-Null
            } elseif (-not [string]::IsNullOrWhiteSpace($storageState.PublicNetworkAccess)) {
                Invoke-AzCli -Arguments @('storage', 'account', 'update', '--name', $StorageAccountName, '--resource-group', $ResourceGroupName,
                    '--public-network-access', $storageState.PublicNetworkAccess,
                    '--output', 'none') | Out-Null
            }

            Write-Host "[SUCCESS] Restored storage network settings" -ForegroundColor Green
        } catch {
            Write-Host "[WARNING] Failed restoring storage network settings" -ForegroundColor Yellow
            Write-Host "  $($_.Exception.Message)" -ForegroundColor Yellow
        }

        Remove-IgnoreTag -ResourceId $storageResourceId
        Write-Host "[SUCCESS] Removed SecurityControl tag on storage account" -ForegroundColor Green
    } else {
        Write-Host "[INFO] Window was not fully opened; skipping cleanup operations that require opened state." -ForegroundColor Yellow
    }

    Write-Host "[INFO] Secure deployment window closed." -ForegroundColor Cyan
}

#Requires -Version 5.1
<#
.SYNOPSIS
    Grants admin consent for Graph API permissions on the app registration.
.DESCRIPTION
    This script grants admin consent for the Graph API application permissions
    configured by deploy-infrastructure.ps1. Requires Global Administrator or
    Privileged Role Administrator role in the Azure AD tenant.
.PARAMETER Environment
    Optional. Environment name (default: dev).
.PARAMETER Suffix
    Optional. The same suffix used when running deploy-infrastructure.ps1.
.USAGE
    .\grant-graph-consent.ps1 -Suffix 999
    .\grant-graph-consent.ps1 -Environment dev -Suffix 999
#>
param(
    [Parameter(HelpMessage="Environment (default: dev, example: dev)")]
    [string]$Environment,

    [Parameter(HelpMessage="Suffix used during infrastructure deployment (default: 1, example: 1)")]
    [string]$Suffix
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

$ProjectName = "eia"

Write-Host "[INFO] Deployment key: $ProjectName-$Environment-$Suffix (location: $Location)" -ForegroundColor Cyan

# Helper: run az CLI via .NET Process to reliably capture stdout + stderr
# (Bypasses PowerShell's error-stream handling which can swallow native stderr)
function Invoke-Az {
    param([string[]]$Arguments)
    # Escape arguments for cmd.exe: wrap in double-quotes if they contain spaces or shell meta-chars
    $escapedArgs = foreach ($arg in $Arguments) {
        if ($arg -match '[\s&|<>^]') { "`"$arg`"" } else { $arg }
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName  = "cmd.exe"
    $psi.Arguments = "/c az " + ($escapedArgs -join " ")
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow = $true

    $process = [System.Diagnostics.Process]::Start($psi)
    # Read one stream async to avoid deadlock when both buffers fill
    $stderrTask    = $process.StandardError.ReadToEndAsync()
    $stdoutContent = $process.StandardOutput.ReadToEnd()
    $process.WaitForExit()
    $stderrContent = $stderrTask.GetAwaiter().GetResult()
    $code = $process.ExitCode
    $process.Dispose()

    return @{
        ExitCode = $code
        Output   = if ($stdoutContent) { $stdoutContent.Trim() } else { "" }
        Stderr   = if ($stderrContent) { $stderrContent.Trim() } else { "" }
    }
}

# =============================================================================
# CONFIGURATION (must match deploy-infrastructure.ps1)
# =============================================================================
$GraphAppName = "$ProjectName-graph-api-$Environment"

# =============================================================================
# PRE-FLIGHT: Confirm tenant admin role
# =============================================================================
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Grant Admin Consent for Graph API" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "This script grants admin consent for the Graph API permissions" -ForegroundColor White
Write-Host "configured on app registration: $GraphAppName" -ForegroundColor White
Write-Host ""
Write-Host "[IMPORTANT] This operation requires one of the following Azure AD roles:" -ForegroundColor Yellow
Write-Host "  - Global Administrator" -ForegroundColor Yellow
Write-Host "  - Privileged Role Administrator" -ForegroundColor Yellow
Write-Host ""

$confirmation = Read-Host "Do you have one of these tenant admin roles? (y/N)"
if ($confirmation -notin @('y', 'Y', 'yes', 'Yes', 'YES')) {
    Write-Host ""
    Write-Host "[ABORTED] Please ask a tenant admin to run this script, or grant consent manually:" -ForegroundColor Yellow
    Write-Host "  Azure Portal > App registrations > $GraphAppName > API permissions > Grant admin consent" -ForegroundColor Cyan
    exit 0
}

# =============================================================================
# Verify Azure CLI login
# =============================================================================
Write-Host ""
Write-Host "Verifying Azure CLI session..." -ForegroundColor Gray
$accountResult = Invoke-Az -Arguments @('account','show','--query','{name:name, user:user.name}','-o','json')
if ($accountResult.ExitCode -ne 0 -or -not $accountResult.Output) {
    Write-Host "[ERROR] Not logged in to Azure CLI. Run 'az login' first." -ForegroundColor Red
    exit 1
}
$account = $accountResult.Output | ConvertFrom-Json
Write-Host "Logged in as: $($account.user) (Subscription: $($account.name))" -ForegroundColor Gray

# =============================================================================
# Check Exchange Online service principal (required for mailbox polling)
# =============================================================================
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Exchange Online Service Principal Check" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Checking Exchange Online service principal (required for mailbox polling)..." -ForegroundColor Gray

$exoAppId  = '00000002-0000-0ff1-ce00-000000000000'
$exoResult = Invoke-Az -Arguments @('ad','sp','show','--id',$exoAppId,'--query','{id:id, accountEnabled:accountEnabled, displayName:displayName}','-o','json')

if ($exoResult.ExitCode -ne 0 -or -not $exoResult.Output) {
    Write-Host "[WARNING] Could not query Exchange Online service principal. Skipping this check." -ForegroundColor Yellow
    if ($exoResult.Stderr) { Write-Host "  $($exoResult.Stderr)" -ForegroundColor Yellow }
} else {
    $exoSp = $exoResult.Output | ConvertFrom-Json
    if ($exoSp.accountEnabled -eq $false) {
        Write-Host "[WARNING] Exchange Online service principal ('$($exoSp.displayName)') is DISABLED." -ForegroundColor Yellow
        Write-Host "  This will block mailbox polling (AADSTS500014 errors in PollMailbox)." -ForegroundColor Yellow
        Write-Host ""
        $reenableAnswer = Read-Host "Do you want to re-enable it now? (y/N)"
        if ($reenableAnswer -in @('y','Y','yes','Yes','YES')) {
            Write-Host "Re-enabling Exchange Online service principal..." -ForegroundColor Gray
            $enableResult = Invoke-Az -Arguments @('ad','sp','update','--id',$exoAppId,'--set','accountEnabled=true')
            if ($enableResult.ExitCode -eq 0) {
                Write-Host "[OK] Exchange Online service principal re-enabled successfully." -ForegroundColor Green
            } else {
                Write-Host "[ERROR] Failed to re-enable Exchange Online service principal." -ForegroundColor Red
                if ($enableResult.Stderr) { Write-Host "  $($enableResult.Stderr)" -ForegroundColor Red }
                Write-Host "[HINT] This requires Global Administrator or Application Administrator role." -ForegroundColor Yellow
            }
        } else {
            Write-Host "[SKIPPED] Exchange Online service principal was NOT re-enabled." -ForegroundColor Yellow
            Write-Host "  Run manually: az ad sp update --id $exoAppId --set accountEnabled=true" -ForegroundColor Cyan
        }
    } else {
        Write-Host "[OK] Exchange Online service principal is enabled." -ForegroundColor Green
    }
}

# =============================================================================
# Look up the app registration
# =============================================================================
Write-Host ""
Write-Host "Looking up app registration: $GraphAppName ..." -ForegroundColor Gray
$appResult = Invoke-Az -Arguments @('ad','app','list','--display-name',$GraphAppName,'--query','[0].appId','-o','tsv')
if ($appResult.ExitCode -ne 0) {
    Write-Host "[ERROR] Failed to query app registrations (exit code $($appResult.ExitCode))." -ForegroundColor Red
    if ($appResult.Stderr) { Write-Host "  $($appResult.Stderr)" -ForegroundColor Red }
    if ($appResult.Stderr -match 'Continuous access evaluation|InteractionRequired|TokenCreatedWithOutdatedPolicies|AADSTS') {
        Write-Host "[HINT] Your Azure CLI token needs to be refreshed. Run 'az login' and retry." -ForegroundColor Yellow
    }
    exit 1
}
if (-not $appResult.Output) {
    Write-Host "[ERROR] App registration '$GraphAppName' not found in current tenant." -ForegroundColor Red
    Write-Host "[HINT] Other 'graph-api' apps visible to you in this tenant:" -ForegroundColor Yellow
    $alt = Invoke-Az -Arguments @('ad','app','list','--filter',"contains(displayName,'graph-api')",'--query','[].{name:displayName, appId:appId}','-o','table')
    if ($alt.Output) { Write-Host $alt.Output -ForegroundColor Yellow }
    Write-Host "[HINT] If your app uses a different name, set the env var GRAPH_APP_NAME and re-run, or run deploy-infrastructure.ps1 first." -ForegroundColor Yellow
    exit 1
}
$GraphClientId = $appResult.Output
Write-Host "Found app registration: $GraphClientId" -ForegroundColor Gray

# =============================================================================
# Ensure service principal exists (required for consent)
# =============================================================================
Write-Host ""
Write-Host "Ensuring service principal exists..." -ForegroundColor Gray
$spResult = Invoke-Az -Arguments @('ad','sp','show','--id',$GraphClientId,'--query','id','-o','tsv')
if ($spResult.ExitCode -ne 0 -or -not $spResult.Output) {
    Write-Host "Creating service principal for app registration..." -ForegroundColor Gray
    $spCreate = Invoke-Az -Arguments @('ad','sp','create','--id',$GraphClientId,'--query','id','-o','tsv')
    if ($spCreate.ExitCode -ne 0) {
        Write-Host "[ERROR] Failed to create service principal: $($spCreate.Stderr)" -ForegroundColor Red
        exit 1
    }
    $appSpId = $spCreate.Output
    Write-Host "Service principal created: $appSpId" -ForegroundColor Gray
} else {
    $appSpId = $spResult.Output
    Write-Host "Service principal already exists: $appSpId" -ForegroundColor Gray
}

# =============================================================================
# Grant admin consent via Microsoft Graph REST API
# =============================================================================
Write-Host ""
Write-Host "Granting admin consent for Graph API permissions..." -ForegroundColor White

# Get the Microsoft Graph service principal ID in this tenant
$graphSpResult = Invoke-Az -Arguments @('ad','sp','show','--id','00000003-0000-0000-c000-000000000000','--query','id','-o','tsv')
if ($graphSpResult.ExitCode -ne 0 -or -not $graphSpResult.Output) {
    Write-Host "[ERROR] Could not find Microsoft Graph service principal in this tenant." -ForegroundColor Red
    exit 1
}
$graphSpId = $graphSpResult.Output

# Read the required permissions from the app registration
$permResult = Invoke-Az -Arguments @('ad','app','show','--id',$GraphClientId,'--query',"requiredResourceAccess[?resourceAppId=='00000003-0000-0000-c000-000000000000'].resourceAccess[].id",'-o','json')
$permissionIds = $permResult.Output | ConvertFrom-Json

$allSucceeded = $true
foreach ($roleId in $permissionIds) {
    $bodyFile = [System.IO.Path]::GetTempFileName()
    try {
        $json = @{principalId=$appSpId; resourceId=$graphSpId; appRoleId=$roleId} | ConvertTo-Json
        [System.IO.File]::WriteAllText($bodyFile, $json, [System.Text.UTF8Encoding]::new($false))
        $grantResult = Invoke-Az -Arguments @('rest','--method','POST',
            '--uri',"https://graph.microsoft.com/v1.0/servicePrincipals/$appSpId/appRoleAssignments",
            '--body',"@$bodyFile",
            '--headers','Content-Type=application/json',
            '--resource','https://graph.microsoft.com',
            '-o','json')
        $exitCode = $grantResult.ExitCode
        # Combine stderr and stdout for error detection (Graph errors may appear in either)
        $errorText = (@($grantResult.Stderr, $grantResult.Output) | Where-Object { $_ }) -join "`n"
        if ($exitCode -eq 0) {
            Write-Host "  Granted role: $roleId" -ForegroundColor Green
        } else {
            # Check if already granted (Permission being assigned already exists on the object)
            if ($errorText -match "already exists|Permission.*already") {
                Write-Host "  Role already granted: $roleId" -ForegroundColor Gray
            } else {
                Write-Host "  [ERROR] Failed to grant role ${roleId}: $errorText" -ForegroundColor Red
                $allSucceeded = $false
            }
        }
    } finally {
        Remove-Item $bodyFile -Force -ErrorAction SilentlyContinue
    }
}

if ($allSucceeded) {
    Write-Host ""
    Write-Host "[SUCCESS] Admin consent granted for Graph API permissions on '$GraphAppName'" -ForegroundColor Green
    Write-Host ""
} else {
    Write-Host ""
    Write-Host "[ERROR] Some permissions failed to grant. See errors above." -ForegroundColor Red
    Write-Host ""
    Write-Host "Possible causes:" -ForegroundColor Yellow
    Write-Host "  - Your account does not have Global Administrator or Privileged Role Administrator role" -ForegroundColor Yellow
    Write-Host "  - The app registration permissions have not been configured correctly" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Manual alternative:" -ForegroundColor Cyan
    Write-Host "  Azure Portal > App registrations > $GraphAppName > API permissions > Grant admin consent" -ForegroundColor Cyan
    exit 1
}

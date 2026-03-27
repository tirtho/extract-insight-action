#Requires -Version 5.1
<#
.SYNOPSIS
    Rotates the Graph API client secret and updates Azure Key Vault.
.DESCRIPTION
    Removes all existing client credentials from the Entra ID app registration,
    creates a new 2-year client secret, and stores it in Key Vault. Designed to
    be run periodically before the current secret expires.
.PARAMETER Suffix
    Required. The same suffix used when running deploy-infrastructure.ps1.
.PARAMETER ExpiryYears
    Optional. Number of years until the new secret expires. Default: 2.
.USAGE
    .\rotate-graph-api-secret.ps1 -Suffix 999
    .\rotate-graph-api-secret.ps1 -Suffix 999 -ExpiryYears 1
#>
param(
    [Parameter(Mandatory=$true, HelpMessage="Suffix used during infrastructure deployment (e.g. 999)")]
    [ValidateNotNullOrEmpty()]
    [string]$Suffix,

    [Parameter(Mandatory=$false)]
    [ValidateRange(1, 5)]
    [int]$ExpiryYears = 2
)

$ErrorActionPreference = "Stop"

# =============================================================================
# CONFIGURATION (must match deploy-infrastructure.ps1)
# =============================================================================
$ProjectName  = if ($env:PROJECT_NAME)   { $env:PROJECT_NAME }   else { "eia" }
$Environment  = if ($env:ENVIRONMENT)    { $env:ENVIRONMENT }    else { "dev" }
$KeyVaultName = if ($env:KEY_VAULT_NAME) { $env:KEY_VAULT_NAME } else { "kv-$ProjectName-$Environment-$Suffix" }
$GraphAppName = if ($env:GRAPH_APP_NAME) { $env:GRAPH_APP_NAME } else { "$ProjectName-graph-api-$Environment" }

# =============================================================================
# HELPER
# =============================================================================
function Invoke-Az {
    param([string[]]$Arguments)
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
# BANNER
# =============================================================================
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Rotate Graph API Client Secret" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "App registration : $GraphAppName" -ForegroundColor White
Write-Host "Key Vault        : $KeyVaultName" -ForegroundColor White
Write-Host "Expiry           : $ExpiryYears year(s)" -ForegroundColor White
Write-Host ""

# =============================================================================
# VERIFY AZURE CLI LOGIN
# =============================================================================
Write-Host "Verifying Azure CLI session..." -ForegroundColor Gray
$accountResult = Invoke-Az -Arguments @('account','show','--query','{name:name, user:user.name}','-o','json')
if ($accountResult.ExitCode -ne 0 -or -not $accountResult.Output) {
    Write-Host "[ERROR] Not logged in to Azure CLI. Run 'az login' first." -ForegroundColor Red
    exit 1
}
$account = $accountResult.Output | ConvertFrom-Json
Write-Host "Logged in as: $($account.user) (Subscription: $($account.name))" -ForegroundColor Gray

# =============================================================================
# LOOK UP APP REGISTRATION
# =============================================================================
Write-Host ""
Write-Host "Looking up app registration: $GraphAppName ..." -ForegroundColor Gray
$appResult = Invoke-Az -Arguments @('ad','app','list','--display-name',$GraphAppName,'--query','[0].appId','-o','tsv')
if ($appResult.ExitCode -ne 0 -or -not $appResult.Output) {
    Write-Host "[ERROR] App registration '$GraphAppName' not found. Run deploy-infrastructure.ps1 first." -ForegroundColor Red
    exit 1
}
$GraphClientId = $appResult.Output
Write-Host "Found app registration: $GraphClientId" -ForegroundColor Green

# =============================================================================
# VERIFY KEY VAULT ACCESS
# =============================================================================
Write-Host ""
Write-Host "Verifying Key Vault access: $KeyVaultName ..." -ForegroundColor Gray
$kvCheck = Invoke-Az -Arguments @('keyvault','show','--name',$KeyVaultName,'--query','name','-o','tsv')
if ($kvCheck.ExitCode -ne 0 -or -not $kvCheck.Output) {
    Write-Host "[ERROR] Key Vault '$KeyVaultName' not found or not accessible." -ForegroundColor Red
    exit 1
}
Write-Host "Key Vault accessible" -ForegroundColor Green

# =============================================================================
# SHOW CURRENT CREDENTIALS
# =============================================================================
Write-Host ""
Write-Host "Checking existing credentials..." -ForegroundColor Gray
$credsResult = Invoke-Az -Arguments @('ad','app','credential','list','--id',$GraphClientId,'-o','json')
if ($credsResult.ExitCode -eq 0 -and $credsResult.Output) {
    $creds = $credsResult.Output | ConvertFrom-Json
    if ($creds.Count -gt 0) {
        Write-Host "  Found $($creds.Count) existing credential(s):" -ForegroundColor Gray
        foreach ($cred in $creds) {
            $endDate = if ($cred.endDateTime) { $cred.endDateTime } else { "unknown" }
            Write-Host "    - KeyId: $($cred.keyId)  Expires: $endDate" -ForegroundColor Gray
        }
    } else {
        Write-Host "  No existing credentials found" -ForegroundColor Yellow
    }
} else {
    Write-Host "  Could not list existing credentials" -ForegroundColor Yellow
}

# =============================================================================
# CONFIRM ROTATION
# =============================================================================
Write-Host ""
Write-Host "[WARNING] This will:" -ForegroundColor Yellow
Write-Host "  1. Remove ALL existing client secrets from the app registration" -ForegroundColor Yellow
Write-Host "  2. Create a new client secret (valid for $ExpiryYears year(s))" -ForegroundColor Yellow
Write-Host "  3. Update the 'GraphClientSecret' secret in Key Vault" -ForegroundColor Yellow
Write-Host ""
Write-Host "Any application using the current secret will need to pick up the" -ForegroundColor Yellow
Write-Host "new value from Key Vault after rotation completes." -ForegroundColor Yellow
Write-Host ""

$confirmation = Read-Host "Proceed with secret rotation? (y/N)"
if ($confirmation -notin @('y', 'Y', 'yes', 'Yes', 'YES')) {
    Write-Host ""
    Write-Host "[ABORTED] No changes were made." -ForegroundColor Yellow
    exit 0
}

# =============================================================================
# STEP 1: REMOVE OLD CREDENTIALS
# =============================================================================
Write-Host ""
Write-Host "[Step 1/3] Removing existing credentials..." -ForegroundColor Cyan

if ($credsResult.ExitCode -eq 0 -and $credsResult.Output) {
    $creds = $credsResult.Output | ConvertFrom-Json
    foreach ($cred in $creds) {
        $keyId = $cred.keyId
        Write-Host "  Removing credential: $keyId" -ForegroundColor Gray
        $removeResult = Invoke-Az -Arguments @('ad','app','credential','delete','--id',$GraphClientId,'--key-id',$keyId)
        if ($removeResult.ExitCode -ne 0) {
            Write-Host "  [ERROR] Failed to remove credential $keyId : $($removeResult.Stderr)" -ForegroundColor Red
            exit 1
        }
    }
    Write-Host "  All existing credentials removed" -ForegroundColor Green
} else {
    Write-Host "  No credentials to remove" -ForegroundColor Gray
}

# =============================================================================
# STEP 2: CREATE NEW SECRET
# =============================================================================
Write-Host ""
Write-Host "[Step 2/3] Creating new client secret (expires in $ExpiryYears year(s))..." -ForegroundColor Cyan

$resetResult = Invoke-Az -Arguments @('ad','app','credential','reset','--id',$GraphClientId,
    '--display-name','extract-insight-action-secret',
    '--years',"$ExpiryYears",
    '--query','password','-o','tsv')

if ($resetResult.ExitCode -ne 0 -or -not $resetResult.Output) {
    Write-Host "[ERROR] Failed to create new client secret: $($resetResult.Stderr)" -ForegroundColor Red
    exit 1
}

$NewSecret = $resetResult.Output
Write-Host "  New client secret created successfully" -ForegroundColor Green

# =============================================================================
# STEP 3: UPDATE KEY VAULT
# =============================================================================
Write-Host ""
Write-Host "[Step 3/3] Updating Key Vault secret 'GraphClientSecret'..." -ForegroundColor Cyan

$kvResult = Invoke-Az -Arguments @('keyvault','secret','set','--vault-name',$KeyVaultName,
    '--name','GraphClientSecret',
    '--value',$NewSecret,
    '--output','none')

if ($kvResult.ExitCode -ne 0) {
    Write-Host "[ERROR] Failed to update Key Vault secret: $($kvResult.Stderr)" -ForegroundColor Red
    Write-Host ""
    Write-Host "[CRITICAL] The new secret was created in Entra ID but NOT saved to Key Vault." -ForegroundColor Red
    Write-Host "You must manually store the secret in Key Vault:" -ForegroundColor Red
    Write-Host "  az keyvault secret set --vault-name $KeyVaultName --name GraphClientSecret --value '<secret>'" -ForegroundColor Yellow
    exit 1
}

Write-Host "  Key Vault secret updated successfully" -ForegroundColor Green

# =============================================================================
# VERIFY
# =============================================================================
Write-Host ""
Write-Host "Verifying rotation..." -ForegroundColor Gray

$verifyResult = Invoke-Az -Arguments @('keyvault','secret','show','--vault-name',$KeyVaultName,
    '--name','GraphClientSecret','--query','{updated:attributes.updated, expires:attributes.expires}','-o','json')
if ($verifyResult.ExitCode -eq 0 -and $verifyResult.Output) {
    $verifyData = $verifyResult.Output | ConvertFrom-Json
    Write-Host "  Key Vault secret last updated: $($verifyData.updated)" -ForegroundColor Gray
}

$newCredResult = Invoke-Az -Arguments @('ad','app','credential','list','--id',$GraphClientId,'--query','[0].endDateTime','-o','tsv')
if ($newCredResult.ExitCode -eq 0 -and $newCredResult.Output) {
    Write-Host "  Entra ID credential expires:   $($newCredResult.Output)" -ForegroundColor Gray
}

# =============================================================================
# SUMMARY
# =============================================================================
Write-Host ""
Write-Host "[SUCCESS] Graph API client secret rotation complete" -ForegroundColor Green
Write-Host ""
Write-Host "  App registration : $GraphAppName ($GraphClientId)" -ForegroundColor White
Write-Host "  Key Vault        : $KeyVaultName" -ForegroundColor White
Write-Host "  Secret name      : GraphClientSecret" -ForegroundColor White
Write-Host ""
Write-Host "[INFO] Applications using Key Vault references will pick up the new" -ForegroundColor Cyan
Write-Host "       secret automatically. If any service caches the secret value," -ForegroundColor Cyan
Write-Host "       restart it to force a refresh." -ForegroundColor Cyan
Write-Host ""

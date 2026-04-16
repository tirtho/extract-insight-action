#Requires -Version 5.1
<#
.SYNOPSIS
    Sets application configuration secrets in Azure Key Vault.
.DESCRIPTION
    Stores application settings as Key Vault secrets for use by Function Apps
    and other services. Idempotent - can be run multiple times safely.
.PARAMETER Suffix
    Required. The same suffix used when running deploy-infrastructure.ps1.
.USAGE
    .\kv-settings-for-applications.ps1 -Suffix 999
#>
param(
    [Parameter(Mandatory=$true, HelpMessage="Suffix used during infrastructure deployment (e.g. 999)")]
    [ValidateNotNullOrEmpty()]
    [string]$Suffix
)

$ErrorActionPreference = "Stop"

# =============================================================================
# CONFIGURATION
# =============================================================================
$ProjectName = if ($env:PROJECT_NAME) { $env:PROJECT_NAME } else { "eia" }
$Environment = if ($env:ENVIRONMENT)  { $env:ENVIRONMENT }  else { "dev" }
$KeyVaultName = if ($env:KEY_VAULT_NAME) { $env:KEY_VAULT_NAME } else { "kv-$ProjectName-$Environment-$Suffix" }

# Resolve environment-sourced values
# USER_EMAIL_ADDRESS is required for the application to function, 
# so we check it here and exit if it's not set.
$UserEmailAddress = if ($env:USER_EMAIL_ADDRESS) { $env:USER_EMAIL_ADDRESS } else {
    Write-Host "[ERROR] USER_EMAIL_ADDRESS environment variable is not set." -ForegroundColor Red
    exit 1
}
# Add the MailboxPollingSchedule variable in key vault
$MailboxPollingSchedule = if ($env:MAILBOX_POLLING_SCHEDULE) { $env:MAILBOX_POLLING_SCHEDULE } else { "0 */5 * * * *" }
# Add PollingMailboxName, but we can default to "Inbox" if not set, since that's a common scenario.
$PollingMailboxName = if ($env:POLLING_MAILBOX_NAME) { $env:POLLING_MAILBOX_NAME } else { "Inbox" }
# Add ReadMailboxForPastNSeconds, defaulting to 60 seconds if not set, which is a reasonable default for many scenarios.
$ReadMailboxForPastNSeconds = if ($env:READ_MAILBOX_FOR_PAST_N_SECONDS) { $env:READ_MAILBOX_FOR_PAST_N_SECONDS } else { "3600" }  

# =============================================================================
# HELPER FUNCTION
# =============================================================================
function Set-KeyVaultSecret {
    param([string]$VaultName, [string]$SecretName, [string]$SecretValue)
    Write-Host "[INFO] Setting Key Vault secret: $SecretName" -ForegroundColor Cyan
    $output = az keyvault secret set --vault-name $VaultName --name $SecretName --value $SecretValue --output none 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] Failed to set secret '$SecretName': $output" -ForegroundColor Red
        return $false
    }
    Write-Host "[OK]   Secret '$SecretName' set successfully." -ForegroundColor Green
    return $true
}

# =============================================================================
# SET KEY VAULT SECRETS
# =============================================================================
Write-Host ""
Write-Host "[INFO] ============================================================" -ForegroundColor Cyan
Write-Host "[INFO] Setting application secrets in Key Vault: $KeyVaultName"      -ForegroundColor Cyan
Write-Host "[INFO] ============================================================" -ForegroundColor Cyan
Write-Host ""

$allSucceeded = $true

if (-not (Set-KeyVaultSecret -VaultName $KeyVaultName -SecretName "ReadMailboxForPastNSeconds" -SecretValue $ReadMailboxForPastNSeconds)) { $allSucceeded = $false }
if (-not (Set-KeyVaultSecret -VaultName $KeyVaultName -SecretName "MailboxPollingSchedule" -SecretValue $MailboxPollingSchedule)) { $allSucceeded = $false }
if (-not (Set-KeyVaultSecret -VaultName $KeyVaultName -SecretName "UserEmailAddress" -SecretValue $UserEmailAddress)) { $allSucceeded = $false }
if (-not (Set-KeyVaultSecret -VaultName $KeyVaultName -SecretName "PollingMailboxName" -SecretValue $PollingMailboxName)) { $allSucceeded = $false }

# =============================================================================
# SUMMARY
# =============================================================================
Write-Host ""
if ($allSucceeded) {
    Write-Host "[INFO] All Key Vault secrets set successfully." -ForegroundColor Green
} else {
    Write-Host "[WARN] One or more secrets failed to set. Review the output above." -ForegroundColor Yellow
    exit 1
}

# =============================================================================
# Configuration for extract-insight-action Infrastructure Deployment (PowerShell)
#
# Reads variables from env.config and sets them as environment variables,
# then prompts for the deployment suffix to derive KEY_VAULT_URL.
#
# Dot-source this file before running deployment scripts:
#   . .\1.config.ps1
#   .\deploy-infrastructure.ps1 -Suffix 999
# =============================================================================

$configFile = Join-Path $PSScriptRoot "env.config"
if (-not (Test-Path $configFile)) {
    Write-Host "[ERROR] env.config not found at $configFile" -ForegroundColor Red
    return
}

Get-Content $configFile | ForEach-Object {
    $line = $_.Trim()
    if ($line -and -not $line.StartsWith('#') -and $line -match '^([^=]+)=(.*)$') {
        $name  = $Matches[1].Trim()
        $value = $Matches[2].Trim().Trim('"')
        [System.Environment]::SetEnvironmentVariable($name, $value, 'Process')
    }
}

Write-Host "[INFO] Environment variables loaded from env.config" -ForegroundColor Cyan

# =============================================================================
# Prompt for suffix and derive KEY_VAULT_URL
# =============================================================================
$ProjectName = if ($env:PROJECT_NAME) { $env:PROJECT_NAME } else { "eia" }
$Environment = if ($env:ENVIRONMENT)  { $env:ENVIRONMENT }  else { "dev" }

$Suffix = Read-Host "Enter deployment suffix (e.g. 1)"
if (-not $Suffix) {
    Write-Host "[ERROR] Suffix is required." -ForegroundColor Red
    return
}

$KeyVaultName = "kv-$ProjectName-$Environment-$Suffix"
$env:KEY_VAULT_URL = "https://$KeyVaultName.vault.azure.net"
Write-Host "[OK] KEY_VAULT_URL = $env:KEY_VAULT_URL" -ForegroundColor Green

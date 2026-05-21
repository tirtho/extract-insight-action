# =============================================================================
# Configuration for extract-insight-action Infrastructure Deployment (PowerShell)
#
# Reads variables from env.config and sets them as environment variables,
# then prompts for the deployment suffix to derive AZURE_KEY_VAULT_URL.
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

$loadedVars = @()
Get-Content $configFile | ForEach-Object {
    $line = $_.Trim()
    if ($line -and -not $line.StartsWith('#') -and $line -match '^([^=]+)=(.*)$') {
        $name  = $Matches[1].Trim()
        $value = $Matches[2].Trim().Trim('"')
        # Set on the current PowerShell session (env: drive) AND the underlying
        # process environment so child processes (az, mvn, func, etc.) inherit them.
        Set-Item -Path "env:$name" -Value $value
        [System.Environment]::SetEnvironmentVariable($name, $value, 'Process')
        $loadedVars += $name
    }
}

Write-Host "[INFO] Loaded $($loadedVars.Count) environment variable(s) from env.config:" -ForegroundColor Cyan
foreach ($n in $loadedVars) {
    Write-Host "  $n = $([System.Environment]::GetEnvironmentVariable($n, 'Process'))" -ForegroundColor Gray
}

# =============================================================================
# Prompt for suffix and derive AZURE_KEY_VAULT_URL
# =============================================================================
$ProjectName = if ($env:PROJECT_NAME) { $env:PROJECT_NAME } else { "eia" }
$Environment = if ($env:ENVIRONMENT)  { $env:ENVIRONMENT }  else { "dev" }

$Suffix = Read-Host "Enter deployment suffix (e.g. 1)"
if (-not $Suffix) {
    Write-Host "[ERROR] Suffix is required." -ForegroundColor Red
    return
}

$KeyVaultName = "kv-$ProjectName-$Environment-$Suffix"
$env:SUFFIX                = $Suffix
$env:KEY_VAULT_NAME        = $KeyVaultName
$env:AZURE_KEY_VAULT_URL   = "https://$KeyVaultName.vault.azure.net"
[System.Environment]::SetEnvironmentVariable('SUFFIX',               $env:SUFFIX,               'Process')
[System.Environment]::SetEnvironmentVariable('KEY_VAULT_NAME',       $env:KEY_VAULT_NAME,       'Process')
[System.Environment]::SetEnvironmentVariable('AZURE_KEY_VAULT_URL',  $env:AZURE_KEY_VAULT_URL,  'Process')

Write-Host "[OK] SUFFIX                = $env:SUFFIX" -ForegroundColor Green
Write-Host "[OK] KEY_VAULT_NAME        = $env:KEY_VAULT_NAME" -ForegroundColor Green
Write-Host "[OK] AZURE_KEY_VAULT_URL   = $env:AZURE_KEY_VAULT_URL" -ForegroundColor Green

# =============================================================================
# Generate env.bat in the repo root (AZURE_KEY_VAULT_URL for tools that source env.bat)
# =============================================================================
$envBatPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'env.bat'
$envBatContent = "@echo off`r`nset AZURE_KEY_VAULT_URL=$($env:AZURE_KEY_VAULT_URL)`r`nset AI_FOUNDRY_REASONING_EFFORT=medium`r`nset AGENT_CONVERSATION_TTL_HOURS=168"
Set-Content -Path $envBatPath -Value $envBatContent -Encoding ASCII -Force
Write-Host "[OK] Wrote $envBatPath" -ForegroundColor Green

if ($MyInvocation.InvocationName -ne '.') {
    Write-Host ""
    Write-Host "[WARNING] This script was not dot-sourced. The environment variables" -ForegroundColor Yellow
    Write-Host "          will be lost when this script exits." -ForegroundColor Yellow
    Write-Host "          Re-run with:  . .\1.config.ps1" -ForegroundColor Yellow
}

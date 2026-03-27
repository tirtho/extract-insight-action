# =============================================================================
# Configuration for extract-insight-action Infrastructure Deployment (PowerShell)
#
# Reads variables from env.config and sets them as environment variables.
# Dot-source this file before running deployment scripts:
#   . .\config.ps1
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

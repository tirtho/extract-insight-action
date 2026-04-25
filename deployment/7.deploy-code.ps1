#Requires -Version 5.1
<#
.SYNOPSIS
    Builds and deploys a function app to Azure.
.DESCRIPTION
    Prompts the user to select which function to deploy (mailbox-to-queue or
    queue-to-db), derives the target Function App name from the same naming
    convention used by deploy-infrastructure.ps1, confirms with the user, then
    builds the JAR with Maven and deploys it via the SCM OneDeploy API.
.PARAMETER Suffix
    Required. The same suffix used when running deploy-infrastructure.ps1.
.USAGE
    .\6.deploy-code.ps1 -Suffix 999
#>
param(
    [Parameter(Mandatory=$true, HelpMessage="Suffix used during infrastructure deployment (e.g. 999)")]
    [ValidateNotNullOrEmpty()]
    [string]$Suffix,

    [Parameter(HelpMessage="Maximum time to allow each Maven package run before failing. Use 0 to disable the timeout.")]
    [ValidateRange(0, 1440)]
    [int]$MavenTimeoutMinutes = 15
)

$ErrorActionPreference = "Stop"

# =============================================================================
# CONFIGURATION  (mirrors deploy-infrastructure.ps1 naming conventions)
# =============================================================================
$ProjectName       = if ($env:PROJECT_NAME)              { $env:PROJECT_NAME }              else { "eia" }
$Environment       = if ($env:ENVIRONMENT)               { $env:ENVIRONMENT }               else { "dev" }
$ResourceGroupName = if ($env:RESOURCE_GROUP_NAME)       { $env:RESOURCE_GROUP_NAME }       else { "rg-$ProjectName-$Environment-$Suffix" }
$FuncMailboxName   = if ($env:FUNCTION_APP_MAILBOX_NAME) { $env:FUNCTION_APP_MAILBOX_NAME } else { "func-mailbox-$ProjectName-$Environment-$Suffix" }
$FuncQueueDbName   = if ($env:FUNCTION_APP_QUEUE_DB_NAME){ $env:FUNCTION_APP_QUEUE_DB_NAME }else { "func-queuedb-$ProjectName-$Environment-$Suffix" }
$FuncCuQueueDbName = if ($env:FUNCTION_APP_CU_QUEUE_DB_NAME){ $env:FUNCTION_APP_CU_QUEUE_DB_NAME }else { "func-cuqueuedb-$ProjectName-$Environment-$Suffix" }
$ProjClean         = $ProjectName -replace '-',''
$StorageAccountName = if ($env:STORAGE_ACCOUNT_NAME)    { $env:STORAGE_ACCOUNT_NAME }      else { "st$ProjClean$Environment$Suffix" }

$ScriptRoot      = $PSScriptRoot
$RepoRoot        = Split-Path $ScriptRoot -Parent
$FunctionsRoot   = Join-Path $RepoRoot "extract\functions"

# =============================================================================
# PREREQUISITES
# =============================================================================
Write-Host ""
Write-Host "[INFO] ============================================================" -ForegroundColor Cyan
Write-Host "[INFO] Function App Code Deployment"                                  -ForegroundColor Cyan
Write-Host "[INFO] Project     : $ProjectName"                                    -ForegroundColor Cyan
Write-Host "[INFO] Environment : $Environment"                                    -ForegroundColor Cyan
Write-Host "[INFO] Suffix      : $Suffix"                                         -ForegroundColor Cyan
Write-Host "[INFO] ============================================================" -ForegroundColor Cyan
Write-Host ""

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Host "[ERROR] Azure CLI is not installed." -ForegroundColor Red
    exit 1
}

$acctState = az account show --query state -o tsv 2>$null
if ($acctState -ne "Enabled") {
    Write-Host "[ERROR] Not logged in to Azure CLI. Run 'az login' first." -ForegroundColor Red
    exit 1
}

if (-not $env:JAVA_HOME) {
    Write-Host "[ERROR] JAVA_HOME is not set." -ForegroundColor Red
    exit 1
}
$mvn = Get-Command mvn -ErrorAction SilentlyContinue
if (-not $mvn) {
    Write-Host "[ERROR] Maven (mvn) is not on PATH." -ForegroundColor Red
    exit 1
}

function Ensure-FunctionHostSettings {
    param(
        [Parameter(Mandatory=$true)][string]$FunctionAppName,
        [Parameter(Mandatory=$true)][string]$ResourceGroupName,
        [Parameter(Mandatory=$true)][string]$StorageAccountName
    )

    Write-Host "[INFO] Ensuring required Functions host settings on $FunctionAppName..." -ForegroundColor Cyan
    # Note: FUNCTIONS_WORKER_RUNTIME and FUNCTIONS_EXTENSION_VERSION are managed
    # by the platform on Flex Consumption plans and must NOT be set as app settings.
    $settingsOutput = az functionapp config appsettings set `
        --name $FunctionAppName `
        --resource-group $ResourceGroupName `
        --settings `
            AzureWebJobsStorage__accountName=$StorageAccountName `
        --output none 2>&1

    if ($LASTEXITCODE -ne 0) {
        $errMsg = ($settingsOutput | Out-String).Trim()
        throw "Failed to set required app settings on ${FunctionAppName}:`n  $errMsg"
    }
}

function Write-NewLogContent {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][ref]$LineCount
    )

    if (-not (Test-Path $Path)) {
        return
    }

    $lines = Get-Content -Path $Path
    if ($lines.Count -le $LineCount.Value) {
        return
    }

    foreach ($line in $lines[$LineCount.Value..($lines.Count - 1)]) {
        if ($null -ne $line -and $line -ne '') {
            Write-Host $line
        } else {
            Write-Host ''
        }
    }

    $LineCount.Value = $lines.Count
}

function Invoke-MavenPackage {
    param(
        [Parameter(Mandatory=$true)][string]$SourceDir,
        [Parameter(Mandatory=$true)][string]$FunctionLabel,
        [Parameter(Mandatory=$true)][string]$MavenPath,
        [Parameter(Mandatory=$true)][int]$TimeoutMinutes
    )

    $stdoutLog = Join-Path $env:TEMP ("$FunctionLabel-maven-stdout.log")
    $stderrLog = Join-Path $env:TEMP ("$FunctionLabel-maven-stderr.log")
    Remove-Item $stdoutLog, $stderrLog -Force -ErrorAction SilentlyContinue

    $process = Start-Process `
        -FilePath $MavenPath `
        -ArgumentList @('clean', 'package', '-DskipTests', '--no-transfer-progress') `
        -WorkingDirectory $SourceDir `
        -NoNewWindow `
        -PassThru `
        -RedirectStandardOutput $stdoutLog `
        -RedirectStandardError $stderrLog

    $stdoutLineCount = 0
    $stderrLineCount = 0
    $deadline = if ($TimeoutMinutes -gt 0) { [DateTime]::UtcNow.AddMinutes($TimeoutMinutes) } else { $null }

    try {
        while (-not $process.HasExited) {
            Write-NewLogContent -Path $stdoutLog -LineCount ([ref]$stdoutLineCount)
            Write-NewLogContent -Path $stderrLog -LineCount ([ref]$stderrLineCount)

            if ($deadline -and [DateTime]::UtcNow -ge $deadline) {
                try {
                    $process.Kill($true)
                } catch {
                }

                Write-NewLogContent -Path $stdoutLog -LineCount ([ref]$stdoutLineCount)
                Write-NewLogContent -Path $stderrLog -LineCount ([ref]$stderrLineCount)

                throw "Maven build for $FunctionLabel exceeded the timeout of $TimeoutMinutes minute(s). If the last output was 'Searching for Azure Functions entry points', the Azure Functions Maven plugin is likely stuck scanning dependencies."
            }

            Start-Sleep -Seconds 2
        }

        Write-NewLogContent -Path $stdoutLog -LineCount ([ref]$stdoutLineCount)
        Write-NewLogContent -Path $stderrLog -LineCount ([ref]$stderrLineCount)

        if ($process.ExitCode -ne 0) {
            throw "Maven build failed for $FunctionLabel with exit code $($process.ExitCode)."
        }
    } finally {
        Remove-Item $stdoutLog, $stderrLog -Force -ErrorAction SilentlyContinue
    }
}

# =============================================================================
# STEP 1: Select which function(s) to deploy
# =============================================================================
Write-Host "Which function app(s) do you want to deploy?" -ForegroundColor White
Write-Host "  1. mailbox-to-queue"
Write-Host "  2. queue-to-db"
Write-Host "  3. cu-queue-to-db"
Write-Host "  4. All"
Write-Host ""
Write-Host "  You can enter a single number or comma-separated list (e.g. 1,3)" -ForegroundColor DarkCyan
Write-Host ""

$validOptions = @('1','2','3','4')
do {
    $rawInput = (Read-Host "Enter selection(s)").Trim()
    $selections = $rawInput -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    $allValid = ($selections.Count -gt 0) -and ($selections | Where-Object { $_ -notin $validOptions }).Count -eq 0
    if (-not $allValid) {
        Write-Host "[ERROR] Please enter 1, 2, 3, 4, or a comma-separated list (e.g. 1,3)." -ForegroundColor Red
    }
} while (-not $allValid)

# Expand '4' (All) into individual selections, then deduplicate
if ($selections -contains '4') {
    $selections = @('1','2','3')
} else {
    $selections = $selections | Select-Object -Unique
}

# Build ordered list of targets: @{ Label, FunctionAppName, SourceDir }
$targets = [System.Collections.Generic.List[hashtable]]::new()
if ($selections -contains '1') {
    $targets.Add(@{
        Label           = "mailbox-to-queue"
        FunctionAppName = $FuncMailboxName
        SourceDir       = Join-Path $FunctionsRoot "mailbox-to-queue"
    })
}
if ($selections -contains '2') {
    $targets.Add(@{
        Label           = "queue-to-db"
        FunctionAppName = $FuncQueueDbName
        SourceDir       = Join-Path $FunctionsRoot "queue-to-db"
    })
}
if ($selections -contains '3') {
    $targets.Add(@{
        Label           = "cu-queue-to-db"
        FunctionAppName = $FuncCuQueueDbName
        SourceDir       = Join-Path $FunctionsRoot "cu-queue-to-db"
    })
}

# =============================================================================
# STEP 2: Confirm / override target names
# =============================================================================
Write-Host ""
Write-Host "[INFO] Derived deployment targets:" -ForegroundColor Cyan
foreach ($t in $targets) {
    Write-Host "  $($t.Label.PadRight(20)) -> $($t.FunctionAppName)"
}
Write-Host "  Resource Group: $ResourceGroupName"
Write-Host ""

if ($targets.Count -eq 1) {
    # Single target — allow per-app name override
    $confirm = Read-Host "Press [Enter] to accept Function App name '$($targets[0].FunctionAppName)', or type a new name to override"
    $confirm = $confirm.Trim()
    if ($confirm -ne '') {
        $targets[0].FunctionAppName = $confirm
        Write-Host "[INFO] Using overridden Function App name: $confirm" -ForegroundColor Cyan
    }
}

$confirmRg = Read-Host "Press [Enter] to accept Resource Group '$ResourceGroupName', or type a new name to override"
$confirmRg = $confirmRg.Trim()
if ($confirmRg -ne '') {
    $ResourceGroupName = $confirmRg
    Write-Host "[INFO] Using overridden Resource Group: $ResourceGroupName" -ForegroundColor Cyan
}

# Final confirmation
Write-Host ""
Write-Host "[INFO] ============================================================" -ForegroundColor Cyan
Write-Host "[INFO] About to deploy:"                                              -ForegroundColor Cyan
foreach ($t in $targets) {
    Write-Host "  $($t.Label.PadRight(20)) -> $($t.FunctionAppName)"             -ForegroundColor Cyan
}
Write-Host "  Resource Group: $ResourceGroupName"                                 -ForegroundColor Cyan
Write-Host "[INFO] ============================================================" -ForegroundColor Cyan
Write-Host ""

$go = Read-Host "Proceed with deployment? [Y/n]"
if ($go.Trim() -match '^[Nn]') {
    Write-Host "[INFO] Deployment cancelled." -ForegroundColor Yellow
    exit 0
}

# =============================================================================
# STEP 3+4: Build and deploy each target via SCM OneDeploy
# =============================================================================
$deploymentErrors = [System.Collections.Generic.List[string]]::new()

foreach ($target in $targets) {
    $FunctionLabel   = $target.Label
    $FunctionAppName = $target.FunctionAppName
    $SourceDir       = $target.SourceDir

    Write-Host ""
    Write-Host "[INFO] ---- Deploying: $FunctionLabel ----" -ForegroundColor White

    # Validate source
    if (-not (Test-Path $SourceDir)) {
        Write-Host "[ERROR] Source directory not found: $SourceDir" -ForegroundColor Red
        $deploymentErrors.Add($FunctionLabel)
        continue
    }
    if (-not (Test-Path (Join-Path $SourceDir "pom.xml"))) {
        Write-Host "[ERROR] pom.xml not found in: $SourceDir" -ForegroundColor Red
        $deploymentErrors.Add($FunctionLabel)
        continue
    }

    # Maven build
    Write-Host "[INFO] Building $FunctionLabel with Maven..." -ForegroundColor Cyan
    try {
        if ($MavenTimeoutMinutes -gt 0) {
            Write-Host "[INFO] Maven timeout for this build: $MavenTimeoutMinutes minute(s)." -ForegroundColor DarkCyan
        } else {
            Write-Host "[INFO] Maven timeout disabled for this build." -ForegroundColor DarkCyan
        }

        Invoke-MavenPackage -SourceDir $SourceDir -FunctionLabel $FunctionLabel -MavenPath $mvn.Source -TimeoutMinutes $MavenTimeoutMinutes
    } catch {
        Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
        $deploymentErrors.Add($FunctionLabel)
        continue
    }
    Write-Host "[SUCCESS] Maven build completed for $FunctionLabel" -ForegroundColor Green

    # Locate staging directory
    $stagingBase = Join-Path $SourceDir "target\azure-functions"
    $stagingDir  = Get-ChildItem $stagingBase -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $stagingDir) {
        Write-Host "[ERROR] Staging directory not found under $stagingBase" -ForegroundColor Red
        $deploymentErrors.Add($FunctionLabel)
        continue
    }
    Write-Host "[INFO] Staging directory: $($stagingDir.FullName)" -ForegroundColor Cyan

    # Package the staged output as a zip, then deploy via the SCM OneDeploy
    # API (/api/publish). On Flex Consumption, the /api/zipdeploy endpoint
    # returns 502; the OneDeploy endpoint triggers the full deployment pipeline
    # (validation, extraction, sync triggers) and reliably registers functions.
    $zipPath = Join-Path $env:TEMP "$FunctionAppName-deployment.zip"
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
    Compress-Archive -Path "$($stagingDir.FullName)\*" -DestinationPath $zipPath -Force
    Write-Host "[INFO] Created deployment package: $zipPath" -ForegroundColor Cyan

    try {
        Ensure-FunctionHostSettings -FunctionAppName $FunctionAppName -ResourceGroupName $ResourceGroupName -StorageAccountName $StorageAccountName
    } catch {
        Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
        $deploymentErrors.Add($FunctionLabel)
        continue
    }

    # Obtain an ARM token for authenticating to the SCM site
    $armToken = (az account get-access-token --resource "https://management.azure.com/" `
        --query accessToken -o tsv 2>$null).Trim()
    if (-not $armToken) {
        Write-Host "[ERROR] Failed to obtain ARM access token." -ForegroundColor Red
        $deploymentErrors.Add($FunctionLabel)
        continue
    }

    # Deploy via SCM OneDeploy API — this triggers the Flex Consumption
    # deployment pipeline (BackgroundDeployerService) which processes the zip,
    # validates it, and syncs triggers so functions are discoverable.
    $scmHost = "$FunctionAppName.scm.azurewebsites.net"
    Write-Host "[INFO] Deploying package to $FunctionAppName via OneDeploy (SCM)..." -ForegroundColor Cyan
    try {
        $deployResp = Invoke-WebRequest `
            -Uri "https://$scmHost/api/publish?type=zip&async=true" `
            -Method POST `
            -Headers @{ Authorization = "Bearer $armToken" } `
            -InFile $zipPath `
            -ContentType "application/zip" `
            -TimeoutSec 120 `
            -ErrorAction Stop
        $deployId = ($deployResp.Content | ConvertFrom-Json)
        Write-Host "[INFO] Deployment accepted (id: $deployId). Polling for completion..." -ForegroundColor Cyan
    } catch {
        Write-Host "[ERROR] Failed to initiate deployment for $FunctionLabel." -ForegroundColor Red
        Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
        $deploymentErrors.Add($FunctionLabel)
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
        continue
    }
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue

    # Poll deployment status until it completes (status 4 = Success, 3 = Failed)
    $maxPollAttempts = 60   # up to 10 minutes (60 x 10s)
    $deployOk = $false
    for ($poll = 0; $poll -lt $maxPollAttempts; $poll++) {
        Start-Sleep -Seconds 10
        try {
            $pollResp = Invoke-RestMethod `
                -Uri "https://$scmHost/api/deployments/$deployId" `
                -Headers @{ Authorization = "Bearer $armToken" } `
                -TimeoutSec 30 `
                -ErrorAction Stop
            $deployStatus   = $pollResp.status
            $deployComplete = $pollResp.complete
            if ($deployComplete -eq $true) {
                if ($deployStatus -eq 4) {
                    $deployOk = $true
                }
                break
            }
        } catch {
            # Transient poll error — keep trying
        }
    }

    if (-not $deployOk) {
        Write-Host "[ERROR] Deployment did not complete successfully for $FunctionLabel (status: $deployStatus)." -ForegroundColor Red
        $deploymentErrors.Add($FunctionLabel)
        continue
    }
    Write-Host "[SUCCESS] Deployment completed for $FunctionLabel" -ForegroundColor Green

    # Verify the function was discovered by the host
    Write-Host "[INFO] Verifying function discovery..." -ForegroundColor Cyan
    $funcList = az functionapp function list `
        --name $FunctionAppName `
        --resource-group $ResourceGroupName `
        --query "[].name" -o tsv 2>$null
    if ($funcList) {
        Write-Host "[SUCCESS] Discovered functions: $funcList" -ForegroundColor Green
    } else {
        Write-Host "[WARNING] No functions discovered yet. They may appear after the first cold start." -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "[INFO] To view logs use Application Insights in the portal," -ForegroundColor Yellow
    Write-Host "       or: az monitor app-insights query ..." -ForegroundColor Yellow
}

# =============================================================================
# SUMMARY
# =============================================================================
Write-Host ""
if ($deploymentErrors.Count -gt 0) {
    Write-Host "[FAILED] ==========================================" -ForegroundColor Red
    Write-Host "[FAILED] Deployment completed with errors:"          -ForegroundColor Red
    foreach ($err in $deploymentErrors) {
        Write-Host "  - $err" -ForegroundColor Red
    }
    Write-Host "[FAILED] ==========================================" -ForegroundColor Red
    exit 1
} else {
    Write-Host "[SUCCESS] ==========================================" -ForegroundColor Green
    Write-Host "[SUCCESS] All deployments complete!"                  -ForegroundColor Green
    Write-Host "[SUCCESS] ==========================================" -ForegroundColor Green
    foreach ($t in $targets) {
        Write-Host "  $($t.Label.PadRight(20)) -> $($t.FunctionAppName)"
    }
    Write-Host "  Resource Group   : $ResourceGroupName"
    Write-Host ""
    Write-Host "[INFO] Flex Consumption has no Kudu — use Application Insights for logs:" -ForegroundColor Cyan
    foreach ($t in $targets) {
        Write-Host "  Portal > $($t.FunctionAppName) > Application Insights > Live Metrics"
    }
}


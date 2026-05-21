#Requires -Version 5.1
<#
.SYNOPSIS
    Builds and deploys Azure Function apps and the Spring Boot web app to Azure.
.DESCRIPTION
    Prompts the user to select which workloads to deploy, derives the target
    application names from the same naming convention used by
    deploy-infrastructure.ps1, confirms with the user, then builds the JARs
    with Maven and deploys function apps via the SCM OneDeploy API and the
    Spring Boot web app via Azure App Service JAR deployment.
.PARAMETER Suffix
    Required. The same suffix used when running deploy-infrastructure.ps1.
.USAGE
    .\9.deploy-code.ps1 -Suffix 999
#>
param(
    [Parameter(Mandatory=$true, HelpMessage="Suffix used during infrastructure deployment (e.g. 999)")]
    [ValidateNotNullOrEmpty()]
    [string]$Suffix,

    [Parameter(HelpMessage="Maximum time to allow each Maven package run before failing. Use 0 to disable the timeout.")]
    [ValidateRange(0, 1440)]
    [int]$MavenTimeoutMinutes = 15,

    [Parameter(HelpMessage="Maximum OneDeploy retry attempts for function apps when conflicts occur (status 6).")]
    [ValidateRange(1, 10)]
    [int]$RetryCount = 3,

    [Parameter(HelpMessage="Delay in seconds between deployment status polls and retry waits.")]
    [ValidateRange(5, 300)]
    [int]$RetryDelaySeconds = 10,

    [Parameter(HelpMessage="Maximum time to allow web app JAR deployment before failing.")]
    [ValidateRange(1, 120)]
    [int]$WebAppDeployTimeoutMinutes = 20
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
$WebAppName        = if ($env:WEB_APP_NAME)             { $env:WEB_APP_NAME }               else { "app-$ProjectName-$Environment-$Suffix" }

$ScriptRoot      = $PSScriptRoot
$RepoRoot        = Split-Path $ScriptRoot -Parent
$FunctionsRoot   = Join-Path $RepoRoot "extract\functions"
$UiRoot          = Join-Path $RepoRoot "insight\ui"

# =============================================================================
# PREREQUISITES
# =============================================================================
Write-Host ""
Write-Host "[INFO] ============================================================" -ForegroundColor Cyan
Write-Host "[INFO] Application Code Deployment"                                   -ForegroundColor Cyan
Write-Host "[INFO] Project     : $ProjectName"                                    -ForegroundColor Cyan
Write-Host "[INFO] Environment : $Environment"                                    -ForegroundColor Cyan
Write-Host "[INFO] Suffix      : $Suffix"                                         -ForegroundColor Cyan
Write-Host "[INFO] Retry Count : $RetryCount"                                     -ForegroundColor Cyan
Write-Host "[INFO] Retry Delay : $RetryDelaySeconds second(s)"                    -ForegroundColor Cyan
Write-Host "[INFO] WebApp Deploy Timeout : $WebAppDeployTimeoutMinutes minute(s)" -ForegroundColor Cyan
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
        [Parameter(Mandatory=$true)][int]$TimeoutMinutes,
        [Parameter()][switch]$SkipClean
    )

    $stdoutLog = Join-Path $env:TEMP ("$FunctionLabel-maven-stdout.log")
    $stderrLog = Join-Path $env:TEMP ("$FunctionLabel-maven-stderr.log")
    Remove-Item $stdoutLog, $stderrLog -Force -ErrorAction SilentlyContinue

    $mavenArgs = @('-DskipTests', '--no-transfer-progress')
    if ($SkipClean) {
        $mavenArgs = @('package') + $mavenArgs
    } else {
        $mavenArgs = @('clean', 'package') + $mavenArgs
    }

    $process = Start-Process `
        -FilePath $MavenPath `
        -ArgumentList $mavenArgs `
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

function Invoke-AzWebAppDeploy {
    param(
        [Parameter(Mandatory=$true)][string]$WebAppName,
        [Parameter(Mandatory=$true)][string]$ResourceGroupName,
        [Parameter(Mandatory=$true)][string]$JarPath,
        [Parameter(Mandatory=$true)][int]$TimeoutMinutes
    )

    $stdoutLog = Join-Path $env:TEMP ("$WebAppName-webapp-deploy-stdout.log")
    $stderrLog = Join-Path $env:TEMP ("$WebAppName-webapp-deploy-stderr.log")
    Remove-Item $stdoutLog, $stderrLog -Force -ErrorAction SilentlyContinue

    # --async: CLI returns as soon as the file is uploaded; Azure recycles the
    # container on its own. This avoids the CLI hanging on the warmup probe
    # ("Starting the site..." loop) for Spring Boot apps that take > 30s to boot.
    $deployArgs = @(
        'webapp', 'deploy',
        '--name', $WebAppName,
        '--resource-group', $ResourceGroupName,
        "--src-path=`"$JarPath`"",
        '--type', 'jar',
        '--clean', 'true',
        '--async', 'true'
    )

    $process = Start-Process `
        -FilePath 'az' `
        -ArgumentList $deployArgs `
        -NoNewWindow `
        -PassThru `
        -RedirectStandardOutput $stdoutLog `
        -RedirectStandardError $stderrLog

    $stdoutLineCount = 0
    $stderrLineCount = 0
    $start = [DateTime]::UtcNow
    $deadline = $start.AddMinutes($TimeoutMinutes)
    $nextHeartbeat = $start.AddSeconds(15)

    try {
        while (-not $process.HasExited) {
            Write-NewLogContent -Path $stdoutLog -LineCount ([ref]$stdoutLineCount)
            Write-NewLogContent -Path $stderrLog -LineCount ([ref]$stderrLineCount)

            $now = [DateTime]::UtcNow
            if ($now -ge $nextHeartbeat) {
                $elapsedSeconds = [int]($now - $start).TotalSeconds
                Write-Host "[INFO] Waiting for web app deployment... elapsed ${elapsedSeconds}s" -ForegroundColor DarkCyan
                $nextHeartbeat = $now.AddSeconds(15)
            }

            if ($now -ge $deadline) {
                try { $process.Kill($true) } catch { }
                Write-NewLogContent -Path $stdoutLog -LineCount ([ref]$stdoutLineCount)
                Write-NewLogContent -Path $stderrLog -LineCount ([ref]$stderrLineCount)
                throw "Web app deployment exceeded timeout of $TimeoutMinutes minute(s)."
            }

            Start-Sleep -Seconds 2
        }

        Write-NewLogContent -Path $stdoutLog -LineCount ([ref]$stdoutLineCount)
        Write-NewLogContent -Path $stderrLog -LineCount ([ref]$stderrLineCount)

        if ($process.ExitCode -ne 0) {
            throw "Web app deployment command failed with exit code $($process.ExitCode)."
        }
    } finally {
        Remove-Item $stdoutLog, $stderrLog -Force -ErrorAction SilentlyContinue
    }
}

function Wait-ForScmDeploymentsIdle {
    param(
        [Parameter(Mandatory=$true)][string]$ScmHost,
        [Parameter(Mandatory=$true)][string]$ArmToken,
        [Parameter(Mandatory=$true)][string]$FunctionLabel,
        [Parameter()][int]$MaxPollAttempts = 60,
        [Parameter()][int]$PollIntervalSeconds = 10
    )

    for ($attempt = 1; $attempt -le $MaxPollAttempts; $attempt++) {
        try {
            $deployments = Invoke-RestMethod `
                -Uri "https://$ScmHost/api/deployments" `
                -Headers @{ Authorization = "Bearer $ArmToken" } `
                -TimeoutSec 30 `
                -ErrorAction Stop

            $activeDeployments = @($deployments | Where-Object { $_.complete -ne $true })
            if ($activeDeployments.Count -eq 0) {
                return $true
            }

            $activeIds = ($activeDeployments | ForEach-Object { $_.id }) -join ', '
            Write-Host "[INFO] Waiting for active deployment(s) on $FunctionLabel to finish: $activeIds" -ForegroundColor DarkCyan
        } catch {
            Write-Host "[WARNING] Could not query current SCM deployments for $FunctionLabel; retrying..." -ForegroundColor Yellow
        }

        Start-Sleep -Seconds $PollIntervalSeconds
    }

    return $false
}

function Get-ArtifactSha256 {
    param(
        [Parameter(Mandatory=$true)][string]$Path
    )

    if (-not (Test-Path $Path)) {
        return ""
    }

    try {
        return (Get-FileHash -Path $Path -Algorithm SHA256 -ErrorAction Stop).Hash
    } catch {
        return ""
    }
}

# =============================================================================
# STEP 1: Select which workload(s) to deploy
# =============================================================================
Write-Host "Which workload(s) do you want to deploy?" -ForegroundColor White
Write-Host "  1. mailbox-to-queue"
Write-Host "  2. queue-to-db"
Write-Host "  3. cu-queue-to-db"
Write-Host "  4. insight-ui web app"
Write-Host "  5. All"
Write-Host ""
Write-Host "  You can enter a single number or comma-separated list (e.g. 1,3)" -ForegroundColor DarkCyan
Write-Host ""

$validOptions = @('1','2','3','4','5')
do {
    $rawInput = (Read-Host "Enter selection(s)").Trim()
    $selections = $rawInput -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    $allValid = ($selections.Count -gt 0) -and ($selections | Where-Object { $_ -notin $validOptions }).Count -eq 0
    if (-not $allValid) {
        Write-Host "[ERROR] Please enter 1, 2, 3, 4, 5, or a comma-separated list (e.g. 1,4)." -ForegroundColor Red
    }
} while (-not $allValid)

# Expand '5' (All) into individual selections, then deduplicate
if ($selections -contains '5') {
    $selections = @('1','2','3','4')
} else {
    $selections = $selections | Select-Object -Unique
}

# Build ordered list of targets: @{ Label, AppName, SourceDir, Kind }
$targets = [System.Collections.Generic.List[hashtable]]::new()
if ($selections -contains '1') {
    $targets.Add(@{
        Label           = "mailbox-to-queue"
        AppName         = $FuncMailboxName
        SourceDir       = Join-Path $FunctionsRoot "mailbox-to-queue"
        Kind            = "function"
    })
}
if ($selections -contains '2') {
    $targets.Add(@{
        Label           = "queue-to-db"
        AppName         = $FuncQueueDbName
        SourceDir       = Join-Path $FunctionsRoot "queue-to-db"
        Kind            = "function"
    })
}
if ($selections -contains '3') {
    $targets.Add(@{
        Label           = "cu-queue-to-db"
        AppName         = $FuncCuQueueDbName
        SourceDir       = Join-Path $FunctionsRoot "cu-queue-to-db"
        Kind            = "function"
    })
}
if ($selections -contains '4') {
    $targets.Add(@{
        Label           = "insight-ui"
        AppName         = $WebAppName
        SourceDir       = $UiRoot
        Kind            = "webapp"
    })
}

# =============================================================================
# STEP 2: Confirm / override target names
# =============================================================================
Write-Host ""
Write-Host "[INFO] Derived deployment targets:" -ForegroundColor Cyan
foreach ($t in $targets) {
    Write-Host "  $($t.Label.PadRight(20)) -> $($t.AppName) [$($t.Kind)]"
}
Write-Host "  Resource Group: $ResourceGroupName"
Write-Host ""

if ($targets.Count -eq 1) {
    # Single target — allow per-app name override
    $confirm = Read-Host "Press [Enter] to accept app name '$($targets[0].AppName)', or type a new name to override"
    $confirm = $confirm.Trim()
    if ($confirm -ne '') {
        $targets[0].AppName = $confirm
        Write-Host "[INFO] Using overridden app name: $confirm" -ForegroundColor Cyan
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
    Write-Host "  $($t.Label.PadRight(20)) -> $($t.AppName) [$($t.Kind)]"        -ForegroundColor Cyan
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
    $TargetAppName   = $target.AppName
    $SourceDir       = $target.SourceDir
    $TargetKind      = $target.Kind

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

        Invoke-MavenPackage -SourceDir $SourceDir -FunctionLabel $FunctionLabel -MavenPath $mvn.Source -TimeoutMinutes $MavenTimeoutMinutes -SkipClean:($TargetKind -eq 'webapp')
    } catch {
        Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
        $deploymentErrors.Add($FunctionLabel)
        continue
    }
    Write-Host "[SUCCESS] Maven build completed for $FunctionLabel" -ForegroundColor Green

    if ($TargetKind -eq 'webapp') {
        $jarFile = Get-ChildItem (Join-Path $SourceDir 'target') -Filter '*.jar' -File |
            Where-Object { $_.Name -notlike '*.original' } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if (-not $jarFile) {
            Write-Host "[ERROR] Spring Boot JAR not found under $(Join-Path $SourceDir 'target')" -ForegroundColor Red
            $deploymentErrors.Add($FunctionLabel)
            continue
        }

        $jarHash = Get-ArtifactSha256 -Path $jarFile.FullName
        if ($jarHash) {
            Write-Host "[INFO] Deploying artifact: $($jarFile.Name) (SHA256: $jarHash)" -ForegroundColor DarkCyan
        }

        Write-Host "[INFO] Deploying web app JAR to $TargetAppName..." -ForegroundColor Cyan
        try {
            Invoke-AzWebAppDeploy `
                -WebAppName $TargetAppName `
                -ResourceGroupName $ResourceGroupName `
                -JarPath $jarFile.FullName `
                -TimeoutMinutes $WebAppDeployTimeoutMinutes
        } catch {
            Write-Host "[ERROR] Web app deployment failed for $FunctionLabel" -ForegroundColor Red
            Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
            $deploymentErrors.Add($FunctionLabel)
            continue
        }

        Write-Host "[SUCCESS] JAR deployed for $FunctionLabel — waiting for site to come up..." -ForegroundColor Green
        $defaultHostName = az webapp show --name $TargetAppName --resource-group $ResourceGroupName --query defaultHostName -o tsv 2>$null
        if ($defaultHostName) {
            $appUrl = "https://$defaultHostName"
            Write-Host "[INFO] Web app URL: $appUrl" -ForegroundColor Cyan

            # Poll the app URL until it responds HTTP 2xx/3xx or we time out.
            $pollStart    = [DateTime]::UtcNow
            $pollDeadline = $pollStart.AddMinutes($WebAppDeployTimeoutMinutes)
            $pollInterval = 15
            $appReady = $false
            while ([DateTime]::UtcNow -lt $pollDeadline) {
                try {
                    $resp = Invoke-WebRequest -Uri $appUrl -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
                    if ($resp.StatusCode -lt 500) {
                        Write-Host "[SUCCESS] App is responding (HTTP $($resp.StatusCode))." -ForegroundColor Green
                        $appReady = $true
                        break
                    }
                } catch {
                    # Non-2xx or connection refused — still starting
                }
                $elapsed = [int]([DateTime]::UtcNow - $pollStart).TotalSeconds
                Write-Host "[INFO] App not yet ready (${elapsed}s elapsed), retrying in ${pollInterval}s..." -ForegroundColor DarkCyan
                Start-Sleep -Seconds $pollInterval
            }
            if (-not $appReady) {
                Write-Host "[WARNING] App did not respond within $WebAppDeployTimeoutMinutes min. Check Azure portal for status." -ForegroundColor Yellow
            }
        }
        continue
    }

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
    $zipPath = Join-Path $env:TEMP "$TargetAppName-deployment.zip"
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
    Compress-Archive -Path "$($stagingDir.FullName)\*" -DestinationPath $zipPath -Force
    Write-Host "[INFO] Created deployment package: $zipPath" -ForegroundColor Cyan

    $zipHash = Get-ArtifactSha256 -Path $zipPath
    if ($zipHash) {
        Write-Host "[INFO] Deployment package SHA256: $zipHash" -ForegroundColor DarkCyan
    }

    try {
        Ensure-FunctionHostSettings -FunctionAppName $TargetAppName -ResourceGroupName $ResourceGroupName -StorageAccountName $StorageAccountName
    } catch {
        Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
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
    $scmHost = "$TargetAppName.scm.azurewebsites.net"

    $isScmIdle = Wait-ForScmDeploymentsIdle -ScmHost $scmHost -ArmToken $armToken -FunctionLabel $FunctionLabel
    if (-not $isScmIdle) {
        Write-Host "[ERROR] Timed out waiting for existing deployment(s) to finish on $FunctionLabel before starting a new deploy." -ForegroundColor Red
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
        $deploymentErrors.Add($FunctionLabel)
        continue
    }

    $maxDeployAttempts = $RetryCount
    $deployOk = $false
    $deployStatus = "unknown"
    $recordedFunctionError = $false

    for ($deployAttempt = 1; $deployAttempt -le $maxDeployAttempts; $deployAttempt++) {
        Write-Host "[INFO] Deploying package to $TargetAppName via OneDeploy (SCM) (attempt $deployAttempt/$maxDeployAttempts)..." -ForegroundColor Cyan
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
            $recordedFunctionError = $true
            break
        }

        # Poll deployment status until it completes (status 4 = Success, 3 = Failed, 6 = Conflict)
        $maxPollAttempts = 60   # up to 10 minutes (60 x 10s)
        for ($poll = 0; $poll -lt $maxPollAttempts; $poll++) {
            Start-Sleep -Seconds $RetryDelaySeconds
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

        if ($deployOk) {
            break
        }

        if ($deployStatus -eq 6 -and $deployAttempt -lt $maxDeployAttempts) {
            Write-Host "[WARNING] Deployment conflict detected for $FunctionLabel (status 6). Waiting for SCM to become idle before retry..." -ForegroundColor Yellow
            $isScmIdle = Wait-ForScmDeploymentsIdle -ScmHost $scmHost -ArmToken $armToken -FunctionLabel $FunctionLabel -PollIntervalSeconds $RetryDelaySeconds
            if (-not $isScmIdle) {
                Write-Host "[ERROR] Timed out waiting for SCM to become idle for $FunctionLabel before retry." -ForegroundColor Red
                break
            }
            continue
        }

        break
    }

    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue

    if (-not $deployOk) {
        Write-Host "[ERROR] Deployment did not complete successfully for $FunctionLabel (status: $deployStatus)." -ForegroundColor Red
        if (-not $recordedFunctionError) {
            $deploymentErrors.Add($FunctionLabel)
        }
        continue
    }
    Write-Host "[SUCCESS] Deployment completed for $FunctionLabel" -ForegroundColor Green

    # Verify the function was discovered by the host
    Write-Host "[INFO] Verifying function discovery..." -ForegroundColor Cyan
    $funcList = az functionapp function list `
        --name $TargetAppName `
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
        Write-Host "  $($t.Label.PadRight(20)) -> $($t.AppName) [$($t.Kind)]"
    }
    Write-Host "  Resource Group   : $ResourceGroupName"
    Write-Host ""
    Write-Host "[INFO] Flex Consumption has no Kudu — use Application Insights for function logs:" -ForegroundColor Cyan
    foreach ($t in $targets) {
        if ($t.Kind -eq 'function') {
            Write-Host "  Portal > $($t.AppName) > Application Insights > Live Metrics"
        }
    }
}


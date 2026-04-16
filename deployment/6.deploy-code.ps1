#Requires -Version 5.1
<#
.SYNOPSIS
    Builds and deploys a function app to Azure.
.DESCRIPTION
    Prompts the user to select which function to deploy (mailbox-to-queue or
    queue-to-db), derives the target Function App name from the same naming
    convention used by deploy-infrastructure.ps1, confirms with the user, then
    builds the JAR with Maven and deploys it using the Azure CLI.
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
Write-Host "Which function app do you want to deploy?" -ForegroundColor White
Write-Host "  1. mailbox-to-queue"
Write-Host "  2. queue-to-db"
Write-Host "  3. All (both)"
Write-Host ""

do {
    $choice = Read-Host "Enter 1, 2, or 3"
    $choice = $choice.Trim()
    if ($choice -notin @('1','2','3')) {
        Write-Host "[ERROR] Please enter 1, 2, or 3." -ForegroundColor Red
    }
} while ($choice -notin @('1','2','3'))

# Build ordered list of targets: @{ Label, FunctionAppName, SourceDir }
$targets = [System.Collections.Generic.List[hashtable]]::new()
if ($choice -in @('1','3')) {
    $targets.Add(@{
        Label           = "mailbox-to-queue"
        FunctionAppName = $FuncMailboxName
        SourceDir       = Join-Path $FunctionsRoot "mailbox-to-queue"
    })
}
if ($choice -in @('2','3')) {
    $targets.Add(@{
        Label           = "queue-to-db"
        FunctionAppName = $FuncQueueDbName
        SourceDir       = Join-Path $FunctionsRoot "queue-to-db"
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

if ($choice -ne '3') {
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
# STEP 3: Shared deployment prerequisites
# =============================================================================
Write-Host "[INFO] Using storage account '$StorageAccountName' for Flex deployment artifacts." -ForegroundColor Cyan

# =============================================================================
# STEP 4+5: Build, upload deployment package, and deploy each target
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

    # Package the staged output as a zip, then upload that zip into a dedicated
    # per-app container. Flex blobContainer deployment reads the most recent blob
    # from the configured container as the deployment package.
    $containerName = ("deploy-" + $FunctionAppName.ToLowerInvariant())
    if ($containerName.Length -gt 63) {
        $containerName = $containerName.Substring(0, 63)
    }
    $containerName = $containerName.Trim('-')

    $blobName = "$FunctionAppName-deployment.zip"
    $zipPath  = Join-Path $env:TEMP $blobName
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
    Compress-Archive -Path "$($stagingDir.FullName)\*" -DestinationPath $zipPath -Force
    Write-Host "[INFO] Created deployment package: $zipPath" -ForegroundColor Cyan

    Write-Host "[INFO] Ensuring deployment container '$containerName' exists..." -ForegroundColor Cyan
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    az storage container create --name $containerName --account-name $StorageAccountName `
        --auth-mode login --output none 2>$null
    $ErrorActionPreference = $prevEAP

    Write-Host "[INFO] Clearing existing contents from '$containerName'..." -ForegroundColor Cyan
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    az storage blob delete-batch `
        --account-name $StorageAccountName `
        --source $containerName `
        --auth-mode login `
        --pattern "*" `
        --output none 2>&1 | Out-Null
    $ErrorActionPreference = $prevEAP

    # Upload
    # NOTE: The storage account firewall is managed by 5.operation-dev.ps1, which
    # permanently adds your current public IP as an allowed rule. Run that script
    # first if you get network-blocked errors here.
    Write-Host "[INFO] Uploading deployment package to container '$containerName'..." -ForegroundColor Cyan
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    az storage blob upload `
        --account-name $StorageAccountName `
        --container-name $containerName `
        --name $blobName `
        --file $zipPath `
        --auth-mode login `
        --overwrite `
        --output none 2>&1
    $uploadExitCode = $LASTEXITCODE
    $ErrorActionPreference = $prevEAP
    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue

    if ($uploadExitCode -ne 0) {
        Write-Host "[ERROR] Failed to upload deployment package for $FunctionLabel." -ForegroundColor Red
        Write-Host "        Your public IP may not be in the storage firewall allowlist." -ForegroundColor Yellow
        Write-Host "        Re-run 5.operation-dev.ps1 -Suffix $Suffix to refresh the firewall rule." -ForegroundColor Yellow
        $deploymentErrors.Add($FunctionLabel)
        continue
    }
    Write-Host "[SUCCESS] Deployment package uploaded" -ForegroundColor Green

    # Configure deployment + restart
    # For Flex Consumption, functionAppConfig.deployment.storage.value must be the
    # CONTAINER URL (not a blob URL). The ARM schema says "URL for the storage container".
    # The host reads the most recently modified blob from that container on startup.
    $containerUrl = "https://$StorageAccountName.blob.core.windows.net/$containerName"
    Write-Host "[INFO] Configuring deployment container on $FunctionAppName..." -ForegroundColor Cyan

    $funcId = (az functionapp show `
        --name $FunctionAppName `
        --resource-group $ResourceGroupName `
        --query id -o tsv 2>$null)
    $funcId = $funcId.Trim()   # strip any \r\n from Windows az CLI tsv output
    if (-not $funcId) {
        Write-Host "[ERROR] Function app '$FunctionAppName' not found." -ForegroundColor Red
        $deploymentErrors.Add($FunctionLabel)
        continue
    }

    try {
        Ensure-FunctionHostSettings -FunctionAppName $FunctionAppName -ResourceGroupName $ResourceGroupName -StorageAccountName $StorageAccountName
    } catch {
        Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
        $deploymentErrors.Add($FunctionLabel)
        continue
    }

    # Use Invoke-RestMethod instead of 'az rest' to avoid Windows az CLI URL
    # construction bugs where \r in $funcId (from tsv CRLF output) corrupts
    # the URL hostname inside Python's urllib3.
    $armToken = (az account get-access-token --resource "https://management.azure.com/" `
        --query accessToken -o tsv 2>$null).Trim()
    if (-not $armToken) {
        Write-Host "[ERROR] Failed to obtain ARM access token." -ForegroundColor Red
        $deploymentErrors.Add($FunctionLabel)
        continue
    }
    $armUrl     = "https://management.azure.com" + $funcId + "?api-version=2023-12-01"
    $armHeaders = @{
        "Authorization" = "Bearer $armToken"
        "Content-Type"  = "application/json"
    }

    # ARM rejects a PATCH that sends only the deployment.storage sub-tree because
    # it validates the complete functionAppConfig object (runtime, scaleAndConcurrency,
    # deployment must all be present and consistent).
    # Strategy: GET the current config, update deployment.storage in-place, re-PATCH
    # with the full functionAppConfig so all other fields remain unchanged.
    #
    # IMPORTANT: functionAppConfig.deployment.storage.value must be the CONTAINER URL.
    # The Flex Consumption host reads the most recent blob in that container as
    # the deployment package, so each app must have its own dedicated container.
    Write-Host "[INFO] Reading current function app config..." -ForegroundColor Cyan
    try {
        $funcAppConfig = Invoke-RestMethod -Method Get -Uri $armUrl -Headers $armHeaders -ErrorAction Stop
    } catch {
        Write-Host "[ERROR] Failed to read function app config for $FunctionAppName." -ForegroundColor Red
        Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
        $deploymentErrors.Add($FunctionLabel)
        continue
    }

    $currentValue = $funcAppConfig.properties.functionAppConfig.deployment.storage.value
    Write-Host "[INFO] Current deployment.storage.value : $(if ($currentValue) { $currentValue } else { '(not set)' })" -ForegroundColor Cyan

    # Update only the deployment.storage node; leave everything else untouched
    $funcAppConfig.properties.functionAppConfig.deployment.storage = [pscustomobject]@{
        type           = "blobContainer"
        value          = $containerUrl        # container URL, not a specific blob URL
        authentication = [pscustomobject]@{ type = "SystemAssignedIdentity" }
    }

    $patchBody = @{
        properties = @{
            functionAppConfig = $funcAppConfig.properties.functionAppConfig
        }
    } | ConvertTo-Json -Depth 20 -Compress

    try {
        $patchResp = Invoke-RestMethod -Method Patch -Uri $armUrl -Headers $armHeaders -Body $patchBody `
            -ResponseHeadersVariable patchRespHeaders -ErrorAction Stop
        $patchOk = $true
    } catch {
        $patchOk     = $false
        $patchErrMsg = $_.Exception.Message
        if ($_.Exception.Response) {
            try {
                $reader      = [System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream())
                $patchErrMsg = $reader.ReadToEnd()
                $reader.Dispose()
            } catch {}
        }
    }

    if (-not $patchOk) {
        Write-Host "[ERROR] Failed to update deployment config for $FunctionAppName." -ForegroundColor Red
        Write-Host "  $patchErrMsg" -ForegroundColor Red
        $deploymentErrors.Add($FunctionLabel)
        continue
    }

    # ARM PATCH on functionAppConfig is asynchronous — poll until Succeeded
    $asyncUrl = if ($patchRespHeaders -and $patchRespHeaders['Azure-AsyncOperation']) {
        $patchRespHeaders['Azure-AsyncOperation'] | Select-Object -First 1
    } elseif ($patchRespHeaders -and $patchRespHeaders['Location']) {
        $patchRespHeaders['Location'] | Select-Object -First 1
    } else { $null }

    if ($asyncUrl) {
        Write-Host "[INFO] ARM PATCH is async, polling for completion..." -ForegroundColor Cyan
        $maxWait = 120; $waited = 0; $pollInterval = 5
        do {
            Start-Sleep -Seconds $pollInterval
            $waited += $pollInterval
            try {
                $asyncStatus = Invoke-RestMethod -Method Get -Uri $asyncUrl -Headers $armHeaders -ErrorAction Stop
                $opState = if ($asyncStatus.status) { $asyncStatus.status } else { $asyncStatus.properties.provisioningState }
            } catch { $opState = "Unknown" }
        } while ($opState -notin @('Succeeded','Failed','Canceled') -and $waited -lt $maxWait)

        if ($opState -ne 'Succeeded') {
            Write-Host "[ERROR] ARM async PATCH did not succeed (state: $opState) after ${waited}s." -ForegroundColor Red
            $deploymentErrors.Add($FunctionLabel)
            continue
        }
        Write-Host "[INFO] ARM PATCH completed (state: $opState)" -ForegroundColor Cyan
    }

    # Verify the change stuck
    try {
        $verifyResp  = Invoke-RestMethod -Method Get -Uri $armUrl -Headers $armHeaders -ErrorAction Stop
        $appliedVal  = $verifyResp.properties.functionAppConfig.deployment.storage.value
        $appliedAuth = $verifyResp.properties.functionAppConfig.deployment.storage.authentication.type
        Write-Host "[INFO] Verified deployment.storage.value = $appliedVal  auth = $appliedAuth" -ForegroundColor Cyan
        if ($appliedVal -ne $containerUrl) {
            Write-Host "[WARNING] Value mismatch — expected '$containerUrl', got '$appliedVal'" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "[WARNING] Could not verify PATCH result: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    Write-Host "[SUCCESS] Deployment container configured: $containerUrl" -ForegroundColor Green

    # Restart so the host picks up the newly uploaded blob from the container
    Write-Host "[INFO] Restarting $FunctionAppName to load new package..." -ForegroundColor Cyan
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    az functionapp restart `
        --name $FunctionAppName `
        --resource-group $ResourceGroupName `
        --output none 2>&1 | Out-Null
    $ErrorActionPreference = $prevEAP
    Write-Host "[SUCCESS] $FunctionAppName restarted" -ForegroundColor Green
    Write-Host ""
    Write-Host "[INFO] NOTE: Flex Consumption has no Kudu endpoint — 'az functionapp logs tail'" -ForegroundColor Yellow
    Write-Host "       does NOT work. To view logs use Application Insights in the portal," -ForegroundColor Yellow
    Write-Host "       or: az monitor app-insights query ..." -ForegroundColor Yellow
    Write-Host "[INFO] Functions in the portal appear ~2-3 min after a cold start." -ForegroundColor Cyan
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
    Write-Host "  Deployment storage account: $StorageAccountName"
    Write-Host ""
    Write-Host "[INFO] Flex Consumption has no Kudu — use Application Insights for logs:" -ForegroundColor Cyan
    foreach ($t in $targets) {
        Write-Host "  Portal > $($t.FunctionAppName) > Application Insights > Live Metrics"
    }
}


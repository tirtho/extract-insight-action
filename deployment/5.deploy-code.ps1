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
.PARAMETER Environment
    Optional. Environment name (default: dev).
.PARAMETER Suffix
    Optional. The same suffix used when running deploy-infrastructure.ps1.
.USAGE
    .\5.deploy-code.ps1 -Suffix 999
    .\5.deploy-code.ps1 -Environment dev -Suffix 999
#>
param(
    [Parameter(HelpMessage="Environment (default: dev, example: dev)")]
    [string]$Environment,

    [Parameter(HelpMessage="Suffix used during infrastructure deployment (default: 1, example: 1)")]
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

# =============================================================================
# CONFIGURATION  (mirrors deploy-infrastructure.ps1 naming conventions)
# =============================================================================
$ResourceGroupName = "rg-$ProjectName-$Environment-$Suffix"
$FuncMailboxName   = "func-mailbox-$ProjectName-$Environment-$Suffix"
$FuncQueueDbName   = "func-queuedb-$ProjectName-$Environment-$Suffix"
$FuncCuQueueDbName = "func-cuqueuedb-$ProjectName-$Environment-$Suffix"
$FuncAgentServiceName = "func-agentservice-$ProjectName-$Environment-$Suffix"
$ProjClean         = $ProjectName -replace '-',''
$StorageClean      = ($Suffix.ToLowerInvariant()) -replace '[^a-z0-9]',''
$StorageAccountName = "st$ProjClean$Environment$StorageClean"
$WebAppName        = "app-$ProjectName-$Environment-$Suffix"

$ScriptRoot      = $PSScriptRoot
$RepoRoot        = Split-Path $ScriptRoot -Parent
$FunctionsRoot   = Join-Path $RepoRoot "extract\functions"
$UiRoot          = Join-Path $RepoRoot "insight\ui"
$JavaCoreRoot      = Join-Path $RepoRoot "java-core"
$EmailReviewerRoot = Join-Path $RepoRoot "insight\agents\eia-email-reviewer"
$AgentServiceRoot  = Join-Path $RepoRoot "agent-service"
$MultiAgentRoot    = Join-Path $RepoRoot "multiagent"

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
    $currentStorageAccount = az functionapp config appsettings list `
        --name $FunctionAppName `
        --resource-group $ResourceGroupName `
        --query "[?name=='AzureWebJobsStorage__accountName'].value | [0]" `
        -o tsv 2>$null

    if ($LASTEXITCODE -eq 0 -and $currentStorageAccount -eq $StorageAccountName) {
        Write-Host "[INFO] Required host setting already present on $FunctionAppName; skipping update." -ForegroundColor DarkCyan
        return
    }

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

function Remove-BuildOutputDirectory {
    param(
        [Parameter(Mandatory=$true)][string]$SourceDir,
        [Parameter(Mandatory=$true)][string]$FunctionLabel
    )

    $targetDir = Join-Path $SourceDir 'target'
    if (-not (Test-Path $targetDir)) {
        return
    }

    try {
        cmd.exe /c "rd /s /q `"$targetDir`"" | Out-Null
    } catch {
        throw "Failed to clear build output directory for $FunctionLabel at $targetDir. Close any process locking the folder and try again."
    }

    if (Test-Path $targetDir) {
        throw "Failed to clear build output directory for $FunctionLabel at $targetDir. Close any process locking the folder and try again."
    }
}

function Invoke-MavenPackage {
    param(
        [Parameter(Mandatory=$true)][string]$SourceDir,
        [Parameter(Mandatory=$true)][string]$FunctionLabel,
        [Parameter(Mandatory=$true)][string]$MavenPath,
        [Parameter(Mandatory=$true)][int]$TimeoutMinutes,
        [Parameter()][switch]$SkipClean,
        [Parameter()][string[]]$MavenArgs
    )

    $stdoutLog = Join-Path $env:TEMP ("$FunctionLabel-maven-stdout.log")
    $stderrLog = Join-Path $env:TEMP ("$FunctionLabel-maven-stderr.log")
    Remove-Item $stdoutLog, $stderrLog -Force -ErrorAction SilentlyContinue

    if ($MavenArgs) {
        $mavenArgs = $MavenArgs
    } else {
        $mavenArgs = @('-DskipTests', '--no-transfer-progress')
        if ($SkipClean) {
            $mavenArgs = @('package') + $mavenArgs
        } else {
            $mavenArgs = @('clean', 'package') + $mavenArgs
        }
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

function Ensure-LibraryJars {
    param(
        [Parameter(Mandatory=$true)][string]$JavaCoreRoot,
        [Parameter(Mandatory=$true)][string]$EmailReviewerRoot,
        [Parameter(Mandatory=$true)][string]$MavenPath,
        [Parameter(Mandatory=$true)][int]$TimeoutMinutes
    )

    foreach ($dir in @($JavaCoreRoot, $EmailReviewerRoot)) {
        if (-not (Test-Path (Join-Path $dir "pom.xml"))) {
            throw "Required library project not found (pom.xml missing): $dir"
        }
    }

    Write-Host "[INFO] Building prerequisite library JARs (java-core, eia-email-reviewer)..." -ForegroundColor Cyan

    # java-core: install to the local Maven repo (eia-email-reviewer depends on it) and copy
    # the thin JAR to project-lib/java via the 'library' profile.
    Invoke-MavenPackage -SourceDir $JavaCoreRoot -FunctionLabel "java-core" -MavenPath $MavenPath -TimeoutMinutes $TimeoutMinutes `
        -MavenArgs @('clean', 'install', '-Dlibrary', '-DskipTests', '--no-transfer-progress')

    # eia-email-reviewer: copy its thin JAR to project-lib/java via the 'library' profile.
    Invoke-MavenPackage -SourceDir $EmailReviewerRoot -FunctionLabel "eia-email-reviewer" -MavenPath $MavenPath -TimeoutMinutes $TimeoutMinutes `
        -MavenArgs @('clean', 'package', '-Dlibrary', '-DskipTests', '--no-transfer-progress')

    Write-Host "[SUCCESS] Prerequisite library JARs are ready in project-lib/java" -ForegroundColor Green
}

function Ensure-MultiAgentLibrary {
    param(
        [Parameter(Mandatory=$true)][string]$JavaCoreRoot,
        [Parameter(Mandatory=$true)][string]$MultiAgentRoot,
        [Parameter(Mandatory=$true)][string]$MavenPath,
        [Parameter(Mandatory=$true)][int]$TimeoutMinutes
    )

    foreach ($dir in @($JavaCoreRoot, $MultiAgentRoot)) {
        if (-not (Test-Path (Join-Path $dir "pom.xml"))) {
            throw "Required library project not found (pom.xml missing): $dir"
        }
    }

    Write-Host "[INFO] Building prerequisite library JARs (java-core, multiagent)..." -ForegroundColor Cyan

    # java-core: install to the local Maven repo so multiagent (and agent-service) can
    # resolve it as a normal Maven dependency during a single-directory build.
    Invoke-MavenPackage -SourceDir $JavaCoreRoot -FunctionLabel "java-core" -MavenPath $MavenPath -TimeoutMinutes $TimeoutMinutes `
        -MavenArgs @('clean', 'install', '-DskipTests', '--no-transfer-progress')

    # multiagent: install to the local Maven repo so agent-service can resolve it as a
    # normal Maven dependency (agent-service bundles jars via copy-dependencies, not shading).
    Invoke-MavenPackage -SourceDir $MultiAgentRoot -FunctionLabel "multiagent" -MavenPath $MavenPath -TimeoutMinutes $TimeoutMinutes `
        -MavenArgs @('clean', 'install', '-DskipTests', '--no-transfer-progress')

    Write-Host "[SUCCESS] Prerequisite library JARs are ready (java-core, multiagent installed to local repo)" -ForegroundColor Green
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
        [Parameter()][int]$PollIntervalSeconds = 10,
        [Parameter()][int]$MaxForbiddenRetries = 6
    )

    $forbiddenCount = 0

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

            # Any successful call means SCM access has propagated.
            $forbiddenCount = 0

            $activeIds = ($activeDeployments | ForEach-Object { $_.id }) -join ', '
            Write-Host "[INFO] Waiting for active deployment(s) on $FunctionLabel to finish: $activeIds" -ForegroundColor DarkCyan
        } catch {
            if (Test-ScmIpForbidden -Exception $_.Exception) {
                $forbiddenCount++
                if ($forbiddenCount -lt $MaxForbiddenRetries) {
                    Write-Host "[WARNING] SCM access for $FunctionLabel is returning 403 Ip Forbidden (attempt $forbiddenCount/$MaxForbiddenRetries). This can be temporary while access rules propagate; retrying..." -ForegroundColor Yellow
                    Start-Sleep -Seconds $PollIntervalSeconds
                    continue
                }

                throw "SCM access for $FunctionLabel is blocked (403 Ip Forbidden) after $forbiddenCount consecutive checks. This usually means 6.operation-prod.ps1 has already disabled public inbound access for the Function App. Deploy code before prod hardening, or temporarily undo the hardening and retry."
            }
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

function Test-JarArchiveIntegrity {
    param(
        [Parameter(Mandatory=$true)][string]$JarPath
    )

    if (-not (Test-Path $JarPath)) {
        return $false
    }

    $item = Get-Item -LiteralPath $JarPath -ErrorAction SilentlyContinue
    if ($null -eq $item -or $item.Length -le 0) {
        return $false
    }

    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        $archive = [System.IO.Compression.ZipFile]::OpenRead($JarPath)
        try {
            # Touch entries to force central directory/header read.
            $null = $archive.Entries.Count
        } finally {
            $archive.Dispose()
        }
        return $true
    } catch {
        return $false
    }
}

function Get-HttpStatusCodeFromException {
    param(
        [Parameter(Mandatory=$true)]$Exception
    )

    if ($null -eq $Exception) {
        return $null
    }

    $response = $Exception.Response
    if ($null -eq $response) {
        return $null
    }

    try {
        return [int]$response.StatusCode
    } catch {
        return $null
    }
}

function Test-ScmIpForbidden {
    param(
        [Parameter(Mandatory=$true)]$Exception
    )

    $statusCode = Get-HttpStatusCodeFromException -Exception $Exception
    if ($statusCode -ne 403) {
        return $false
    }

    return ($Exception.Message -match 'Ip Forbidden|IP Forbidden|Forbidden')
}

# =============================================================================
# STEP 1: Select which workload(s) to deploy
# =============================================================================
Write-Host "Which workload(s) do you want to deploy?" -ForegroundColor White
Write-Host "  1. mailbox-to-queue"
Write-Host "  2. queue-to-db"
Write-Host "  3. cu-queue-to-db"
Write-Host "  4. insight-ui web app"
Write-Host "  5. agent-service (multi-agent orchestrator)"
Write-Host "  6. All"
Write-Host ""
Write-Host "  You can enter a single number or comma-separated list (e.g. 1,3)" -ForegroundColor DarkCyan
Write-Host ""

$validOptions = @('1','2','3','4','5','6')
do {
    $rawInput = (Read-Host "Enter selection(s)").Trim()
    $selections = $rawInput -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    $allValid = ($selections.Count -gt 0) -and ($selections | Where-Object { $_ -notin $validOptions }).Count -eq 0
    if (-not $allValid) {
        Write-Host "[ERROR] Please enter 1, 2, 3, 4, 5, 6, or a comma-separated list (e.g. 1,4)." -ForegroundColor Red
    }
} while (-not $allValid)

# Expand '6' (All) into individual selections, then deduplicate
if ($selections -contains '6') {
    $selections = @('1','2','3','4','5')
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
if ($selections -contains '5') {
    $targets.Add(@{
        Label           = "agent-service"
        AppName         = $FuncAgentServiceName
        SourceDir       = $AgentServiceRoot
        Kind            = "function"
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

        # The web app references thin library JARs (java-core, eia-email-reviewer) from
        # project-lib/java via system-scoped dependencies. Build those prerequisites first
        # so the JARs exist before insight-ui is packaged.
        if ($TargetKind -eq 'webapp') {
            Ensure-LibraryJars -JavaCoreRoot $JavaCoreRoot -EmailReviewerRoot $EmailReviewerRoot -MavenPath $mvn.Source -TimeoutMinutes $MavenTimeoutMinutes
        }
        if ($FunctionLabel -eq 'agent-service') {
            Ensure-MultiAgentLibrary -JavaCoreRoot $JavaCoreRoot -MultiAgentRoot $MultiAgentRoot -MavenPath $mvn.Source -TimeoutMinutes $MavenTimeoutMinutes
        }

        # Remove the previous build output first so Maven does not have to delete a locked target tree.
        Remove-BuildOutputDirectory -SourceDir $SourceDir -FunctionLabel $FunctionLabel

        # Package only after the output directory is removed; this is equivalent to a clean build without
        # relying on the Maven clean plugin to delete locked files.
        Invoke-MavenPackage -SourceDir $SourceDir -FunctionLabel $FunctionLabel -MavenPath $mvn.Source -TimeoutMinutes $MavenTimeoutMinutes -SkipClean
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

        if (-not (Test-JarArchiveIntegrity -JarPath $jarFile.FullName)) {
            Write-Host "[ERROR] Built JAR is invalid or corrupted: $($jarFile.FullName)" -ForegroundColor Red
            Write-Host "[ERROR] Rebuild the project and ensure no process is locking files under target before deployment." -ForegroundColor Red
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

            # Poll lightweight anonymous URLs and require consecutive healthy checks
            # so transient startup states do not look like a successful deployment.
            $pollStart    = [DateTime]::UtcNow
            $pollDeadline = $pollStart.AddMinutes($WebAppDeployTimeoutMinutes)
            $pollInterval = 15
            $appReady = $false
            $lastObservedStatus = $null
            $lastObservedError  = ""
            $smokeUrls = @($appUrl, "$appUrl/actuator/health")
            $requiredStablePasses = 2
            $stablePasses = 0
            $lastSmokeSummary = ""
            while ([DateTime]::UtcNow -lt $pollDeadline) {
                $allHealthy = $true
                $currentStatuses = [System.Collections.Generic.List[string]]::new()

                foreach ($smokeUrl in $smokeUrls) {
                    try {
                        $resp = Invoke-WebRequest -Uri $smokeUrl -UseBasicParsing -TimeoutSec 10 -MaximumRedirection 0 -ErrorAction Stop
                        $statusCode = [int]$resp.StatusCode
                        $currentStatuses.Add("$smokeUrl=$statusCode")
                        $lastObservedStatus = $statusCode

                        if ($statusCode -ge 500) {
                            $allHealthy = $false
                        }
                    } catch {
                        $statusCode = Get-HttpStatusCodeFromException -Exception $_.Exception
                        if ($null -ne $statusCode) {
                            $currentStatuses.Add("$smokeUrl=$statusCode")
                            $lastObservedStatus = $statusCode
                            if ($statusCode -ge 500) {
                                $allHealthy = $false
                            }
                        } else {
                            $currentStatuses.Add("$smokeUrl=ERR")
                            $allHealthy = $false
                            $lastObservedError = $_.Exception.Message
                        }
                    }
                }

                $lastSmokeSummary = ($currentStatuses -join '; ')

                if ($allHealthy) {
                    $stablePasses++
                    if ($stablePasses -ge $requiredStablePasses) {
                        Write-Host "[SUCCESS] App smoke checks passed ($lastSmokeSummary)." -ForegroundColor Green
                        $appReady = $true
                        break
                    }
                } else {
                    $stablePasses = 0
                }

                $elapsed = [int]([DateTime]::UtcNow - $pollStart).TotalSeconds
                if ($lastSmokeSummary) {
                    Write-Host ("[INFO] App not yet ready ({0}s elapsed, checks: {1}, stable passes: {2}/{3}), retrying in {4}s..." -f $elapsed, $lastSmokeSummary, $stablePasses, $requiredStablePasses, $pollInterval) -ForegroundColor DarkCyan
                } elseif ($null -ne $lastObservedStatus) {
                    Write-Host ("[INFO] App not yet ready ({0}s elapsed, last HTTP: {1}), retrying in {2}s..." -f $elapsed, $lastObservedStatus, $pollInterval) -ForegroundColor DarkCyan
                } else {
                    Write-Host ("[INFO] App not yet ready ({0}s elapsed), retrying in {1}s..." -f $elapsed, $pollInterval) -ForegroundColor DarkCyan
                }
                Start-Sleep -Seconds $pollInterval
            }
            if (-not $appReady) {
                if ($lastSmokeSummary) {
                    Write-Host "[WARNING] App did not become ready within $WebAppDeployTimeoutMinutes min (last smoke checks: $lastSmokeSummary). Check Azure portal for status." -ForegroundColor Yellow
                } elseif ($null -ne $lastObservedStatus) {
                    Write-Host "[WARNING] App did not become ready within $WebAppDeployTimeoutMinutes min (last HTTP: $lastObservedStatus). Check Azure portal for status." -ForegroundColor Yellow
                } elseif ($lastObservedError) {
                    Write-Host "[WARNING] App did not become ready within $WebAppDeployTimeoutMinutes min (last error: $lastObservedError). Check Azure portal for status." -ForegroundColor Yellow
                } else {
                    Write-Host "[WARNING] App did not respond within $WebAppDeployTimeoutMinutes min. Check Azure portal for status." -ForegroundColor Yellow
                }
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
            if (Test-ScmIpForbidden -Exception $_.Exception) {
                Write-Host "[ERROR] SCM access is blocked for $FunctionLabel (403 Ip Forbidden)." -ForegroundColor Red
                Write-Host "[ERROR] The Function App was likely hardened by 6.operation-prod.ps1 before code deployment." -ForegroundColor Red
                Write-Host "[ERROR] Re-enable Function App public inbound access or run 6.operation-prod.ps1 -Rollback, deploy code, then re-run 6.operation-prod.ps1." -ForegroundColor Red
                $deploymentErrors.Add($FunctionLabel)
                $recordedFunctionError = $true
                break
            }
            Write-Host "[ERROR] Failed to initiate deployment for $FunctionLabel." -ForegroundColor Red
            Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
            # 502/503 from the SCM site during Kudu cold start are transient — retry like any other attempt.
            if ($deployAttempt -lt $maxDeployAttempts) {
                Write-Host "[INFO] Retrying in $RetryDelaySeconds second(s)..." -ForegroundColor Cyan
                Start-Sleep -Seconds $RetryDelaySeconds
                continue
            }
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
        if ($deployStatus -eq 3 -and $deployId) {
            try {
                $failedDeploy = Invoke-RestMethod `
                    -Uri "https://$scmHost/api/deployments/$deployId" `
                    -Headers @{ Authorization = "Bearer $armToken" } `
                    -TimeoutSec 30 `
                    -ErrorAction Stop

                $statusText = [string]$failedDeploy.status_text
                if (-not [string]::IsNullOrWhiteSpace($statusText)) {
                    Write-Host "[ERROR] OneDeploy status text: $statusText" -ForegroundColor Red
                }

                if ($statusText -match 'InaccessibleStorageException|BlobUploadFailedException|Failed to access storage account') {
                    Write-Host "[ERROR] Deployment pipeline cannot write to the Functions storage account." -ForegroundColor Red
                    Write-Host "[ERROR] Check storage network/auth policy posture for this environment. OneDeploy requires deployment-time blob upload access." -ForegroundColor Red
                    Write-Host "[ERROR] Quick checks:" -ForegroundColor Red
                    Write-Host "        az storage account show -n $StorageAccountName -g $ResourceGroupName --query '{pna:publicNetworkAccess,defaultAction:networkRuleSet.defaultAction,bypass:networkRuleSet.bypass,allowSharedKeyAccess:allowSharedKeyAccess}'" -ForegroundColor Red
                    Write-Host "[ERROR] If policy forces pna=Disabled, request a policy exception or a deployment-approved storage configuration." -ForegroundColor Red
                }
            } catch {
                Write-Host "[WARNING] Could not fetch detailed deployment failure text for $FunctionLabel." -ForegroundColor Yellow
            }
        }
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


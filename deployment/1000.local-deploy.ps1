#Requires -Version 5.1
<#
.SYNOPSIS
    Builds and runs local workloads for the three Azure Function apps and the Spring Boot web app.
.DESCRIPTION
    Prompts the user to select which workloads to run locally, builds the
    selected targets with Maven, then starts either the Azure Functions Core
    Tools host or the Spring Boot web app.

    With -Debug, a single selected function host starts with a Java debug agent
    on port 5005 so you can attach VS Code using the provided launch
    configurations in .vscode/launch.json.
.PARAMETER Debug
    Start a single function host with Java remote debugging enabled on port 5005.
.PARAMETER KeyVaultUrl
    Optional. Key Vault URL to pass to local workloads. If omitted, the script
    uses AZURE_KEY_VAULT_URL, then env.bat.
.USAGE
    .\1000.local-deploy.ps1
    .\1000.local-deploy.ps1 -Debug
    .\1000.local-deploy.ps1 -KeyVaultUrl https://my-vault.vault.azure.net
#>
param(
    [switch]$Debug,
    [string]$KeyVaultUrl
)

$ErrorActionPreference = "Stop"

$ScriptRoot    = $PSScriptRoot
$RepoRoot      = Split-Path $ScriptRoot -Parent
$FunctionsRoot = Join-Path $RepoRoot "extract\functions"
$UiRoot        = Join-Path $RepoRoot "insight\ui"

# =============================================================================
# Helper Functions (defined before use)
# =============================================================================
function Get-HostShell {
    if (Get-Command pwsh -ErrorAction SilentlyContinue) {
        return "pwsh"
    }
    return "powershell"
}

function Get-KeyVaultUrlFromEnvBat {
    $envBatPath = Join-Path $RepoRoot 'env.bat'
    if (-not (Test-Path $envBatPath)) {
        return $null
    }

    $match = Select-String -Path $envBatPath -Pattern '^\s*set\s+AZURE_KEY_VAULT_URL\s*=\s*(.+)\s*$' | Select-Object -First 1
    if (-not $match) {
        return $null
    }

    return $match.Matches[0].Groups[1].Value.Trim()
}

function Resolve-KeyVaultUrl {
    param([string]$ExplicitUrl)

    foreach ($candidate in @(
        $ExplicitUrl,
        $env:AZURE_KEY_VAULT_URL,
        (Get-KeyVaultUrlFromEnvBat)
    )) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            return $candidate.Trim()
        }
    }

    return $null
}

# =============================================================================
# PREREQUISITES
# =============================================================================
Write-Host ""
Write-Host "[INFO] ============================================================" -ForegroundColor Cyan
Write-Host "[INFO] Local Run / Debug"                                             -ForegroundColor Cyan
Write-Host "[INFO] ============================================================" -ForegroundColor Cyan
Write-Host ""

if (-not $env:JAVA_HOME) {
    Write-Host "[ERROR] JAVA_HOME is not set." -ForegroundColor Red
    exit 1
}
if (-not (Get-Command mvn -ErrorAction SilentlyContinue)) {
    Write-Host "[ERROR] Maven (mvn) is not on PATH." -ForegroundColor Red
    exit 1
}

$script:ResolvedKeyVaultUrl = Resolve-KeyVaultUrl -ExplicitUrl $KeyVaultUrl
if ($script:ResolvedKeyVaultUrl) {
    $env:AZURE_KEY_VAULT_URL = $script:ResolvedKeyVaultUrl
    Write-Host "[INFO] Key Vault URL resolved: $script:ResolvedKeyVaultUrl" -ForegroundColor Cyan
} else {
    Write-Host "[WARNING] No Key Vault URL resolved. Use -KeyVaultUrl, set AZURE_KEY_VAULT_URL, or populate env.bat." -ForegroundColor Yellow
}

# =============================================================================
# Additional Helpers
# =============================================================================

function Ensure-AzuriteRunning {
    $azuritePort = 10000
    $azuriteRunning = $false
    $startedProcess = $null

    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.Connect("127.0.0.1", $azuritePort)
        $tcp.Close()
        $azuriteRunning = $true
    } catch {
    }

    if ($azuriteRunning) {
        Write-Host "[OK] Azurite already running on port $azuritePort" -ForegroundColor Green
        return $null
    }

    Write-Host "[INFO] Azurite is not running. Starting it..." -ForegroundColor Cyan

    $azuriteCmd = Get-Command azurite -ErrorAction SilentlyContinue
    if (-not $azuriteCmd) {
        if (Get-Command npm -ErrorAction SilentlyContinue) {
            Write-Host "[INFO] Azurite not found. Installing via npm..." -ForegroundColor Cyan
            npm install -g azurite
            if ($LASTEXITCODE -ne 0) {
                Write-Host "[ERROR] npm install -g azurite failed." -ForegroundColor Red
                exit 1
            }
        } elseif (Get-Command winget -ErrorAction SilentlyContinue) {
            Write-Host "[INFO] npm not found. Installing Node.js LTS via winget..." -ForegroundColor Cyan
            winget install OpenJS.NodeJS.LTS --accept-source-agreements --accept-package-agreements
            if ($LASTEXITCODE -ne 0) {
                Write-Host "[ERROR] winget install Node.js failed." -ForegroundColor Red
                exit 1
            }
            $nodePath = Join-Path $env:ProgramFiles "nodejs"
            if (Test-Path $nodePath) {
                $env:PATH = "$nodePath;$env:PATH"
            }
            $npmGlobalPath = Join-Path $env:APPDATA "npm"
            if (-not ($env:PATH -split ';' | Where-Object { $_ -eq $npmGlobalPath })) {
                $env:PATH = "$npmGlobalPath;$env:PATH"
            }
            if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
                Write-Host "[ERROR] Node.js installed but npm not found on PATH. Close and reopen your terminal, then retry." -ForegroundColor Red
                exit 1
            }
            Write-Host "[OK] Node.js installed" -ForegroundColor Green
            Write-Host "[INFO] Installing Azurite via npm..." -ForegroundColor Cyan
            npm install -g azurite
            if ($LASTEXITCODE -ne 0) {
                Write-Host "[ERROR] npm install -g azurite failed." -ForegroundColor Red
                exit 1
            }
        } else {
            Write-Host "[ERROR] Neither npm nor winget found. Install Node.js manually: https://nodejs.org" -ForegroundColor Red
            exit 1
        }

        $azuriteCmd = Get-Command azurite -ErrorAction SilentlyContinue
        if (-not $azuriteCmd) {
            Write-Host "[ERROR] Azurite installed but not found on PATH. Close and reopen your terminal, then retry." -ForegroundColor Red
            exit 1
        }
        Write-Host "[OK] Azurite installed" -ForegroundColor Green
    }

    $azuritePath = $azuriteCmd.Source
    $shell = Get-HostShell
    $startedProcess = Start-Process -FilePath $shell `
        -ArgumentList "-NoProfile", "-Command", "& '$azuritePath' --silent" `
        -WindowStyle Hidden -PassThru

    $waited = 0
    while ($waited -lt 10) {
        Start-Sleep -Seconds 1
        $waited++
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $tcp.Connect("127.0.0.1", $azuritePort)
            $tcp.Close()
            $azuriteRunning = $true
            break
        } catch {
        }
    }

    if (-not $azuriteRunning) {
        Write-Host "[ERROR] Azurite failed to start within 10 seconds." -ForegroundColor Red
        exit 1
    }

    Write-Host "[OK] Azurite started (PID $($startedProcess.Id))" -ForegroundColor Green
    return $startedProcess
}

function Invoke-MavenBuild {
    param(
        [Parameter(Mandatory=$true)][string]$SourceDir,
        [Parameter(Mandatory=$true)][string]$Label,
        [Parameter()][switch]$SkipClean
    )

    Push-Location $SourceDir
    try {
        if ($SkipClean) {
            mvn package -DskipTests --no-transfer-progress
        } else {
            mvn clean package -DskipTests --no-transfer-progress
        }

        if ($LASTEXITCODE -ne 0) {
            Write-Host "[ERROR] Maven build failed for $Label." -ForegroundColor Red
            exit 1
        }
    } finally {
        Pop-Location
    }
}

function Resolve-FunctionLocalSettings {
    param([Parameter(Mandatory=$true)][string]$StagingDir)

    $stagingSettings = Join-Path $StagingDir "local.settings.json"
    if ($env:AZURE_KEY_VAULT_URL -and (Test-Path $stagingSettings)) {
        Write-Host "[INFO] Resolving local.settings.json in staging directory..." -ForegroundColor Cyan
        Write-Host "[INFO] AZURE_KEY_VAULT_URL = $env:AZURE_KEY_VAULT_URL" -ForegroundColor Cyan
        $kvName = ([Uri]$env:AZURE_KEY_VAULT_URL).Host -replace '\.vault\.azure\.net$',''
        $settings = Get-Content $stagingSettings -Raw | ConvertFrom-Json

        $settings.Values.AZURE_KEY_VAULT_URL = $env:AZURE_KEY_VAULT_URL

        foreach ($prop in ($settings.Values.PSObject.Properties | Where-Object { $_.Value -match '@Microsoft\.KeyVault\(' })) {
            if ($prop.Value -match 'SecretName=([^;)]+)') {
                $secretName = $Matches[1]
                Write-Host "[INFO] Resolving Key Vault secret '$secretName' for $($prop.Name)..." -ForegroundColor Cyan
                try {
                    $secretValue = az keyvault secret show --vault-name $kvName --name $secretName --query value -o tsv 2>&1
                    if ($LASTEXITCODE -eq 0 -and $secretValue) {
                        $prop.Value = $secretValue
                        Write-Host "[OK]   $($prop.Name) resolved from Key Vault" -ForegroundColor Green
                    } else {
                        Write-Host "[WARNING] Could not read secret '$secretName': $secretValue" -ForegroundColor Yellow
                    }
                } catch {
                    Write-Host "[WARNING] Failed to resolve secret '$secretName': $_" -ForegroundColor Yellow
                }
            }
        }

        $settings | ConvertTo-Json -Depth 10 | Set-Content $stagingSettings -Encoding UTF8
        Write-Host "[OK] Staging local.settings.json updated with resolved secrets" -ForegroundColor Green
    } elseif (-not $env:AZURE_KEY_VAULT_URL) {
        Write-Host "[WARNING] AZURE_KEY_VAULT_URL environment variable is not set. Run env.bat first or set it manually." -ForegroundColor Yellow
        Write-Host "          local.settings.json will use its existing values." -ForegroundColor Yellow
    }
}

function Start-TargetWindow {
    param(
        [Parameter(Mandatory=$true)][hashtable]$Target,
        [Parameter()][switch]$EnableDebug
    )

    $shell = Get-HostShell
    $envPrefix = ''
    if ($script:ResolvedKeyVaultUrl) {
        $envPrefix = "`$env:AZURE_KEY_VAULT_URL='$($script:ResolvedKeyVaultUrl)'; "
    }

    if ($Target.Kind -eq 'function') {
        if ($EnableDebug) {
            $command = $envPrefix + "Set-Location '$($Target.StagingDir)'; func host start --port $($Target.LocalPort) --java --language-workers '--java:-agentlib:jdwp=transport=dt_socket,server=y,suspend=y,address=5005'"
        } else {
            $command = $envPrefix + "Set-Location '$($Target.StagingDir)'; func host start --port $($Target.LocalPort) --java"
        }
    } else {
        $javaExe = Join-Path $env:JAVA_HOME 'bin\java.exe'
        $command = $envPrefix + "`$env:PORT='$($Target.LocalPort)'; Set-Location '$($Target.SourceDir)'; & '$javaExe' -jar '$($Target.JarPath)'"
    }

    $process = Start-Process -FilePath $shell -ArgumentList '-NoExit', '-Command', $command -PassThru
    Write-Host "[SUCCESS] Started $($Target.Label) (PID $($process.Id))" -ForegroundColor Green
}

# =============================================================================
# STEP 1: Select workload(s)
# =============================================================================
Write-Host "Which workload(s) do you want to run locally?" -ForegroundColor White
Write-Host "  1. mailbox-to-queue  (Timer -> polls mailbox -> Service Bus)"
Write-Host "  2. queue-to-db       (Service Bus -> extracts email -> Cosmos DB)"
Write-Host "  3. cu-queue-to-db    (Storage Queue -> polls CU analysis -> Cosmos DB)"
Write-Host "  4. insight-ui web app"
Write-Host "  5. All"
Write-Host ""
Write-Host "  You can enter a single number or comma-separated list (e.g. 1,4)" -ForegroundColor DarkCyan
Write-Host ""

$validOptions = @('1','2','3','4','5')
do {
    $rawInput = (Read-Host "Enter selection(s)").Trim()
    $selections = $rawInput -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    $allValid = ($selections.Count -gt 0) -and ($selections | Where-Object { $_ -notin $validOptions }).Count -eq 0
    if (-not $allValid) {
        Write-Host "[ERROR] Please enter 1, 2, 3, 4, 5, or a comma-separated list." -ForegroundColor Red
    }
} while (-not $allValid)

if ($selections -contains '5') {
    $selections = @('1','2','3','4')
} else {
    $selections = $selections | Select-Object -Unique
}

$targets = [System.Collections.Generic.List[hashtable]]::new()
if ($selections -contains '1') {
    $sourceDir = Join-Path $FunctionsRoot 'mailbox-to-queue'
    $targets.Add(@{
        Label      = 'mailbox-to-queue'
        Kind       = 'function'
        SourceDir  = $sourceDir
        StagingDir = Join-Path $sourceDir 'target\azure-functions\mailbox-to-queue-function'
        LocalPort  = 7071
    })
}
if ($selections -contains '2') {
    $sourceDir = Join-Path $FunctionsRoot 'queue-to-db'
    $targets.Add(@{
        Label      = 'queue-to-db'
        Kind       = 'function'
        SourceDir  = $sourceDir
        StagingDir = Join-Path $sourceDir 'target\azure-functions\queue-to-db-function'
        LocalPort  = 7072
    })
}
if ($selections -contains '3') {
    $sourceDir = Join-Path $FunctionsRoot 'cu-queue-to-db'
    $targets.Add(@{
        Label      = 'cu-queue-to-db'
        Kind       = 'function'
        SourceDir  = $sourceDir
        StagingDir = Join-Path $sourceDir 'target\azure-functions\cu-queue-to-db-function'
        LocalPort  = 7073
    })
}
if ($selections -contains '4') {
    $targets.Add(@{
        Label     = 'insight-ui'
        Kind      = 'webapp'
        SourceDir = $UiRoot
        LocalPort = 8080
    })
}

$hasFunctionTargets = ($targets | Where-Object { $_.Kind -eq 'function' }).Count -gt 0
$runInline = $targets.Count -eq 1 -and $targets[0].Kind -eq 'function'

if ($Debug -and -not $runInline) {
    Write-Host "[WARNING] -Debug only applies when running a single function target. Continuing without debugger." -ForegroundColor Yellow
    $Debug = $false
}

if ($hasFunctionTargets -and -not (Get-Command func -ErrorAction SilentlyContinue)) {
    Write-Host "[ERROR] Azure Functions Core Tools (func) is not on PATH." -ForegroundColor Red
    Write-Host "        Install: npm install -g azure-functions-core-tools@4 --unsafe-perm true" -ForegroundColor Yellow
    exit 1
}

Write-Host ""
Write-Host "[INFO] Selected local targets:" -ForegroundColor Cyan
foreach ($target in $targets) {
    Write-Host "  $($target.Label.PadRight(18)) [$($target.Kind)] port $($target.LocalPort)" -ForegroundColor Cyan
}
if ($Debug) {
    Write-Host "[INFO] Debug port : 5005" -ForegroundColor Magenta
}
Write-Host ""

# =============================================================================
# STEP 2: Ensure Azurite (only if functions are selected)
# =============================================================================
$script:AzuriteProcess = $null
if ($hasFunctionTargets) {
    $script:AzuriteProcess = Ensure-AzuriteRunning
}

# =============================================================================
# STEP 3: Build selected targets
# =============================================================================
foreach ($target in $targets) {
    Write-Host "[INFO] Building $($target.Label) with Maven..." -ForegroundColor Cyan
    Invoke-MavenBuild -SourceDir $target.SourceDir -Label $target.Label -SkipClean:($target.Kind -eq 'webapp')
    Write-Host "[SUCCESS] Maven build completed for $($target.Label)" -ForegroundColor Green

    if ($target.Kind -eq 'function') {
        if (-not (Test-Path $target.StagingDir)) {
            Write-Host "[ERROR] Staging directory not found: $($target.StagingDir)" -ForegroundColor Red
            exit 1
        }

        Resolve-FunctionLocalSettings -StagingDir $target.StagingDir
    } else {
        $jarFile = Get-ChildItem (Join-Path $target.SourceDir 'target') -Filter '*.jar' -File |
            Where-Object { $_.Name -notlike '*.original' } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if (-not $jarFile) {
            Write-Host "[ERROR] Spring Boot JAR not found for $($target.Label)." -ForegroundColor Red
            exit 1
        }
        $target.JarPath = $jarFile.FullName
    }
}
Write-Host ""

# =============================================================================
# STEP 4: Start selected targets
# =============================================================================
Write-Host ""
if ($runInline) {
    $target = $targets[0]
    if ($Debug) {
        Write-Host "[INFO] Starting $($target.Label) on port $($target.LocalPort) with Java debugger on port 5005..." -ForegroundColor Magenta
        Write-Host "[INFO] Attach VS Code debugger: Run > Start Debugging > 'Attach to $($target.Label)'" -ForegroundColor Magenta
        Write-Host "[INFO] The function host will WAIT for the debugger to attach before processing." -ForegroundColor Yellow
    } else {
        Write-Host "[INFO] Starting $($target.Label) on port $($target.LocalPort)..." -ForegroundColor Cyan
    }
    Write-Host "[INFO] Press Ctrl+C to stop." -ForegroundColor Gray
    Write-Host ""

    Push-Location $target.StagingDir
    try {
        if ($Debug) {
            func host start --port $target.LocalPort --java --language-workers "--java:-agentlib:jdwp=transport=dt_socket,server=y,suspend=y,address=5005"
        } else {
            func host start --port $target.LocalPort --java
        }
    } finally {
        Pop-Location

        if ($script:AzuriteProcess -and -not $script:AzuriteProcess.HasExited) {
            Write-Host ""
            Write-Host "[INFO] Stopping Azurite (PID $($script:AzuriteProcess.Id))..." -ForegroundColor Cyan
            Stop-Process -Id $script:AzuriteProcess.Id -Force -ErrorAction SilentlyContinue
            Write-Host "[OK] Azurite stopped" -ForegroundColor Green
        }
    }
} else {
    Write-Host "[INFO] Launching selected targets in separate PowerShell windows..." -ForegroundColor Cyan
    foreach ($target in $targets) {
        Start-TargetWindow -Target $target
    }
    Write-Host ""
    if ($hasFunctionTargets) {
        Write-Host "[INFO] Azurite will remain running for the launched function hosts." -ForegroundColor Cyan
    }
    Write-Host "[SUCCESS] Local workloads started. Close the opened windows to stop them." -ForegroundColor Green
}

#Requires -Version 5.1
<#
.SYNOPSIS
    Builds and runs an Azure Function app locally with optional VS Code debugging.
.DESCRIPTION
    Prompts the user to select which function to run (mailbox-to-queue or
    queue-to-db), builds the staging directory with Maven, then starts the
    Azure Functions Core Tools host.

    With -Debug, the Functions host starts with a Java debug agent on port 5005
    so you can attach VS Code using the provided launch configurations in
    .vscode/launch.json.
.PARAMETER Debug
    Start the function host with Java remote debugging enabled on port 5005.
.USAGE
    .\100.local-test-deploy.ps1
    .\100.local-test-deploy.ps1 -Debug
#>
param(
    [switch]$Debug
)

$ErrorActionPreference = "Stop"

$ScriptRoot    = $PSScriptRoot
$RepoRoot      = Split-Path $ScriptRoot -Parent
$FunctionsRoot = Join-Path $RepoRoot "extract\functions"

# =============================================================================
# PREREQUISITES
# =============================================================================
Write-Host ""
Write-Host "[INFO] ============================================================" -ForegroundColor Cyan
Write-Host "[INFO] Azure Functions — Local Run / Debug"                          -ForegroundColor Cyan
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
if (-not (Get-Command func -ErrorAction SilentlyContinue)) {
    Write-Host "[ERROR] Azure Functions Core Tools (func) is not on PATH." -ForegroundColor Red
    Write-Host "        Install: npm install -g azure-functions-core-tools@4 --unsafe-perm true" -ForegroundColor Yellow
    exit 1
}

# =============================================================================
# STEP 1: Select function app
# =============================================================================
Write-Host "Which function app do you want to run locally?" -ForegroundColor White
Write-Host "  1. mailbox-to-queue  (Timer → polls mailbox → Service Bus)"
Write-Host "  2. queue-to-db       (Service Bus → extracts email → Cosmos DB)"
Write-Host ""

do {
    $choice = Read-Host "Enter 1 or 2"
    $choice = $choice.Trim()
    if ($choice -notin @('1','2')) {
        Write-Host "[ERROR] Please enter 1 or 2." -ForegroundColor Red
    }
} while ($choice -notin @('1','2'))

switch ($choice) {
    '1' {
        $FunctionLabel = "mailbox-to-queue"
        $SourceDir     = Join-Path $FunctionsRoot "mailbox-to-queue"
        $StagingDir    = Join-Path $SourceDir "target\azure-functions\mailbox-to-queue-function"
        $LocalPort     = 7071
    }
    '2' {
        $FunctionLabel = "queue-to-db"
        $SourceDir     = Join-Path $FunctionsRoot "queue-to-db"
        $StagingDir    = Join-Path $SourceDir "target\azure-functions\queue-to-db-function"
        $LocalPort     = 7072
    }
}

Write-Host ""
Write-Host "[INFO] Selected  : $FunctionLabel" -ForegroundColor Cyan
Write-Host "[INFO] Source     : $SourceDir" -ForegroundColor Cyan
Write-Host "[INFO] Staging    : $StagingDir" -ForegroundColor Cyan
Write-Host "[INFO] HTTP port  : $LocalPort" -ForegroundColor Cyan
if ($Debug) {
    Write-Host "[INFO] Debug port : 5005" -ForegroundColor Magenta
}
Write-Host ""

# =============================================================================
# STEP 2: Resolve local.settings.json — done after Maven build (Step 4)
#         so that the staging copy gets the real values.
# =============================================================================
Write-Host ""

# =============================================================================
# STEP 3: Ensure Azurite (local storage emulator) is running
# =============================================================================
$azuritePort = 10000
$azuriteRunning = $false
try {
    $tcp = New-Object System.Net.Sockets.TcpClient
    $tcp.Connect("127.0.0.1", $azuritePort)
    $tcp.Close()
    $azuriteRunning = $true
} catch {
    # port not listening
}

if ($azuriteRunning) {
    Write-Host "[OK] Azurite already running on port $azuritePort" -ForegroundColor Green
} else {
    Write-Host "[INFO] Azurite is not running. Starting it..." -ForegroundColor Cyan

    # Install Azurite globally if it is not already installed
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
            # Node.js is not installed — install it via winget, then install Azurite
            Write-Host "[INFO] npm not found. Installing Node.js LTS via winget..." -ForegroundColor Cyan
            winget install OpenJS.NodeJS.LTS --accept-source-agreements --accept-package-agreements
            if ($LASTEXITCODE -ne 0) {
                Write-Host "[ERROR] winget install Node.js failed." -ForegroundColor Red
                exit 1
            }
            # Refresh PATH so npm is visible in this session
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
        # Refresh command lookup after install
        $azuriteCmd = Get-Command azurite -ErrorAction SilentlyContinue
        if (-not $azuriteCmd) {
            Write-Host "[ERROR] Azurite installed but not found on PATH. Close and reopen your terminal, then retry." -ForegroundColor Red
            exit 1
        }
        Write-Host "[OK] Azurite installed" -ForegroundColor Green
    }

    # Start Azurite in a hidden window.
    # npm installs azurite as a .ps1 shim on Windows, so we must launch it
    # through pwsh/powershell rather than Start-Process on the .ps1 directly.
    $azuritePath = $azuriteCmd.Source
    $shell = if (Get-Command pwsh -ErrorAction SilentlyContinue) { "pwsh" } else { "powershell" }
    $script:AzuriteProcess = Start-Process -FilePath $shell `
        -ArgumentList "-NoProfile", "-Command", "& '$azuritePath' --silent" `
        -WindowStyle Hidden -PassThru

    # Wait briefly for Azurite to start listening
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
        } catch { }
    }

    if ($azuriteRunning) {
        Write-Host "[OK] Azurite started (PID $($script:AzuriteProcess.Id))" -ForegroundColor Green
    } else {
        Write-Host "[ERROR] Azurite failed to start within 10 seconds." -ForegroundColor Red
        exit 1
    }
}

# =============================================================================
# STEP 4: Maven build
# =============================================================================
Write-Host "[INFO] Building $FunctionLabel with Maven..." -ForegroundColor Cyan
Push-Location $SourceDir
try {
    mvn clean package -DskipTests --no-transfer-progress
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] Maven build failed." -ForegroundColor Red
        exit 1
    }
} finally {
    Pop-Location
}
Write-Host "[SUCCESS] Maven build completed" -ForegroundColor Green

# Verify staging directory
if (-not (Test-Path $StagingDir)) {
    Write-Host "[ERROR] Staging directory not found: $StagingDir" -ForegroundColor Red
    exit 1
}

# =============================================================================
# STEP 4b: Resolve local.settings.json in the staging directory
#           The local Functions runtime does not support @Microsoft.KeyVault(...)
#           references, so we replace them with the actual secret values.
# =============================================================================
$stagingSettings = Join-Path $StagingDir "local.settings.json"
if ($env:KEY_VAULT_URL -and (Test-Path $stagingSettings)) {
    Write-Host "[INFO] Resolving local.settings.json in staging directory..." -ForegroundColor Cyan
    Write-Host "[INFO] KEY_VAULT_URL = $env:KEY_VAULT_URL" -ForegroundColor Cyan
    $kvName = ([Uri]$env:KEY_VAULT_URL).Host -replace '\.vault\.azure\.net$',''
    $settings = Get-Content $stagingSettings -Raw | ConvertFrom-Json

    # Set AZURE_KEY_VAULT_URL from the KEY_VAULT_URL environment variable
    $settings.Values.AZURE_KEY_VAULT_URL = $env:KEY_VAULT_URL

    # Resolve @Microsoft.KeyVault(...) references
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
} elseif (-not $env:KEY_VAULT_URL) {
    Write-Host "[WARNING] KEY_VAULT_URL environment variable is not set. Run env.bat first or set it manually." -ForegroundColor Yellow
    Write-Host "          local.settings.json will use its existing values." -ForegroundColor Yellow
}
Write-Host ""

# =============================================================================
# STEP 5: Start Azure Functions host
# =============================================================================
Write-Host ""
if ($Debug) {
    Write-Host "[INFO] Starting $FunctionLabel on port $LocalPort with Java debugger on port 5005..." -ForegroundColor Magenta
    Write-Host "[INFO] Attach VS Code debugger: Run > Start Debugging > 'Attach to $FunctionLabel'" -ForegroundColor Magenta
    Write-Host "[INFO] The function host will WAIT for the debugger to attach before processing." -ForegroundColor Yellow
} else {
    Write-Host "[INFO] Starting $FunctionLabel on port $LocalPort..." -ForegroundColor Cyan
}
Write-Host "[INFO] Press Ctrl+C to stop." -ForegroundColor Gray
Write-Host ""

Push-Location $StagingDir
try {
    if ($Debug) {
        # languageWorkers:java:arguments passes JVM args to the Java worker.
        # 'suspend=y' makes the worker wait for a debugger before executing functions.
        func host start --port $LocalPort --java --language-workers "--java:-agentlib:jdwp=transport=dt_socket,server=y,suspend=y,address=5005"
    } else {
        func host start --port $LocalPort --java
    }
} finally {
    Pop-Location

    # Stop Azurite if this script started it
    if ($script:AzuriteProcess -and -not $script:AzuriteProcess.HasExited) {
        Write-Host ""
        Write-Host "[INFO] Stopping Azurite (PID $($script:AzuriteProcess.Id))..." -ForegroundColor Cyan
        Stop-Process -Id $script:AzuriteProcess.Id -Force -ErrorAction SilentlyContinue
        Write-Host "[OK] Azurite stopped" -ForegroundColor Green
    }
}

#Requires -Version 5.1
<#
.SYNOPSIS
    Builds and provisions Azure AI Foundry agents.
.DESCRIPTION
    Prompts the user to select which agent(s) to provision, gathers the agent
    instructions, builds each JAR with Maven (also updating project-lib/java
    via the copy-to-project-lib profile), then runs the provisioning main()
    to register the agent in Azure AI Foundry.
.PARAMETER Suffix
    Required. The same suffix used when running deploy-infrastructure.ps1.
.PARAMETER MavenTimeoutMinutes
    Maximum time to allow each Maven build before failing (default: 15).
.USAGE
    .\8.deploy-agents.ps1 -Suffix 999
#>
param(
    [Parameter(HelpMessage="Suffix used during infrastructure deployment (default: 1, example: 1)")]
    [string]$Suffix,

    [Parameter(HelpMessage="Maximum time to allow each Maven package run before failing. Use 0 to disable the timeout.")]
    [ValidateRange(0, 1440)]
    [int]$MavenTimeoutMinutes = 15
)

$ErrorActionPreference = "Stop"

$LocationInput = Read-Host "Enter location [default: centralus, example: centralus]"
$Location = if ([string]::IsNullOrWhiteSpace($LocationInput)) { "centralus" } else { $LocationInput.Trim().ToLowerInvariant() }

$EnvironmentInput = Read-Host "Enter environment [default: dev, example: dev]"
$Environment = if ([string]::IsNullOrWhiteSpace($EnvironmentInput)) { "dev" } else { $EnvironmentInput.Trim().ToLowerInvariant() }

if ([string]::IsNullOrWhiteSpace($Suffix)) {
    $SuffixInput = Read-Host "Enter suffix [default: 1, example: 1]"
    $Suffix = if ([string]::IsNullOrWhiteSpace($SuffixInput)) { "1" } else { $SuffixInput.Trim() }
} else {
    $Suffix = $Suffix.Trim()
}

Write-Host "[INFO] Deployment key: eia-$Environment-$Suffix (location: $Location)" -ForegroundColor Cyan

# =============================================================================
# CONFIGURATION
# =============================================================================
$ProjectName       = "eia"
$ResourceGroupName = "rg-$ProjectName-$Environment-$Suffix"
$KeyVaultName      = "kv-$ProjectName-$Environment-$Suffix"

$ScriptRoot  = $PSScriptRoot
$RepoRoot    = Split-Path $ScriptRoot -Parent
$AgentsRoot  = Join-Path $RepoRoot "insight\agents"

# =============================================================================
# PREREQUISITES
# =============================================================================
Write-Host ""
Write-Host "[INFO] ============================================================" -ForegroundColor Cyan
Write-Host "[INFO] Agent Provisioning"                                             -ForegroundColor Cyan
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

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================
function Write-NewLogContent {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][ref]$LineCount
    )

    if (-not (Test-Path $Path)) { return }

    $lines = Get-Content -Path $Path
    if ($lines.Count -le $LineCount.Value) { return }

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
        [Parameter(Mandatory=$true)][string]$Label,
        [Parameter(Mandatory=$true)][string]$MavenPath,
        [Parameter(Mandatory=$true)][int]$TimeoutMinutes,
        [string[]]$ExtraArgs = @()
    )

    $stdoutLog = Join-Path $env:TEMP ("$Label-maven-stdout.log")
    $stderrLog = Join-Path $env:TEMP ("$Label-maven-stderr.log")
    Remove-Item $stdoutLog, $stderrLog -Force -ErrorAction SilentlyContinue

    $mavenArgs = @('clean', 'package', '-DskipTests', '--no-transfer-progress') + $ExtraArgs

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
                try { $process.Kill($true) } catch { }
                Write-NewLogContent -Path $stdoutLog -LineCount ([ref]$stdoutLineCount)
                Write-NewLogContent -Path $stderrLog -LineCount ([ref]$stderrLineCount)
                throw "Maven build for $Label exceeded the timeout of $TimeoutMinutes minute(s)."
            }

            Start-Sleep -Seconds 2
        }

        Write-NewLogContent -Path $stdoutLog -LineCount ([ref]$stdoutLineCount)
        Write-NewLogContent -Path $stderrLog -LineCount ([ref]$stderrLineCount)

        if ($process.ExitCode -ne 0) {
            throw "Maven build failed for $Label with exit code $($process.ExitCode)."
        }
    } finally {
        Remove-Item $stdoutLog, $stderrLog -Force -ErrorAction SilentlyContinue
    }
}

function Get-ArtifactSha256 {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not (Test-Path $Path)) { return "" }
    try {
        return (Get-FileHash -Path $Path -Algorithm SHA256 -ErrorAction Stop).Hash
    } catch {
        return ""
    }
}

# =============================================================================
# STEP 1: Select which agent(s) to provision
# =============================================================================
Write-Host "Which agent(s) do you want to provision?" -ForegroundColor White
Write-Host "  1. eia-email-reviewer"
Write-Host "  2. All"
Write-Host ""
Write-Host "  You can enter a single number or comma-separated list (e.g. 1)" -ForegroundColor DarkCyan
Write-Host ""

$validOptions = @('1','2')
do {
    $rawInput   = (Read-Host "Enter selection(s)").Trim()
    $selections = $rawInput -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    $allValid   = ($selections.Count -gt 0) -and ($selections | Where-Object { $_ -notin $validOptions }).Count -eq 0
    if (-not $allValid) {
        Write-Host "[ERROR] Please enter 1, 2, or a comma-separated list." -ForegroundColor Red
    }
} while (-not $allValid)

$selectedAll = $selections -contains '2'

if ($selectedAll) { $selections = @('1') }
else { $selections = $selections | Select-Object -Unique }

$targets = [System.Collections.Generic.List[hashtable]]::new()
if ($selections -contains '1') {
    $targets.Add(@{
        Label     = "eia-email-reviewer"
        SourceDir = Join-Path $AgentsRoot "eia-email-reviewer"
    })
}

# =============================================================================
# STEP 2: Gather agent instructions
# =============================================================================
Write-Host ""
Write-Host ">>> Step 2: Agent instructions" -ForegroundColor White
Write-Host "[INFO] Instructions become the system prompt registered with the agent in Azure AI Foundry." -ForegroundColor DarkCyan
Write-Host ""

# Keep defaults per agent label. Add a new entry here whenever a new agent is added.
$defaultInstructionsByAgent = @{
    "eia-email-reviewer" = "You are a helpful assistant, who can read user data, detect anomalies, missing data, recommend action items, classify content into a multi-class hierarchy, summarize content, and provide insights."
}

foreach ($target in $targets) {
    $defaultInstruction = $defaultInstructionsByAgent[$target.Label]
    if (-not $defaultInstruction) {
        throw "No default instructions configured for agent '$($target.Label)'. Add it to `$defaultInstructionsByAgent in this script."
    }

    if ($selectedAll) {
        $target.Instructions = $defaultInstruction
        Write-Host "[INFO] '$($target.Label)' selected via 'All' - using default instructions." -ForegroundColor DarkCyan
        continue
    }

    Write-Host "Default instructions for '$($target.Label)':" -ForegroundColor DarkCyan
    Write-Host "  $defaultInstruction" -ForegroundColor Gray

    $instrInput = Read-Host "Press [Enter] to keep default, or type edited instructions"
    $instr = $instrInput.Trim()
    if (-not $instr) {
        $instr = $defaultInstruction
    }

    $target.Instructions = $instr
}

# =============================================================================
# STEP 3: Confirm
# =============================================================================
$confirmRg = Read-Host "Press [Enter] to accept Resource Group '$ResourceGroupName', or type a new name to override"
$confirmRg = $confirmRg.Trim()
if ($confirmRg -ne '') {
    $ResourceGroupName = $confirmRg
    Write-Host "[INFO] Using overridden Resource Group: $ResourceGroupName" -ForegroundColor Cyan
}

Write-Host ""
Write-Host "[INFO] ============================================================" -ForegroundColor Cyan
Write-Host "[INFO] About to provision:"                                            -ForegroundColor Cyan
foreach ($t in $targets) {
    Write-Host "  $($t.Label)" -ForegroundColor Cyan
    Write-Host "    Instructions: $($t.Instructions)" -ForegroundColor DarkCyan
}
Write-Host "  Resource Group : $ResourceGroupName"                                -ForegroundColor Cyan
Write-Host "  Key Vault      : $KeyVaultName"                                     -ForegroundColor Cyan
Write-Host "[INFO] ============================================================" -ForegroundColor Cyan
Write-Host ""

$go = Read-Host "Proceed with provisioning? [Y/n]"
if ($go.Trim() -match '^[Nn]') {
    Write-Host "[INFO] Provisioning cancelled." -ForegroundColor Yellow
    exit 0
}

# =============================================================================
# STEP 4: Resolve Key Vault URL
# =============================================================================
Write-Host ""
Write-Host ">>> Step 4: Resolving Key Vault URL" -ForegroundColor White

$kvUrl = az keyvault show --name $KeyVaultName --resource-group $ResourceGroupName --query properties.vaultUri -o tsv 2>$null
if (-not $kvUrl) {
    Write-Host "[ERROR] Could not retrieve Key Vault '$KeyVaultName' in '$ResourceGroupName'. Verify the name/suffix and that you are logged in." -ForegroundColor Red
    exit 1
}
$kvUrl = $kvUrl.TrimEnd('/')
Write-Host "[OK] Key Vault URL: $kvUrl" -ForegroundColor Green

# =============================================================================
# STEP 5: Build and provision each agent
# =============================================================================
Write-Host ""
Write-Host ">>> Step 5: Build and provision agents" -ForegroundColor White

$javaExe  = Join-Path $env:JAVA_HOME 'bin\java.exe'
if (-not (Test-Path $javaExe)) { $javaExe = 'java' }

$provisionErrors = [System.Collections.Generic.List[string]]::new()

foreach ($target in $targets) {
    $Label        = $target.Label
    $SourceDir    = $target.SourceDir
    $Instructions = $target.Instructions

    Write-Host ""
    Write-Host "[INFO] ---- Agent: $Label ----" -ForegroundColor White

    if (-not (Test-Path $SourceDir)) {
        Write-Host "[ERROR] Source directory not found: $SourceDir" -ForegroundColor Red
        $provisionErrors.Add($Label); continue
    }
    if (-not (Test-Path (Join-Path $SourceDir "pom.xml"))) {
        Write-Host "[ERROR] pom.xml not found in: $SourceDir" -ForegroundColor Red
        $provisionErrors.Add($Label); continue
    }

    # Maven build — -Dlibrary also copies the thin JAR to project-lib/java
    Write-Host "[INFO] Building $Label with Maven..." -ForegroundColor Cyan
    if ($MavenTimeoutMinutes -gt 0) {
        Write-Host "[INFO] Maven timeout: $MavenTimeoutMinutes minute(s)." -ForegroundColor DarkCyan
    } else {
        Write-Host "[INFO] Maven timeout disabled." -ForegroundColor DarkCyan
    }

    try {
        Invoke-MavenPackage `
            -SourceDir $SourceDir -Label $Label `
            -MavenPath $mvn.Source -TimeoutMinutes $MavenTimeoutMinutes `
            -ExtraArgs @('-Dlibrary')
    } catch {
        Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
        $provisionErrors.Add($Label); continue
    }
    Write-Host "[SUCCESS] Maven build completed for $Label" -ForegroundColor Green

    # Locate the executable fat JAR produced by maven-shade-plugin
    $jarFile = Get-ChildItem (Join-Path $SourceDir 'target') -Filter '*-exec.jar' -File |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if (-not $jarFile) {
        Write-Host "[ERROR] Executable JAR (*-exec.jar) not found under $(Join-Path $SourceDir 'target')" -ForegroundColor Red
        $provisionErrors.Add($Label); continue
    }

    $jarHash = Get-ArtifactSha256 -Path $jarFile.FullName
    Write-Host "[INFO] Provisioning with: $($jarFile.Name)$(if ($jarHash) { " (SHA256: $jarHash)" })" -ForegroundColor DarkCyan

    # Run provisioning — main(keyVaultUrl, instructions...)
    Write-Host "[INFO] Registering agent in Azure AI Foundry..." -ForegroundColor Cyan
    & $javaExe -jar $jarFile.FullName $kvUrl $Instructions
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] Provisioning failed for $Label (exit code $LASTEXITCODE)" -ForegroundColor Red
        $provisionErrors.Add($Label); continue
    }
    Write-Host "[SUCCESS] Agent provisioned: $Label" -ForegroundColor Green
}

# =============================================================================
# SUMMARY
# =============================================================================
Write-Host ""
Write-Host "[INFO] ============================================================" -ForegroundColor Cyan
Write-Host "[INFO] Provisioning Summary"                                           -ForegroundColor Cyan
Write-Host "[INFO] ============================================================" -ForegroundColor Cyan

if ($provisionErrors.Count -eq 0) {
    Write-Host "[SUCCESS] All agents provisioned successfully." -ForegroundColor Green
} else {
    Write-Host "[WARNING] The following agents failed to provision:" -ForegroundColor Yellow
    foreach ($err in $provisionErrors) {
        Write-Host "  - $err" -ForegroundColor Red
    }
    exit 1
}

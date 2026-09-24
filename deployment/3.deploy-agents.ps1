#Requires -Version 5.1
<#
.SYNOPSIS
    Builds and provisions Azure AI Foundry agents.
.DESCRIPTION
    Prompts the user to select which agent(s) to provision, gathers the agent
    instructions, builds each JAR with Maven (also updating project-lib/java
    via the copy-to-project-lib profile), then runs the provisioning main()
    to register the agent in Azure AI Foundry.

    Self-sufficient: grants the signed-in user the AI Foundry data-plane roles
    the agents API requires (so it does not depend on 6.operation-dev.ps1).
.PARAMETER Environment
    Optional. Environment name (default: dev).
.PARAMETER Suffix
    Optional. The same suffix used when running deploy-infrastructure.ps1.
.PARAMETER MavenTimeoutMinutes
    Maximum time to allow each Maven build before failing (default: 15).
.PARAMETER WorkerDefinitionsPath
    JSON manifest containing generic worker definitions (default: deployment/multiagent-workers.json).
.USAGE
    .\3.deploy-agents.ps1 -Suffix 999
    .\3.deploy-agents.ps1 -Environment dev -Suffix 999
#>
param(
    [Parameter(HelpMessage="Environment (default: dev, example: dev)")]
    [string]$Environment,

    [Parameter(HelpMessage="Suffix used during infrastructure deployment (default: 1, example: 1)")]
    [string]$Suffix,

    [Parameter(HelpMessage="Maximum time to allow each Maven package run before failing. Use 0 to disable the timeout.")]
    [ValidateRange(0, 1440)]
    [int]$MavenTimeoutMinutes = 15,

    [Parameter(HelpMessage="JSON manifest containing generic multi-agent worker definitions.")]
    [string]$WorkerDefinitionsPath
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
# CONFIGURATION
# =============================================================================
$ResourceGroupName = "rg-$ProjectName-$Environment-$Suffix"
$KeyVaultName      = "kv-$ProjectName-$Environment-$Suffix"
$AiFoundryName        = "oai-$ProjectName-$Environment-$Suffix"
$AiFoundryProjectName = "proj-$ProjectName-$Environment-$Suffix"

$ScriptRoot  = $PSScriptRoot
$RepoRoot    = Split-Path $ScriptRoot -Parent
$AgentsRoot  = Join-Path $RepoRoot "insight\agents"
$JavaCoreRoot = Join-Path $RepoRoot "java-core"
$MultiAgentRoot = Join-Path $RepoRoot "multiagent"
$DefaultWorkerDefinitionsPath = Join-Path $ScriptRoot "multiagent-workers.json"
if ([string]::IsNullOrWhiteSpace($WorkerDefinitionsPath)) {
    $WorkerDefinitionsPath = $DefaultWorkerDefinitionsPath
} elseif (-not [System.IO.Path]::IsPathRooted($WorkerDefinitionsPath)) {
    $WorkerDefinitionsPath = Join-Path $RepoRoot $WorkerDefinitionsPath
}

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

        # Process.ExitCode (and even StartTime/ProcessName) can come back blank on this
        # machine once the process has exited, with no exception raised — the handle
        # loses query rights before we read it. Maven's own "BUILD SUCCESS"/"BUILD
        # FAILURE" banner in the captured output is the reliable signal instead.
        $stdoutText = if (Test-Path $stdoutLog) { Get-Content $stdoutLog -Raw -ErrorAction SilentlyContinue } else { $null }
        if ($stdoutText -match 'BUILD SUCCESS') {
            # Build succeeded regardless of what the process handle reports.
        } elseif ($stdoutText -match 'BUILD FAILURE' -or $process.ExitCode -ne 0) {
            throw "Maven build failed for $Label (exit code: $($process.ExitCode))."
        } else {
            throw "Maven build for $Label ended without a BUILD SUCCESS/BUILD FAILURE marker; treating as failed (exit code: $($process.ExitCode))."
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

function Get-LatestProjectInputTime {
    param([Parameter(Mandatory=$true)][string]$SourceDir)

    $inputs = @()
    $pomPath = Join-Path $SourceDir 'pom.xml'
    if (Test-Path $pomPath) {
        $inputs += Get-Item $pomPath
    }
    $sourcePath = Join-Path $SourceDir 'src'
    if (Test-Path $sourcePath) {
        $inputs += Get-ChildItem $sourcePath -File -Recurse
    }
    if ($inputs.Count -eq 0) {
        return [DateTime]::MinValue
    }
    return ($inputs | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1).LastWriteTimeUtc
}

function Get-ExistingFoundryConnections {
    $subscriptionId = (az account show --query id -o tsv 2>$null).Trim()
    if ([string]::IsNullOrWhiteSpace($subscriptionId)) {
        throw "Could not resolve the active Azure subscription."
    }

    $url = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.CognitiveServices/accounts/$AiFoundryName/projects/$AiFoundryProjectName/connections?api-version=2025-06-01"
    $json = az rest --method get --url $url 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) {
        throw "Could not list existing Foundry project connections. No resources were created."
    }

    $response = $json | ConvertFrom-Json
    return @($response.value | ForEach-Object {
        [pscustomobject]@{
            Name      = [string]$_.name
            Reference = [string]$_.name
            ResourceId = [string]$_.id
            Category  = [string]$_.properties.category
            Target    = [string]$_.properties.target
        }
    } | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Reference) })
}

function Get-ExistingFoundryAgent {
    param([Parameter(Mandatory=$true)][string]$AgentName)

    $projectEndpoint = az keyvault secret show `
        --vault-name $KeyVaultName `
        --name 'AiFoundryProjectEndpoint' `
        --query value -o tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($projectEndpoint)) {
        throw "Could not resolve the Foundry project endpoint from Key Vault."
    }

    $encodedAgentName = [Uri]::EscapeDataString($AgentName)
    $url = "$($projectEndpoint.TrimEnd('/'))/agents/$encodedAgentName`?api-version=v1"
    $accessToken = az account get-access-token `
        --resource 'https://ai.azure.com' `
        --query accessToken -o tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($accessToken)) {
        throw "Could not acquire an Azure AI access token to read Foundry agents."
    }

    try {
        $response = Invoke-RestMethod `
            -Method Get `
            -Uri $url `
            -Headers @{ Authorization = "Bearer $($accessToken.Trim())" } `
            -ErrorAction Stop
    } catch {
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) {
            return $null
        }
        throw "Could not read Foundry agent '$AgentName': $($_.Exception.Message)"
    }

    $definition = $response.versions.latest.definition
    if ($null -eq $definition) {
        return $null
    }

    $tools = @($definition.tools | ForEach-Object {
        if ([string]$_.type -eq 'mcp') {
            New-ToolCatalogEntry `
                -Name ([string]$_.server_label) `
                -Description ([string]$_.server_description) `
                -Reference ([string]$_.project_connection_id) `
                -ServerUrl ([string]$_.server_url)
        }
    })

    return [pscustomobject]@{
        Instructions = [string]$definition.instructions
        Tools = $tools
    }
}

function New-ToolCatalogEntry {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][string]$Description,
        [string]$Reference,
        [string]$ServerUrl
    )
    return [ordered]@{
        name = $Name
        description = $Description
        toolBinding = [ordered]@{
            reference = $Reference
            serverUrl = $ServerUrl
        }
    }
}

# =============================================================================
# STEP 1: Select which agent(s) to provision
# =============================================================================
Write-Host "Which agent(s) do you want to provision?" -ForegroundColor White
Write-Host "  1. eia-email-reviewer"
Write-Host "  2. Multi-Agent System (Orchestrator + Jury)"
Write-Host "  3. Configured generic worker agents"
Write-Host "  4. All"
Write-Host ""
Write-Host "  You can enter a single number or comma-separated list (e.g. 1)" -ForegroundColor DarkCyan
Write-Host ""

$validOptions = @('1','2','3','4')
do {
    $rawInput   = (Read-Host "Enter selection(s)").Trim()
    $selections = $rawInput -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    $allValid   = ($selections.Count -gt 0) -and ($selections | Where-Object { $_ -notin $validOptions }).Count -eq 0
    if (-not $allValid) {
        Write-Host "[ERROR] Please enter 1, 2, 3, 4, or a comma-separated list." -ForegroundColor Red
    }
} while (-not $allValid)

$selectedAll = $selections -contains '4'

if ($selectedAll) { $selections = @('1','2','3') }
else { $selections = $selections | Select-Object -Unique }

$targets = [System.Collections.Generic.List[hashtable]]::new()
if ($selections -contains '1') {
    $targets.Add(@{
        Label     = "eia-email-reviewer"
        SourceDir = Join-Path $AgentsRoot "eia-email-reviewer"
    })
}
if ($selections -contains '2') {
    # Both system agents live in the single `multiagent` Maven module; each has its own
    # static createAgent(String[])/main(String[]) entry point, invoked via `java -cp`
    # (not `-jar`) since the shaded JAR has no single Main-Class for the two of them.
    $targets.Add(@{
        Label     = "multiagent-orchestrator"
        SourceDir = $MultiAgentRoot
        MainClass = "com.eia.multiagent.OrchestratorAgent"
    })
    $targets.Add(@{
        Label     = "multiagent-jury"
        SourceDir = $MultiAgentRoot
        MainClass = "com.eia.multiagent.JuryAgent"
    })
}
if ($selections -contains '3') {
    if (-not (Test-Path $WorkerDefinitionsPath)) {
        throw "Worker definitions manifest not found: $WorkerDefinitionsPath"
    }
    $workerDefinitions = @(Get-Content -Path $WorkerDefinitionsPath -Raw | ConvertFrom-Json)
    foreach ($worker in $workerDefinitions) {
        if ([string]::IsNullOrWhiteSpace($worker.agentType) -or
            [string]::IsNullOrWhiteSpace($worker.instructions)) {
            throw "Each worker definition must contain non-empty 'agentType' and 'instructions': $WorkerDefinitionsPath"
        }
        $targets.Add(@{
            Label        = "multiagent-worker-$($worker.agentType)"
            SourceDir    = $MultiAgentRoot
            MainClass    = "com.eia.multiagent.WorkerAgent"
            AgentType    = [string]$worker.agentType
            Instructions = [string]$worker.instructions
            Tools        = @($worker.tools)
            IsConfigured = $true
        })
    }
    if ($workerDefinitions.Count -eq 0) {
        Write-Host "[WARNING] Worker manifest contains no definitions: $WorkerDefinitionsPath" -ForegroundColor Yellow
    }
}

# Confirm the resource group before querying existing project connections.
$confirmRg = Read-Host "Press [Enter] to accept Resource Group '$ResourceGroupName', or type a new name to override"
$confirmRg = $confirmRg.Trim()
if ($confirmRg -ne '') {
    $ResourceGroupName = $confirmRg
    Write-Host "[INFO] Using overridden Resource Group: $ResourceGroupName" -ForegroundColor Cyan
}

# =============================================================================
# STEP 2: Configure worker instructions and Foundry tool bindings
# =============================================================================
if ($selections -contains '3' -and $workerDefinitions.Count -gt 0) {
    Write-Host ""
    Write-Host ">>> Step 2: Configure worker instructions and tools" -ForegroundColor White
    Write-Host "[INFO] Existing project connections are listed as available Foundry tools." -ForegroundColor DarkCyan
    $existingConnections = @(Get-ExistingFoundryConnections)
    foreach ($worker in $workerDefinitions) {
        $target = $targets | Where-Object { $_.AgentType -eq [string]$worker.agentType } | Select-Object -First 1
        $existingAgent = Get-ExistingFoundryAgent -AgentName ([string]$worker.agentType)
        if ($existingAgent) {
            $worker.instructions = $existingAgent.Instructions
            $worker.tools = @($existingAgent.Tools)
            $target.Instructions = $existingAgent.Instructions
            $target.Tools = @($existingAgent.Tools)
            $target.FoundryExists = $true
        }
        Write-Host ""
        Write-Host "Worker '$($worker.agentType)'" -ForegroundColor White
        if ($existingAgent) {
            Write-Host "[WARNING] This agent already exists in Foundry. Any replacement input or tool changes will overwrite its existing setup." -ForegroundColor Yellow
        }
        $instructionSource = if ($existingAgent) {
            'Current instruction for this existing Agent from Foundry (ignoring instructions in local JSON file)'
        } else {
            'Current instruction from local JSON file (new Foundry agent)'
        }
        Write-Host "$instructionSource`:" -ForegroundColor DarkCyan
        Write-Host "  $($worker.instructions)" -ForegroundColor Gray
        $editedInstructions = (Read-Host "Press [Enter] to keep instructions, or enter replacement text").Trim()
        if ($editedInstructions) {
            $worker.instructions = $editedInstructions
            $target.Instructions = $editedInstructions
        }

        Write-Host "Current configuration:" -ForegroundColor DarkCyan
        if ($existingAgent) {
            Write-Host "  Loaded from the existing Foundry agent definition." -ForegroundColor Gray
        } else {
            Write-Host "  Loaded from the local JSON worker definition." -ForegroundColor Gray
        }

        $configuredTools = [System.Collections.Generic.List[object]]::new()
        foreach ($tool in @($worker.tools)) {
            $toolName = [string]$tool.name
            $toolDescription = [string]$tool.description
            $currentReference = if ($tool.toolBinding) { [string]$tool.toolBinding.reference } else { '' }
            $matchingConnection = $existingConnections |
                Where-Object { $_.Reference -eq $currentReference -or $_.ResourceId -eq $currentReference } |
                Select-Object -First 1
            if ($matchingConnection) {
                $currentReference = $matchingConnection.Reference
            }
            $currentServerUrl = if ($tool.toolBinding) { [string]$tool.toolBinding.serverUrl } else { '' }
            if ($matchingConnection -and -not [string]::IsNullOrWhiteSpace($matchingConnection.Target)) {
                $currentServerUrl = $matchingConnection.Target
            }
            Write-Host ""
            Write-Host "Tool '$toolName'" -ForegroundColor White
            $nameInput = (Read-Host "Tool name [$toolName]").Trim()
            if ($nameInput) { $toolName = $nameInput }
            $descriptionInput = (Read-Host "Tool description [$toolDescription]").Trim()
            if ($descriptionInput) { $toolDescription = $descriptionInput }

            Write-Host "Already bound: $(if ($currentReference) { $currentReference } else { '[none]' })" -ForegroundColor DarkCyan
            Write-Host "Available project tools:" -ForegroundColor DarkCyan
            for ($connectionIndex = 0; $connectionIndex -lt $existingConnections.Count; $connectionIndex++) {
                $connection = $existingConnections[$connectionIndex]
                $boundMarker = if ($connection.Reference -eq $currentReference) { ' [currently bound]' } else { '' }
                Write-Host "  $($connectionIndex + 1). $($connection.Name) [$($connection.Category)] $($connection.Target)$boundMarker" -ForegroundColor Gray
            }
            Write-Host "  0. Keep current binding, or leave unbound" -ForegroundColor Gray
            do {
                $choice = (Read-Host "Select the tool to bind to '$toolName' [0]").Trim()
                if ([string]::IsNullOrWhiteSpace($choice)) { $choice = '0' }
                $validChoice = $choice -match '^\d+$' -and [int]$choice -le $existingConnections.Count
                if (-not $validChoice) {
                    Write-Host "[ERROR] Enter 0 or a listed tool number." -ForegroundColor Red
                }
            } while (-not $validChoice)
            if ([int]$choice -gt 0) { $currentReference = $existingConnections[[int]$choice - 1].Reference }
            if ([string]::IsNullOrWhiteSpace($currentReference)) {
                Write-Host "[INFO] Leaving '$toolName' unbound" -ForegroundColor DarkCyan
            } else {
                Write-Host "[INFO] Binding '$toolName' to project connection '$currentReference'" -ForegroundColor DarkCyan
            }
            $configuredTools.Add((New-ToolCatalogEntry -Name $toolName -Description $toolDescription `
                -Reference $currentReference -ServerUrl $currentServerUrl))
        }
        $worker.tools = @($configuredTools.ToArray())
        $target.Tools = @($configuredTools.ToArray())
    }
}

# =============================================================================
# STEP 3: Gather agent instructions
# =============================================================================
Write-Host ""
Write-Host ">>> Step 3: Agent instructions" -ForegroundColor White
Write-Host "[INFO] Instructions become the system prompt registered with the agent in Azure AI Foundry." -ForegroundColor DarkCyan
Write-Host ""

# Keep defaults per agent label. Add a new entry here whenever a new agent is added.
$defaultInstructionsByAgent = @{
    "eia-email-reviewer"      = "You are a helpful assistant, who can read user data, detect anomalies, missing data, recommend action items, classify content into a multi-class hierarchy, summarize content, and provide insights."
    "multiagent-orchestrator" = "You are the orchestrator of a multi-agent framework. Decompose user requests into a minimal directed task graph, score worker agents against each task from their declared capabilities, and synthesise a clear final answer from task results."
    "multiagent-jury"         = "You are a jury agent. When given a task and two or more competing candidate outputs, decide whether to select one verbatim or merge them into a single, more complete answer, and explain your rationale briefly."
}

foreach ($target in $targets) {
    if ($target.IsConfigured) {
        Write-Host "[INFO] '$($target.Label)' loaded from worker manifest; instructions were configured in Step 2." -ForegroundColor DarkCyan
        continue
    }

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
# STEP 4: Confirm
# =============================================================================
Write-Host ""
Write-Host "[INFO] ============================================================" -ForegroundColor Cyan
Write-Host "[INFO] About to provision:"                                            -ForegroundColor Cyan
foreach ($t in $targets) {
    Write-Host "  $($t.Label)" -ForegroundColor Cyan
    Write-Host "    Instructions: $($t.Instructions)" -ForegroundColor DarkCyan
    foreach ($tool in @($t.Tools)) {
        Write-Host "    Tool: $($tool.name) [$($tool.toolBinding.reference)]" -ForegroundColor DarkCyan
    }
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
# STEP 5: Resolve Key Vault URL
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
# STEP 4b: Ensure current-user AI Foundry RBAC (self-sufficient provisioning)
# =============================================================================
# The provisioner runs as the signed-in user (DefaultAzureCredential) and
# registers the agent via the AI Foundry agents API. These are the data-plane
# roles that API needs, so this script does NOT depend on 6.operation-dev.ps1.
Write-Host ""
Write-Host ">>> Step 4b: Ensuring AI Foundry RBAC for current user" -ForegroundColor White

$CurrentUserId = az ad signed-in-user show --query id -o tsv 2>$null
if (-not $CurrentUserId) {
    Write-Host "[ERROR] Could not determine the signed-in user. Run 'az login' first." -ForegroundColor Red
    exit 1
}
$SubscriptionId = az account show --query id -o tsv 2>$null
$AiFoundryId = az cognitiveservices account show --name $AiFoundryName --resource-group $ResourceGroupName --query id -o tsv 2>$null
$AgentServiceName = "func-agentservice-$ProjectName-$Environment-$Suffix"
$AgentServicePrincipalId = az functionapp identity show --name $AgentServiceName --resource-group $ResourceGroupName --query principalId -o tsv 2>$null
$StorageAccountName = "st$($ProjectName.ToLowerInvariant())$($Environment.ToLowerInvariant())$($Suffix.ToLowerInvariant())"
$StorageAccountId = if ($StorageAccountName) {
    az storage account show --name $StorageAccountName --resource-group $ResourceGroupName --query id -o tsv 2>$null
} else {
    $null
}

# Idempotent role assignment for the signed-in user. Accepts a role name or a
# role-definition ID (custom roles must be referenced by ID at sub-resource scope).
function Add-CurrentUserRole {
    param([string]$RoleNameOrId, [string]$Scope, [string]$Label)
    $existing = az role assignment list --assignee $CurrentUserId --role $RoleNameOrId --scope $Scope --query '[0].id' -o tsv 2>$null
    if ($existing) {
        Write-Host "  [OK] $Label - already assigned" -ForegroundColor Gray
        return
    }
    az role assignment create --assignee $CurrentUserId --role $RoleNameOrId --scope $Scope --output none 2>$null
    Write-Host "  [SUCCESS] $Label - assigned" -ForegroundColor Green
}

if (-not $AiFoundryId) {
    Write-Host "[WARNING] AI Foundry account '$AiFoundryName' not found; skipping RBAC grants. Agent provisioning may fail." -ForegroundColor Yellow
} else {
    $AiFoundryProjectId = "$AiFoundryId/projects/$AiFoundryProjectName"

    # Built-in data-plane roles (account scope) + Agents API access (account + project)
    Add-CurrentUserRole -RoleNameOrId 'Cognitive Services User'        -Scope $AiFoundryId        -Label 'Cognitive Services User (account)'
    Add-CurrentUserRole -RoleNameOrId 'Cognitive Services OpenAI User' -Scope $AiFoundryId        -Label 'Cognitive Services OpenAI User (account)'
    Add-CurrentUserRole -RoleNameOrId 'Azure AI Developer'             -Scope $AiFoundryId        -Label 'Azure AI Developer (account)'
    Add-CurrentUserRole -RoleNameOrId 'Azure AI Developer'             -Scope $AiFoundryProjectId -Label 'Azure AI Developer (project)'

    # Custom role: Azure AI Developer covers OpenAI/* but not the AIServices/*
    # data actions used by the agents endpoint. Create it if absent.
    # Custom role names are tenant-wide. Include the deployment key so a role
    # left behind by another subscription or an earlier failed deployment does
    # not block creation or make the role impossible to resolve here.
    $EiaAgentWriterRole = "EIA AI Foundry Agent Writer $Environment $Suffix"
    $existingCustomRole = az role definition list --name $EiaAgentWriterRole --query '[0].name' -o tsv 2>$null
    if (-not $existingCustomRole) {
        Write-Host "  [INFO] Creating custom role '$EiaAgentWriterRole'" -ForegroundColor Cyan
        $roleJson = [ordered]@{
            Name             = $EiaAgentWriterRole
            Description      = 'Grants AIServices/* data-plane access needed for AI Foundry agents API (AIServices/* absent from Azure AI Developer role definition)'
            Actions          = @()
            DataActions      = @('Microsoft.CognitiveServices/accounts/AIServices/*')
            AssignableScopes = @("/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName")
        } | ConvertTo-Json -Depth 5
        $tmpFile = Join-Path $env:TEMP "eia-custom-role-$([guid]::NewGuid().ToString('N')).json"
        Set-Content -Path $tmpFile -Value $roleJson -Encoding UTF8
        $roleCreateOutput = @(az role definition create --role-definition "@$tmpFile" --output none 2>&1)
        $roleCreateExitCode = $LASTEXITCODE
        Remove-Item $tmpFile -ErrorAction SilentlyContinue
        if ($roleCreateExitCode -ne 0) {
            Write-Host "  [WARNING] Could not create custom role '$EiaAgentWriterRole': $($roleCreateOutput -join ' ')" -ForegroundColor Yellow
        }
    }
    # Resolve by ID — az cannot resolve custom role names at deep sub-resource scopes.
    # Role definitions can take a short time to become visible after creation.
    $EiaAgentWriterRoleId = $null
    for ($attempt = 1; $attempt -le 6 -and -not $EiaAgentWriterRoleId; $attempt++) {
        $EiaAgentWriterRoleId = az role definition list --name $EiaAgentWriterRole --query '[0].id' -o tsv 2>$null
        if (-not $EiaAgentWriterRoleId -and $attempt -lt 6) {
            Start-Sleep -Seconds 5
        }
    }
    if ($EiaAgentWriterRoleId) {
        $EiaAgentWriterRoleId = $EiaAgentWriterRoleId.Trim()
        Add-CurrentUserRole -RoleNameOrId $EiaAgentWriterRoleId -Scope $AiFoundryId        -Label "$EiaAgentWriterRole (account)"
        Add-CurrentUserRole -RoleNameOrId $EiaAgentWriterRoleId -Scope $AiFoundryProjectId -Label "$EiaAgentWriterRole (project)"
        if ($AgentServicePrincipalId) {
            foreach ($scope in @($AiFoundryId, $AiFoundryProjectId)) {
                $existingServiceRole = az role assignment list --assignee-object-id $AgentServicePrincipalId --role $EiaAgentWriterRoleId --scope $scope --query '[0].id' -o tsv 2>$null
                if (-not $existingServiceRole) {
                    az role assignment create --assignee-object-id $AgentServicePrincipalId --assignee-principal-type ServicePrincipal --role $EiaAgentWriterRoleId --scope $scope --output none 2>$null
                }
            }
            Write-Host "  [SUCCESS] $EiaAgentWriterRole assigned to $AgentServiceName (account + project)" -ForegroundColor Green
        } else {
            Write-Host "  [WARNING] Could not resolve managed identity for $AgentServiceName; runtime agent access may fail." -ForegroundColor Yellow
        }
    } else {
        Write-Host "  [WARNING] Could not resolve custom role '$EiaAgentWriterRole'; agent registration may fail." -ForegroundColor Yellow
    }

    Write-Host "  [INFO] RBAC propagation may take up to 5 minutes if roles were just created." -ForegroundColor Cyan
}

if ($StorageAccountId) {
    Add-CurrentUserRole -RoleNameOrId 'Storage Table Data Contributor' -Scope $StorageAccountId -Label 'Storage Table Data Contributor (account)'
} else {
    Write-Host "[WARNING] Storage account for '$ResourceGroupName' could not be resolved; table cleanup may fail." -ForegroundColor Yellow
}

# =============================================================================
# STEP 6: Build and provision each agent
# =============================================================================
Write-Host ""
Write-Host ">>> Step 5: Build and provision agents" -ForegroundColor White

$javaExe  = Join-Path $env:JAVA_HOME 'bin\java.exe'
if (-not (Test-Path $javaExe)) { $javaExe = 'java' }

$provisionErrors = [System.Collections.Generic.List[string]]::new()
$configuredWorkerJar = $null
$configuredWorkerBuildChecked = $false

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

    if ($target.IsConfigured) {
        if (-not $configuredWorkerBuildChecked) {
            $configuredWorkerBuildChecked = $true
            $javaCoreJarPath = Join-Path $JavaCoreRoot 'target\java-core-1.0-SNAPSHOT.jar'
            $javaCoreNeedsBuild = -not (Test-Path $javaCoreJarPath) -or
                ((Get-LatestProjectInputTime -SourceDir $JavaCoreRoot) -gt (Get-Item $javaCoreJarPath).LastWriteTimeUtc)

            if ($javaCoreNeedsBuild) {
                Write-Host "[INFO] java-core changed or is missing; building it once for configured workers..." -ForegroundColor Cyan
                try {
                    Invoke-MavenPackage `
                        -SourceDir $JavaCoreRoot -Label 'java-core' `
                        -MavenPath $mvn.Source -TimeoutMinutes $MavenTimeoutMinutes `
                        -ExtraArgs @('-Dlibrary')
                } catch {
                    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
                    $provisionErrors.Add($Label); continue
                }
            } else {
                Write-Host "[INFO] java-core unchanged; reusing existing JAR." -ForegroundColor DarkCyan
            }

            $multiAgentJarPath = Get-ChildItem (Join-Path $MultiAgentRoot 'target') -Filter '*-exec.jar' -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First 1
            $multiAgentNeedsBuild = $null -eq $multiAgentJarPath -or
                ((Get-LatestProjectInputTime -SourceDir $MultiAgentRoot) -gt $multiAgentJarPath.LastWriteTimeUtc) -or
                ((Get-Item $javaCoreJarPath).LastWriteTimeUtc -gt $multiAgentJarPath.LastWriteTimeUtc)

            if ($multiAgentNeedsBuild) {
                Write-Host "[INFO] multiagent changed or is missing; building it once for configured workers..." -ForegroundColor Cyan
                try {
                    Invoke-MavenPackage `
                        -SourceDir $MultiAgentRoot -Label 'multiagent' `
                        -MavenPath $mvn.Source -TimeoutMinutes $MavenTimeoutMinutes `
                        -ExtraArgs @('-Dlibrary')
                } catch {
                    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
                    $provisionErrors.Add($Label); continue
                }
                $multiAgentJarPath = Get-ChildItem (Join-Path $MultiAgentRoot 'target') -Filter '*-exec.jar' -File |
                    Sort-Object LastWriteTime -Descending |
                    Select-Object -First 1
            } else {
                Write-Host "[INFO] multiagent unchanged; reusing $($multiAgentJarPath.Name)." -ForegroundColor DarkCyan
            }
            $configuredWorkerJar = $multiAgentJarPath
        } else {
            Write-Host "[INFO] Reusing shared multiagent JAR for configured worker '$Label'." -ForegroundColor DarkCyan
        }
        $jarFile = $configuredWorkerJar
    } else {
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
    }

    if (-not $jarFile) {
        Write-Host "[ERROR] Executable JAR (*-exec.jar) not found under $(Join-Path $SourceDir 'target')" -ForegroundColor Red
        $provisionErrors.Add($Label); continue
    }

    $jarHash = Get-ArtifactSha256 -Path $jarFile.FullName
    Write-Host "[INFO] Provisioning with: $($jarFile.Name)$(if ($jarHash) { " (SHA256: $jarHash)" })" -ForegroundColor DarkCyan

    # Run provisioning — main(keyVaultUrl, instructions...)
    Write-Host "[INFO] Registering agent in Azure AI Foundry..." -ForegroundColor Cyan
    if ($target.MainClass -eq "com.eia.multiagent.WorkerAgent") {
        $workerArgs = @($kvUrl, $target.AgentType)
        foreach ($tool in @($target.Tools)) {
            $reference = [string]$tool.toolBinding.reference
            if ([string]::IsNullOrWhiteSpace($reference)) {
                Write-Host "[INFO] Provisioning '$($target.AgentType)' without MCP binding for '$($tool.name)'" -ForegroundColor DarkCyan
                continue
            }
            $serverUrl = [string]$tool.toolBinding.serverUrl
            if ([string]::IsNullOrWhiteSpace($serverUrl)) {
                throw "MCP connection '$reference' for worker '$($target.AgentType)' has no server URL. Re-run this step and select the connection again."
            }
            Write-Host "[INFO] Provisioning '$($target.AgentType)' with MCP connection '$reference'" -ForegroundColor DarkCyan
            $workerArgs += @('--foundry-tool', $reference, [string]$tool.name, [string]$tool.description, $serverUrl)
        }
        $workerArgs += $Instructions
        & $javaExe -cp $jarFile.FullName $target.MainClass $workerArgs
    } elseif ($target.MainClass) {
        # Multi-agent system JAR has no single Main-Class (two agents share one module);
        # invoke the specific agent's static main() explicitly via -cp.
        & $javaExe -cp $jarFile.FullName $target.MainClass $kvUrl $Instructions
    } else {
        & $javaExe -jar $jarFile.FullName $kvUrl $Instructions
    }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] Provisioning failed for $Label (exit code $LASTEXITCODE)" -ForegroundColor Red
        $provisionErrors.Add($Label); continue
    }
    Write-Host "[SUCCESS] Agent provisioned: $Label" -ForegroundColor Green
}

if ($selections -contains '3') {
    $workerManifest = $workerDefinitions | ConvertTo-Json -Depth 10
    $manifestTempFile = [System.IO.Path]::GetTempFileName()
    try {
        Set-Content -Path $manifestTempFile -Value $workerManifest -Encoding UTF8 -NoNewline
        az keyvault secret set --vault-name $KeyVaultName --name 'MultiAgentWorkerDefinitions' --file $manifestTempFile --output none
        if ($LASTEXITCODE -ne 0) {
            throw "Could not publish worker definitions to Key Vault: MultiAgentWorkerDefinitions"
        }
    } finally {
        Remove-Item -Path $manifestTempFile -Force -ErrorAction SilentlyContinue
    }
    Write-Host "[SUCCESS] Published worker definitions to Key Vault. They will register on the next Function App cold start." -ForegroundColor Green
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

if ($selections -contains '3') {
    $restart = Read-Host "Restart Function App '$AgentServiceName' so the new worker is registered now? [Y/n]"
    if ($restart.Trim() -notmatch '^[Nn]') {
        Write-Host "[INFO] Restarting Function App '$AgentServiceName'..." -ForegroundColor Cyan
        az functionapp restart --name $AgentServiceName --resource-group $ResourceGroupName --output none
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[WARNING] Function App restart failed. Restart it manually before using the new worker." -ForegroundColor Yellow
        } else {
            Write-Host "[SUCCESS] Function App restart requested. The new worker will register during cold start." -ForegroundColor Green
        }
    } else {
        Write-Host "[INFO] Function App restart skipped. Restart '$AgentServiceName' before using the new worker." -ForegroundColor Yellow
    }
}

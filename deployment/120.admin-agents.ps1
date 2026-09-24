#Requires -Version 5.1
<##
.SYNOPSIS
    Administration and observability for the multi-agent framework.
.DESCRIPTION
    Lists Key Vault worker definitions, optionally deletes a Foundry prompt-agent
    definition, reports agent call performance, lists orchestration request IDs,
    and renders the task/agent graph for one call.

    Performance and call graphs are sourced from OrchestrationState.taskGraphJson,
    which records the agent types actually invoked for each task. If an older graph
    predates calledAgentTypes, the script reports that observability is unavailable
    for that call rather than guessing.
.PARAMETER Environment
    Environment name (default: dev).
.PARAMETER Suffix
    Deployment suffix (default: 1).
.PARAMETER Action
    list-agents | delete-agent | performance | list-calls | show-call-graph.
.PARAMETER AgentType
    Agent type for delete-agent.
.PARAMETER RequestId
    Orchestration request ID for show-call-graph.
.PARAMETER OutputPath
    Optional path for a Mermaid graph when using show-call-graph.
.PARAMETER SinceDays
    Number of days to include in performance/call reports (default: 30).
.USAGE
    .\120.admin-agents.ps1 -Action list-agents -Suffix 1
    .\120.admin-agents.ps1 -Action performance -Environment dev -Suffix 1
    .\120.admin-agents.ps1 -Action list-calls -SinceDays 7
    .\120.admin-agents.ps1 -Action show-call-graph -RequestId <request-id>
    .\120.admin-agents.ps1 -Action delete-agent -AgentType ClaimsReviewAgent
#>
param(
    [string]$Environment,
    [string]$Suffix,
    [switch]$ListCalls,
    [ValidateSet("list-agents", "delete-agent", "performance", "list-calls", "show-call-graph")]
    [string]$Action = "list-agents",
    [string]$AgentType,
    [string]$RequestId,
    [string]$OutputPath,
    [ValidateRange(1, 3650)]
    [int]$SinceDays = 30
)

$ErrorActionPreference = "Stop"
$ProjectName = "eia"

if ($ListCalls -or ($args -contains '-list-calls')) {
    $Action = "list-calls"
}

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

$ResourceGroupName = "rg-$ProjectName-$Environment-$Suffix"
$KeyVaultName = "kv-$ProjectName-$Environment-$Suffix"
$StorageAccountName = "st$ProjectName$Environment$($Suffix -replace '[^a-zA-Z0-9]', '')"
$AiFoundryName = "oai-$ProjectName-$Environment-$Suffix"
$AiFoundryProjectName = "proj-$ProjectName-$Environment-$Suffix"
$OrchestrationTable = "OrchestrationState"
$AgentServiceName = "func-agentservice-$ProjectName-$Environment-$Suffix"

function Invoke-AzCli {
    param([Parameter(Mandatory=$true)][string[]]$Arguments)
    $output = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "az $($Arguments -join ' ') failed:`n$($output -join "`n")"
    }
    return ($output -join "`n").Trim()
}

function Invoke-AzCliJson {
    param([Parameter(Mandatory=$true)][string[]]$Arguments)
    $raw = Invoke-AzCli ($Arguments + @('--output', 'json'))
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    return $raw | ConvertFrom-Json
}

function Get-Secret {
    param([Parameter(Mandatory=$true)][string]$Name)
    return (Invoke-AzCli @('keyvault', 'secret', 'show', '--vault-name', $KeyVaultName,
            '--name', $Name, '--query', 'value', '--output', 'tsv')).Trim()
}

function Get-TableEntities {
    param([Parameter(Mandatory=$true)][string]$TableName)
    Write-Host "Querying table '$TableName' in storage account '$StorageAccountName'..." -ForegroundColor DarkCyan
    try {
        $tableExists = Invoke-AzCli @('storage', 'table', 'exists', '--account-name', $StorageAccountName,
            '--name', $TableName, '--auth-mode', 'login', '--query', 'exists', '--output', 'tsv')
        if ($tableExists -ne 'true') {
            throw "Table '$TableName' does not exist in storage account '$StorageAccountName'."
        }
        $entities = Invoke-AzCliJson @('storage', 'entity', 'query', '--account-name', $StorageAccountName,
            '--table-name', $TableName, '--auth-mode', 'login')
    } catch {
        throw "Could not read table '$TableName' in storage account '$StorageAccountName'. " +
            "The account may be private-endpoint-only and this machine may not have VNet/DNS access. " +
            "Run this command from a network linked to the storage private DNS zone, or temporarily enable the storage public endpoint. " +
            "Underlying error: $($_.Exception.Message)"
    }
    if ($null -eq $entities) { return @() }
    if ($entities.PSObject.Properties.Name -contains 'items') { return @($entities.items) }
    return @($entities)
}

function Convert-ToArray {
    param($Value)
    if ($null -eq $Value) { return @() }
    if ($Value -is [System.Array]) { return @($Value) }
    return @($Value)
}

function Get-GraphNodes {
    param([Parameter(Mandatory=$true)]$Entity)
    $json = [string]$Entity.taskGraphJson
    if ([string]::IsNullOrWhiteSpace($json)) { return @() }
    try {
        $graph = $json | ConvertFrom-Json
        return @(Convert-ToArray $graph.nodes)
    } catch {
        Write-Warning "Could not parse taskGraphJson for request '$($Entity.RowKey)': $($_.Exception.Message)"
        return @()
    }
}

function Get-RequestId {
    param($Entity)
    if ($Entity.RowKey) { return [string]$Entity.RowKey }
    if ($Entity.rowKey) { return [string]$Entity.rowKey }
    return ""
}

function Get-EntityPartitionKey {
    param($Entity)
    if ($Entity.PartitionKey) { return [string]$Entity.PartitionKey }
    if ($Entity.partitionKey) { return [string]$Entity.partitionKey }
    return ""
}

function Get-EntityProperty {
    param($Entity, [string]$Name)
    $property = $Entity.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    $value = $property.Value
    while ($null -ne $value -and $value.PSObject.Properties.Name -contains 'value') {
        $value = $value.value
    }
    return $value
}

function Get-OrchestrationStates {
    $cutoff = (Get-Date).ToUniversalTime().AddDays(-$SinceDays)
    return @(Get-TableEntities -TableName $OrchestrationTable | Where-Object {
        $updated = Get-EntityProperty $_ 'updatedAt'
        if ($null -eq $updated) { return $true }
        try { return ([DateTimeOffset]::FromUnixTimeMilliseconds([int64]$updated).UtcDateTime -ge $cutoff) }
        catch { return $true }
    })
}

function Format-Epoch {
    param($Value)
    if ($null -eq $Value) { return "" }
    if ($Value.PSObject.Properties.Name -contains 'value') {
        $Value = $Value.value
    }
    try { return ([DateTimeOffset]::FromUnixTimeMilliseconds([int64]$Value)).ToString("u") }
    catch { return [string]$Value }
}

function Show-Agents {
    $orchestratorName = Get-Secret -Name "MultiAgentOrchestratorAgentName"
    $juryName = Get-Secret -Name "MultiAgentJuryAgentName"
    $coreAgents = @(
        [pscustomobject]@{ AgentType = $orchestratorName; Role = "Orchestrator"; Description = "Plans tasks and aggregates worker results" },
        [pscustomobject]@{ AgentType = $juryName; Role = "Jury"; Description = "Resolves tied worker candidates" }
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_.AgentType) }

    foreach ($coreAgent in $coreAgents) {
        Write-Host "Agent: $($coreAgent.AgentType)" -ForegroundColor Cyan
        Write-Host "  Role: $($coreAgent.Role)"
        Write-Host "  Status: Configured in Key Vault; provisioned in Foundry"
        Write-Host "  Description: $($coreAgent.Description)"
        Write-Host ("-" * 80) -ForegroundColor DarkGray
    }

    $manifest = Get-Secret -Name "MultiAgentWorkerDefinitions"
    if ([string]::IsNullOrWhiteSpace($manifest)) {
        Write-Host "No worker definitions found in Key Vault." -ForegroundColor Yellow
        return
    }
    try { $agents = @(ConvertFrom-Json $manifest) }
    catch { throw "MultiAgentWorkerDefinitions is not valid JSON: $($_.Exception.Message)" }
    if ($agents.Count -eq 0) {
        Write-Host "No worker definitions found in Key Vault." -ForegroundColor Yellow
        return
    }
    for ($index = 0; $index -lt $agents.Count; $index++) {
        $agent = $agents[$index]
        Write-Host "Agent: $([string]$agent.agentType)" -ForegroundColor Cyan
        Write-Host "  Status: Configured in Key Vault; loaded locally at Function App startup"
        Write-Host "  Speed: $([string]$agent.speed)"
        Write-Host "  Version: $([string]$agent.version)"
        Write-Host "  Tasks: $(@($agent.tasks) -join '; ')"
        Write-Host "  Tools: $(@($agent.tools | ForEach-Object { $_.name }) -join '; ')"
        if ($index -lt ($agents.Count - 1)) {
            Write-Host ("-" * 80) -ForegroundColor DarkGray
        }
    }
}

function Remove-Agent {
    if ([string]::IsNullOrWhiteSpace($AgentType)) {
        throw "-AgentType is required for -Action delete-agent."
    }
    Write-Warning "This action deletes the Foundry definition only. The Key Vault worker manifest is unchanged."
    $confirmation = Read-Host "Type the agent type '$AgentType' to confirm Foundry deletion"
    if ($confirmation -ne $AgentType) {
        Write-Host "Deletion cancelled." -ForegroundColor Yellow
        return
    }
    Remove-FoundryAgentDefinition -AgentName $AgentType
}

function Remove-FoundryAgentDefinition {
    param([Parameter(Mandatory=$true)][string]$AgentName)
    $projectEndpoint = Get-Secret -Name "AiFoundryProjectEndpoint"
    $apiVersion = "2025-04-01-preview"
    $url = "$projectEndpoint/agents/$([uri]::EscapeDataString($AgentName))?api-version=$apiVersion"
    Write-Host "Attempting to delete Foundry agent definition '$AgentName'..." -ForegroundColor Cyan
    try {
        Invoke-AzCli @('rest', '--method', 'delete', '--url', $url, '--output', 'none') | Out-Null
        Write-Host "Foundry agent definition delete requested for '$AgentName'." -ForegroundColor Green
    } catch {
        Write-Warning "Foundry definition deletion failed or is unsupported by this API version: $($_.Exception.Message)"
        Write-Warning "The Key Vault worker manifest was not changed."
    }
}

function Get-CalledAgentTypes {
    param($Node)
    $value = $Node.calledAgentTypes
    if ($null -eq $value) { return @() }
    return @(Convert-ToArray $value | ForEach-Object { [string]$_ })
}

function Show-Performance {
    $states = Get-OrchestrationStates
    $orchestratorName = ""
    try { $orchestratorName = Get-Secret -Name "MultiAgentOrchestratorAgentName" } catch { }
    $juryName = ""
    try { $juryName = Get-Secret -Name "MultiAgentJuryAgentName" } catch { }

    $calls = @($states | Where-Object { [string](Get-EntityProperty $_ 'status') -in @('COMPLETED','FAILED','EXECUTING','PENDING') })
    $totalOrchestratorCalls = $calls.Count
    $counts = @{}
    if (-not [string]::IsNullOrWhiteSpace($orchestratorName)) {
        $counts[$orchestratorName] = $totalOrchestratorCalls
    }
    if (-not [string]::IsNullOrWhiteSpace($juryName)) {
        $counts[$juryName] = 0
    }
    $callsWithGraphData = 0
    foreach ($call in $calls) {
        $nodes = @(Get-GraphNodes $call)
        $hasData = $false
        foreach ($node in $nodes) {
            foreach ($agent in @(Get-CalledAgentTypes $node)) {
                $hasData = $true
                if (-not $counts.ContainsKey($agent)) { $counts[$agent] = 0 }
                $counts[$agent]++
            }
        }
        if ($hasData) { $callsWithGraphData++ }
    }

    Write-Host "Orchestration calls in the last $SinceDays day(s): $totalOrchestratorCalls" -ForegroundColor Cyan
    Write-Host "Calls with agent invocation telemetry: $callsWithGraphData" -ForegroundColor Cyan
    if ($callsWithGraphData -lt $totalOrchestratorCalls) {
        Write-Warning "Older calls without calledAgentTypes are excluded from agent percentages."
    }
    if ($totalOrchestratorCalls -eq 0) { return }

    $rows = foreach ($agent in ($counts.Keys | Sort-Object)) {
        $isJury = ($agent -eq $juryName) -or ($agent -match '(?i)jury')
        $isOrchestrator = ($agent -eq $orchestratorName) -or ($agent -match '(?i)orchestrator')
        [pscustomobject]@{
            AgentType = $agent
            Category = if ($isJury) { "Jury" } elseif ($isOrchestrator) { "Orchestrator" } else { "Worker" }
            Invocations = $counts[$agent]
            PercentOfOrchestratorCalls = [math]::Round(($counts[$agent] / $totalOrchestratorCalls) * 100, 2)
        }
    }
    $rows | Format-Table -AutoSize
    Write-Host "PercentOfOrchestratorCalls = agent invocations / total orchestration request IDs; jury fan-out and retries count as separate invocations." -ForegroundColor DarkCyan
}

function Show-Calls {
    $states = Get-OrchestrationStates
    if ($states.Count -eq 0) {
        Write-Host "No orchestration calls found in the last $SinceDays day(s)." -ForegroundColor Yellow
        return
    }
    $states | Sort-Object @{Expression={ Get-EntityProperty $_ 'updatedAt' }; Descending=$true} | ForEach-Object {
        [pscustomobject]@{
            RequestId = Get-RequestId $_
            Status = [string](Get-EntityProperty $_ 'status')
            Prompt = [string](Get-EntityProperty $_ 'prompt')
            UpdatedUtc = Format-Epoch (Get-EntityProperty $_ 'updatedAt')
            ExpiresUtc = Format-Epoch (Get-EntityProperty $_ 'expiresAt')
        }
    } | Format-Table -Wrap -AutoSize
}

function Show-CallGraph {
    if ([string]::IsNullOrWhiteSpace($RequestId)) {
        throw "-RequestId is required for -Action show-call-graph."
    }
    $state = @(Get-OrchestrationStates | Where-Object { (Get-RequestId $_) -eq $RequestId }) | Select-Object -First 1
    if ($null -eq $state) { throw "Orchestration request '$RequestId' was not found in the last $SinceDays day(s)." }
    $nodes = @(Get-GraphNodes $state)
    if ($nodes.Count -eq 0) { throw "Request '$RequestId' has no readable taskGraphJson." }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("flowchart TD")
    $lines.Add("  U[Orchestrator call: $RequestId]")
    foreach ($node in $nodes) {
        $taskId = [string]$node.taskId
        $safeTask = ($taskId -replace '[^a-zA-Z0-9_]', '_')
        $description = ([string]$node.description -replace '"', "'")
        $lines.Add("  $safeTask[Task $taskId`: $description]")
        $lines.Add("  U --> $safeTask")
        foreach ($dependency in @(Convert-ToArray $node.dependsOn)) {
            $safeDependency = ([string]$dependency -replace '[^a-zA-Z0-9_]', '_')
            $lines.Add("  $safeDependency --> $safeTask")
        }
        $agents = @(Get-CalledAgentTypes $node)
        if ($agents.Count -eq 0) {
            $lines.Add("  $safeTask -.-> UnknownAgent[Agent: telemetry unavailable]")
        } else {
            $index = 0
            foreach ($agent in $agents) {
                $agentId = "${safeTask}_agent_$index"
                $safeAgent = ([string]$agent -replace '[^a-zA-Z0-9_]', '_')
                $lines.Add("  $agentId[Agent: $safeAgent]")
                $lines.Add("  $safeTask --> $agentId")
                $lines.Add("  $agentId --> U")
                $index++
            }
        }
    }
    $mermaid = $lines -join "`n"
    if ($OutputPath) {
        Set-Content -Path $OutputPath -Value $mermaid -Encoding UTF8
        Write-Host "Mermaid graph written to $OutputPath" -ForegroundColor Green
    } else {
        Write-Host $mermaid -ForegroundColor Cyan
    }
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw "Azure CLI (az) is required." }
$state = Invoke-AzCli @('account', 'show', '--query', 'state', '--output', 'tsv')
if ($state -ne "Enabled") { throw "Azure CLI is not logged in. Run az login first." }

switch ($Action) {
    "list-agents" { Show-Agents }
    "delete-agent" { Remove-Agent }
    "performance" { Show-Performance }
    "list-calls" { Show-Calls }
    "show-call-graph" { Show-CallGraph }
}

#Requires -Version 7.0
<#
.SYNOPSIS
Creates or configures a Fabric data agent, with table selection, testing, and optional publication.
.DESCRIPTION
Uses the current Azure CLI identity. Omit WorkspaceId to select an accessible
workspace. Omit DataSource to select a supported item in that workspace, or pass
an exact item display name or item GUID to skip the data source picker.
Requires Contributor or higher, a supported Fabric capacity, and data-agent tenant
settings. Does not grant permissions. Publication requires explicit confirmation.
Use DraftOnly to create just the source-bound draft. Optional local testing needs
Python 3.10-3.13 and fabric-data-agent-sdk 0.1.33a0 or newer.
.EXAMPLE
./create-fabric-data-agent.ps1
.EXAMPLE
./create-fabric-data-agent.ps1 -DataSource 'InsuranceCustomerBase-ins-1'
.EXAMPLE
./create-fabric-data-agent.ps1 -DataSource '<item-guid>' -WorkspaceId '<workspace-guid>' -AgentName 'InsuranceAssistant'
.LINK
https://learn.microsoft.com/en-us/rest/api/fabric/articles/item-management/definitions/data-agent-definition
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0)]
    [ValidateNotNullOrWhiteSpace()]
    [string]$DataSource,
    [guid]$WorkspaceId = [guid]::Empty,
    [ValidateNotNullOrWhiteSpace()]
    [string]$AgentName,
    [ValidateLength(0, 256)]
    [string]$Description = 'Data agent for querying a Fabric data source.',
    [ValidateNotNullOrWhiteSpace()]
    [string]$Instructions = 'Answer using the configured data source. Do not invent data. Explain when the available data cannot answer a question.',
    [switch]$DraftOnly,
    [ValidateNotNullOrWhiteSpace()]
    [string]$PythonExecutable = 'python'
)

$ErrorActionPreference = 'Stop'

function Invoke-AgentAzureCli {
    param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
    $result = & az @Arguments --only-show-errors --output json
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI failed: $($Arguments[0..1] -join ' '). Sign in with az login and check Fabric access." }
    if ($result) { ($result -join "`n") | ConvertFrom-Json }
}

function Invoke-AgentFabricRequest {
    param([string]$Path, [string]$Method = 'GET', [object]$Body)
    $uri = $null
    if (-not [uri]::TryCreate([uri]'https://api.fabric.microsoft.com/v1/', $Path, [ref]$uri) -or
        $uri.Scheme -ne 'https' -or $uri.Host -ne 'api.fabric.microsoft.com' -or
        $uri.Port -ne 443 -or $uri.UserInfo -or
        -not $uri.AbsolutePath.StartsWith('/v1/', [StringComparison]::Ordinal)) {
        $target = if ($null -ne $uri) { '{0}://{1}:{2}{3}' -f $uri.Scheme, $uri.Host, $uri.Port, $uri.AbsolutePath } else { '[invalid URL]' }
        throw "Unexpected Fabric request URL: $target. Only https://api.fabric.microsoft.com/v1/ is allowed. Check the workspace before rerunning if creation was already submitted."
    }
    $token = Invoke-AgentAzureCli @('account', 'get-access-token', '--resource', 'https://api.fabric.microsoft.com')
    if (-not $token.accessToken) { throw 'Azure CLI did not return a Fabric access token.' }
    $parameters = @{
        Uri = $uri; Method = $Method
        Headers = @{ Authorization = "Bearer $($token.accessToken)" }
        ContentType = 'application/json'; TimeoutSec = 120
        MaximumRedirection = 0
        MaximumRetryCount = $(if ($Method -eq 'GET') { 4 } else { 0 })
        RetryIntervalSec = 5
    }
    if ($null -ne $Body) { $parameters.Body = $Body | ConvertTo-Json -Depth 30 -Compress }
    Invoke-WebRequest @parameters
}

function Invoke-AgentFabric {
    param([string]$Path, [string]$Method = 'GET', [object]$Body, [switch]$NoResult)
    $response = Invoke-AgentFabricRequest $Path $Method $Body
    if ([int]$response.StatusCode -eq 202) {
        $operationIdHeader = [string]($response.Headers.'x-ms-operation-id' | Select-Object -First 1)
        $operationUri = [string]($response.Headers.Location | Select-Object -First 1)
        if ($operationIdHeader) {
            $operationId = [guid]::Empty
            if (-not [guid]::TryParse($operationIdHeader, [ref]$operationId) -or $operationId -eq [guid]::Empty) {
                throw 'Fabric returned an invalid x-ms-operation-id. Check the workspace before rerunning.'
            }
            $operationUri = "https://api.fabric.microsoft.com/v1/operations/$operationId"
        }
        if (-not $operationUri) { throw 'Fabric returned 202 without an operation ID or Location. Check the workspace before rerunning.' }
        for ($attempt = 0; $attempt -lt 60; $attempt++) {
            $delay = 5
            $headerDelay = 0
            if ([int]::TryParse([string]($response.Headers.'Retry-After' | Select-Object -First 1), [ref]$headerDelay)) {
                $delay = [Math]::Clamp($headerDelay, 1, 60)
            }
            Start-Sleep -Seconds $delay
            $operationResponse = Invoke-AgentFabricRequest $operationUri
            $operation = $operationResponse.Content | ConvertFrom-Json
            if ($operation.status -eq 'Succeeded') {
                if ($NoResult) { return }
                $response = Invoke-AgentFabricRequest "$($operationUri.TrimEnd('/'))/result"
                if ($response.Content) { return $response.Content | ConvertFrom-Json }
                throw 'Fabric creation completed without an item result. Check the workspace before rerunning.'
            }
            if ($operation.status -in @('Failed', 'Cancelled')) {
                throw "Fabric operation failed: $($operation | ConvertTo-Json -Depth 10 -Compress)"
            }
            $response = $operationResponse
        }
        throw 'Timed out waiting for Fabric creation. Check the workspace before rerunning.'
    }
    if ($response.Content) { $response.Content | ConvertFrom-Json }
}

function Get-AgentFabricCollection {
    param([string]$Path)
    $visited = [System.Collections.Generic.HashSet[string]]::new()
    do {
        if (-not $visited.Add($Path) -or $visited.Count -gt 1000) { throw 'Invalid Fabric pagination sequence.' }
        $page = Invoke-AgentFabric $Path
        $page.value
        $Path = $page.continuationUri
    } while ($Path)
}

function New-AgentDefinitionPart {
    param([string]$Path, [object]$Value)
    @{
        path = $Path
        payloadType = 'InlineBase64'
        payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($Value | ConvertTo-Json -Depth 30 -Compress)))
    }
}

function Read-AgentConfirmation {
    param([string]$Prompt)
    do {
        $answer = (Read-Host "$Prompt [y/N]").Trim()
        if ($answer -in @('', 'n', 'q')) { return $false }
        if ($answer -eq 'y') { return $true }
        Write-Warning 'Enter Y or N.'
    } while ($true)
}

function Get-AgentTables {
    param([string]$ElementsPath)
    $pending = [System.Collections.Generic.Queue[object]]::new()
    $pending.Enqueue(@{ Path = $ElementsPath; Schema = '' })
    $visited = [System.Collections.Generic.HashSet[string]]::new()
    while ($pending.Count) {
        $parent = $pending.Dequeue()
        foreach ($element in @(Get-AgentFabricCollection $parent.Path)) {
            if ($null -eq $element) { continue }
            if (-not $element.id) { throw 'Fabric returned a schema element without an ID.' }
            if (-not $visited.Add($element.id)) { continue }
            if ($visited.Count -gt 10000) { throw 'Fabric schema traversal exceeded 10000 elements.' }
            if ($element.state -and $element.state -ne 'Available') {
                throw "Cannot read schema element '$($element.displayName)': $($element.state). Check datasource access and synchronization."
            }
            if ($element.type -in @('Table', 'ExternalTable', 'View', 'MaterializedView')) {
                [pscustomobject]@{
                    Id = $element.id
                    Name = $(if ($parent.Schema) { "$($parent.Schema).$($element.displayName)" } else { $element.displayName })
                    IsSelected = [bool]$element.isSelected
                }
            } elseif ($element.hasSubElements -and $element.type -in @('Root', 'Schemas', 'Schema', 'Tables', 'Views', 'MaterializedViews', 'Shortcuts')) {
                $schema = if ($element.type -eq 'Schema') { $element.displayName } else { $parent.Schema }
                $pending.Enqueue(@{ Path = "$ElementsPath`?rootId=$([uri]::EscapeDataString($element.id))"; Schema = $schema })
            }
        }
    }
}

function Invoke-AgentQuickTest {
    param([string]$AgentId, [string]$Question)
    if (-not (Get-Command $PythonExecutable -ErrorAction SilentlyContinue)) {
        throw "Python was not found. Use -PythonExecutable with a Python 3.10-3.13 environment containing fabric-data-agent-sdk >=0.1.33a0."
    }
    $code = @'
import sys
from azure.identity import AzureCliCredential
from fabric.analytics.environment.base.context import InternalContext
from fabric.dataagent.client import FabricOpenAIResponses

with AzureCliCredential() as credential:
    with FabricOpenAIResponses(
        artifact_name=sys.argv[1],
        workspace_name=sys.argv[2],
        credential=credential,
        context=InternalContext(rollout_stage="prod"),
        ai_skill_stage="sandbox",
        timeout=120.0,
        max_retries=0,
    ) as client:
        response = client.responses.create(input=sys.stdin.read())
        if response.status != "completed" or not response.output_text.strip():
            raise RuntimeError("The draft test did not return a completed text answer.")
        print(response.output_text)
'@
    $answer = $Question | & $PythonExecutable -c $code $AgentId "$WorkspaceId"
    if ($LASTEXITCODE -ne 0) {
        throw 'Draft test failed. Check Python 3.10-3.13, fabric-data-agent-sdk >=0.1.33a0, Azure CLI identity, and datasource permissions. Nothing was published.'
    }
    Write-Host ($answer -join "`n")
}

if ($PSBoundParameters.ContainsKey('WorkspaceId') -and $WorkspaceId -eq [guid]::Empty) { throw 'WorkspaceId must not be empty.' }
if ($WhatIfPreference) {
    $null = $PSCmdlet.ShouldProcess("Fabric workspace $WorkspaceId / source $DataSource", 'Create draft data agent')
    return
}
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Install Azure CLI and sign in with az login first.' }
$account = Invoke-AgentAzureCli @('account', 'show')
if ($WorkspaceId -eq [guid]::Empty) {
    $workspaces = @(Get-AgentFabricCollection 'workspaces' | Sort-Object displayName, id)
    if (-not $workspaces.Count) { throw 'No accessible Fabric workspaces were found in the signed-in tenant.' }
    Write-Host "Accessible Fabric workspaces in tenant $($account.tenantId):"
    for ($index = 0; $index -lt $workspaces.Count; $index++) {
        Write-Host ('{0}. {1} [{2}]' -f ($index + 1), $workspaces[$index].displayName, $workspaces[$index].id)
    }
    do {
        $selection = Read-Host 'Select a workspace number (or Q to cancel)'
        if ($selection -eq 'q') { Write-Host 'Workspace selection cancelled. No resources were changed.'; return }
        $selectionNumber = 0
        $validSelection = [int]::TryParse($selection, [ref]$selectionNumber) -and
            $selectionNumber -ge 1 -and $selectionNumber -le $workspaces.Count
        if (-not $validSelection) { Write-Warning "Enter a number from 1 to $($workspaces.Count), or Q to cancel." }
    } until ($validSelection)
    $WorkspaceId = [guid]$workspaces[$selectionNumber - 1].id
    Write-Host "Selected workspace: $($workspaces[$selectionNumber - 1].displayName) [$WorkspaceId]"
}
$workspacePath = "workspaces/$WorkspaceId"
$workspace = Invoke-AgentFabric $workspacePath
if (-not $workspace.capacityId) { throw 'Assign the workspace to a supported Fabric capacity before creating a data agent.' }
$items = @(Get-AgentFabricCollection "$workspacePath/items")
$sourceTypes = @{
    Lakehouse = 'lakehouse'
    Warehouse = 'data_warehouse'
    KQLDatabase = 'kusto'
    SemanticModel = 'semantic_model'
    MirroredDatabase = 'mirrored_database'
}
if (-not $DataSource) {
    $availableSources = @($items | Where-Object { $_ -and $_.type -and $sourceTypes.ContainsKey($_.type) } | Sort-Object displayName, type, id)
    if (-not $availableSources.Count) { throw 'No supported data sources were found in the selected workspace.' }
    Write-Host "Supported data sources in $($workspace.displayName):"
    for ($index = 0; $index -lt $availableSources.Count; $index++) {
        Write-Host ('{0}. {1} ({2}) [{3}]' -f ($index + 1), $availableSources[$index].displayName, $availableSources[$index].type, $availableSources[$index].id)
    }
    do {
        $selection = Read-Host 'Select a data source number (or Q to cancel)'
        if ($selection -eq 'q') { Write-Host 'Data source selection cancelled. No resources were changed.'; return }
        $selectionNumber = 0
        $validSelection = [int]::TryParse($selection, [ref]$selectionNumber) -and
            $selectionNumber -ge 1 -and $selectionNumber -le $availableSources.Count
        if (-not $validSelection) { Write-Warning "Enter a number from 1 to $($availableSources.Count), or Q to cancel." }
    } until ($validSelection)
    $source = $availableSources[$selectionNumber - 1]
    Write-Host "Selected data source: $($source.displayName) [$($source.id)]"
} else {
    $sourceId = [guid]::Empty
    $sources = if ([guid]::TryParse($DataSource, [ref]$sourceId)) {
        @($items | Where-Object id -EQ "$sourceId")
    } else {
        @($items | Where-Object displayName -EQ $DataSource)
    }
    if ($sources.Count -eq 0) { throw "Data source '$DataSource' was not found in workspace $WorkspaceId. Pass its exact Fabric item name or ID, not an Azure SQL database or connection name." }
    if ($sources.Count -ne 1) { throw "Multiple items match '$DataSource'. Rerun with the source item GUID." }
    $source = $sources[0]
}
if (-not $sourceTypes.ContainsKey($source.type)) {
    throw "Unsupported data source type '$($source.type)'. Use a Lakehouse, Warehouse, KQLDatabase, SemanticModel, or MirroredDatabase item."
}
$sourceType = $sourceTypes[$source.type]
if (-not $AgentName) { $AgentName = "fws-da-$($source.displayName)" }
$existing = @($items | Where-Object displayName -EQ $AgentName)
if ($existing.Count) {
    if ($DraftOnly -or $existing.Count -ne 1 -or $existing[0].type -ne 'DataAgent') {
        throw "An item named '$AgentName' already exists. It was not changed. Use a unique DataAgent name or omit DraftOnly to configure an existing agent."
    }
    $agent = $existing[0]
    Write-Host "Data agent '$AgentName' already exists [$($agent.id)]."
    do {
        $existingAction = (Read-Host 'T: test existing draft, C: continue setup using this agent, Q: cancel').Trim()
        if ($existingAction -in @('q', 'n', '')) { return }
        if ($existingAction -in @('c', 'y')) { break }
        if ($existingAction -eq 't') {
            do {
                $question = Read-Host 'Enter a question for the existing draft, or press Enter to finish'
                if ([string]::IsNullOrWhiteSpace($question)) { break }
                Invoke-AgentQuickTest -AgentId $agent.id -Question $question
            } while ($true)
            Write-Host 'Testing finished. No agent configuration or publication was changed.'
            return
        }
        Write-Warning 'Enter T to test, C to continue setup, or Q to cancel.'
    } while ($true)
}
$definition = @{
    parts = @(
        (New-AgentDefinitionPart 'Files/Config/data_agent.json' @{ '$schema' = '2.1.0' })
        (New-AgentDefinitionPart 'Files/Config/draft/stage_config.json' @{ '$schema' = '1.0.0'; aiInstructions = $Instructions })
        (New-AgentDefinitionPart "Files/Config/draft/$sourceType-$($source.id)/datasource.json" @{
            '$schema' = '1.0.0'; artifactId = $source.id; workspaceId = "$WorkspaceId"
            displayName = $source.displayName; type = $sourceType
        })
    )
}
if (-not $PSCmdlet.ShouldProcess("$($workspace.displayName)/$AgentName", "Configure draft data agent for $($source.displayName)")) { return }
if (-not $existing.Count) {
    $agent = Invoke-AgentFabric "$workspacePath/dataAgents" 'POST' @{
        displayName = $AgentName; description = $Description; definition = $definition
    }
}
if (-not $agent.id) { throw 'Fabric did not return the data agent ID. Check the workspace before rerunning.' }
$published = $false
$selectedTables = @()
if (-not $DraftOnly) {
    $agentPath = "$workspacePath/dataAgents/$($agent.id)"
    Write-Host "Configuring draft '$AgentName' [$($agent.id)]. Cancellation leaves any saved draft changes in place."
    $datasources = @(Get-AgentFabricCollection "$agentPath/staging/datasources")
    $matchingSources = @($datasources | Where-Object {
        ($_.itemReference.itemId -eq $source.id -and $_.itemReference.workspaceId -eq "$WorkspaceId") -or
        ($_.lakehouseReference.itemId -eq $source.id -and $_.lakehouseReference.workspaceId -eq "$WorkspaceId")
    })
    if ($matchingSources.Count -gt 1) { throw 'Multiple staged datasources match the source. Resolve the duplicate bindings in Fabric first.' }
    if ($matchingSources.Count -eq 1) { $agentDatasource = $matchingSources[0] }
    else {
        $reference = @{ referenceType = 'ById'; itemId = $source.id; workspaceId = "$WorkspaceId" }
        $body = if ($source.type -eq 'Lakehouse') { @{ type = 'LakehouseTables'; lakehouseReference = $reference } }
            else { @{ type = 'FabricItem'; itemReference = $reference } }
        $agentDatasource = Invoke-AgentFabric "$agentPath/staging/datasources" 'POST' $body
    }
    if (-not $agentDatasource.id) { throw 'Fabric did not return a staged datasource ID. The draft was not published.' }
    $elementsPath = "$agentPath/staging/datasources/$($agentDatasource.id)/elements"
    $tables = @(Get-AgentTables $elementsPath | Sort-Object Name, Id)
    if (-not $tables.Count) { throw 'No available tables or views were found. Check source synchronization and permissions. The draft was not published.' }
    Write-Host 'Available tables and views (* currently selected):'
    for ($index = 0; $index -lt $tables.Count; $index++) {
        Write-Host ('{0}. {1}{2}' -f ($index + 1), $tables[$index].Name, $(if ($tables[$index].IsSelected) { ' *' } else { '' }))
    }
    do {
        $selection = (Read-Host 'Select table numbers separated by commas, A for all, or Q to leave the draft').Trim()
        if ($selection -eq 'q') { Write-Host 'Stopped. The draft was not published.'; return }
        $selectedIndexes = @()
        $validSelection = $true
        if ($selection -eq 'a') { $selectedIndexes = @(1..$tables.Count) }
        else {
            foreach ($value in ($selection -split ',')) {
                $number = 0
                if (-not [int]::TryParse($value.Trim(), [ref]$number) -or $number -lt 1 -or $number -gt $tables.Count) {
                    $validSelection = $false
                    break
                }
                $selectedIndexes += $number
            }
        }
        if (-not $validSelection) { Write-Warning "Select at least one table using numbers 1 to $($tables.Count), A, or Q." }
    } until ($validSelection)
    $selectedIndexes = @($selectedIndexes | Sort-Object -Unique)
    $selectedTables = @($selectedIndexes | ForEach-Object { $tables[$_ - 1].Name })
    Write-Host "Selected: $($selectedTables -join ', '). Table selection includes all columns."
    $settings = Invoke-AgentFabric "$agentPath/staging/settings"
    if (-not $PSBoundParameters.ContainsKey('Instructions')) {
        if ($settings.aiInstructions) { $Instructions = $settings.aiInstructions }
        Write-Host "Current instructions: $Instructions"
        $newInstructions = Read-Host 'Enter replacement instructions, or press Enter to keep them'
        if (-not [string]::IsNullOrWhiteSpace($newInstructions)) { $Instructions = $newInstructions }
    }
    if (-not (Read-AgentConfirmation 'Save these table selections and instructions to the draft?')) { return }
    for ($index = 0; $index -lt $tables.Count; $index++) {
        $null = Invoke-AgentFabric "$elementsPath`?id=$([uri]::EscapeDataString($tables[$index].Id))" 'PATCH' @{
            isSelected = ($selectedIndexes -contains ($index + 1))
        } -NoResult
    }
    $null = Invoke-AgentFabric "$agentPath/staging/settings" 'PATCH' @{ aiInstructions = $Instructions } -NoResult
    Write-Host 'Draft saved. No permissions were changed.'
    $testFailed = $false
    do {
        $question = Read-Host 'Enter a quick-test question, or press Enter to skip/finish testing'
        if ([string]::IsNullOrWhiteSpace($question)) { break }
        try {
            Invoke-AgentQuickTest -AgentId $agent.id -Question $question
            $testFailed = $false
        } catch {
            $testFailed = $true
            Write-Warning $_.Exception.Message
        }
    } while ($true)
    if ($testFailed) { throw 'The last quick test failed. The saved draft was not published. Rerun to retry.' }
    Write-Warning 'Publishing applies ALL pending staging changes for this agent, including other sources. It does not grant users access.'
    if (Read-AgentConfirmation "Publish '$AgentName' now?") {
        if ($PSCmdlet.ShouldProcess("$($workspace.displayName)/$AgentName", 'Publish all staged agent changes')) {
            $null = Invoke-AgentFabric "$agentPath/staging/publish" 'POST' @{ publishedDescription = $Description } -NoResult
            $published = $true
            Write-Host 'Agent published.'
        }
    } else { Write-Host 'Saved as draft. Not published by this run.' }
} else { Write-Host 'Source-bound draft created. Rerun without -DraftOnly to select tables, configure instructions, test, and publish.' }
[pscustomobject]@{
    WorkspaceId = "$WorkspaceId"; DataAgentId = $agent.id; DataAgentName = $agent.displayName
    DataSourceId = $source.id; DataSourceName = $source.displayName; DataSourceType = $source.type
    SelectedTables = $selectedTables
    Published = $published
}
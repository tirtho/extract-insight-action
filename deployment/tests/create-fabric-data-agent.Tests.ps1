#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot '../fabric/create-fabric-data-agent.ps1'
$PSDefaultParameterValues['create-fabric-data-agent.ps1:DraftOnly'] = $true
$parseErrors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
$workspaceId = '11111111-2222-3333-4444-555555555555'
$sourceId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
$state = @{ Calls = @(); Choices = @('bad', '1'); Items = @(); Async = $false; Failure = $false; CliFailure = $false; Poison = $false; Empty = $false }
$state.WorkspaceId = $workspaceId
$state.SourceId = $sourceId
function az {
    $global:LASTEXITCODE = if ($state.CliFailure) { 1 } else { 0 }
    if (-not $state.CliFailure) { '{"tenantId":"test-tenant","accessToken":"offline-token"}' }
}
function Read-Host {
    param($Prompt)
    if (-not $state.Choices.Count) { throw 'Unexpected prompt' }
    $choice = $state.Choices[0]
    $state.Choices = @($state.Choices | Select-Object -Skip 1)
    $choice
}
function Start-Sleep { param($Seconds) }
function Test-AgentPython {
    $state.PythonArguments = @($args)
    $state.TestQuestion = @($input) -join "`n"
    $global:LASTEXITCODE = if ($state.TestFailure) { 1 } else { 0 }
    if (-not $state.TestFailure) { 'There are 10 customers.' }
}
function Invoke-WebRequest {
    param($Uri, $Method, $Headers, $ContentType, $TimeoutSec, $MaximumRetryCount, $RetryIntervalSec, $Body, $MaximumRedirection)
    Assert-True ($Headers.Authorization -eq 'Bearer offline-token' -and $MaximumRedirection -eq 0) 'Missing token or redirect protection.'
    Assert-True ($Uri.Host -eq 'api.fabric.microsoft.com') 'Token sent to untrusted host.'
    $state.Calls += $PSBoundParameters
    $content = switch -Regex ($Uri.PathAndQuery) {
        '^/v1/workspaces$' {
            @{ value = $(if ($state.Empty) { @() } else { @(@{ id = $state.WorkspaceId; displayName = 'Customer workspace' }) }); continuationUri = $(if ($state.Poison) { 'https://example.com/steal' } else { $null }) }; break
        }
        '^/v1/workspaces/[^/]+$' { @{ capacityId = 'capacity'; displayName = 'Customer workspace' }; break }
        '^/v1/workspaces/[^/]+/items$' {
            if ($state.PaginateItems) { @{ value = $state.Items; continuationUri = "https://api.fabric.microsoft.com/v1/workspaces/$($state.WorkspaceId)/items?page=2" } }
            else { @{ value = $(if ($state.NoSources) { $state.Items } else { @(@{ id = $state.SourceId; displayName = 'InsuranceCustomerBase-ins-1'; type = 'MirroredDatabase' }) + $state.Items }) } }
            break
        }
        '^/v1/workspaces/[^/]+/items\?page=2$' { @{ value = @(@{ id = $state.SourceId; displayName = 'InsuranceCustomerBase-ins-1'; type = 'MirroredDatabase' }) }; break }
        '^/v1/workspaces/[^/]+/dataAgents/[^/]+/staging/datasources$' {
            if ($Method -eq 'POST') {
                $payload = $Body | ConvertFrom-Json
                Assert-True ($payload.type -eq 'FabricItem' -and $payload.itemReference.itemId -eq $state.SourceId) 'Wrong staged datasource reference.'
                @{ id = 'bound-source' }
            } else {
                @{ value = $(if ($state.BindingMissing) { @() } else { @(@{ id = 'bound-source'; itemReference = @{ itemId = $state.SourceId; workspaceId = $state.WorkspaceId } }) }) }
            }
            break
        }
        '^/v1/workspaces/[^/]+/dataAgents/[^/]+/staging/datasources/[^/]+/elements' {
            if ($Method -eq 'PATCH') {
                Assert-True ($MaximumRetryCount -eq 0) 'Schema mutations must not retry blindly.'
                $payload = $Body | ConvertFrom-Json
                Assert-True ($payload.isSelected -is [bool]) 'Table selection must be a boolean.'
                @{ id = 'updated' }
            } elseif ($Uri.Query -eq '?rootId=schema%2Fobj%3D') {
                @{ value = @(
                    @{ id = 'table/customer+='; displayName = 'Customer'; type = 'Table'; hasSubElements = $true; isSelected = $false; state = 'Available' }
                    @{ id = 'table/policy'; displayName = 'InsurancePolicy'; type = 'Table'; hasSubElements = $true; isSelected = $true; state = 'Available' }
                ) }
            } elseif ($Uri.Query -eq '?rootId=schemas') {
                @{ value = @(@{ id = 'schema/obj='; displayName = 'obj'; type = 'Schema'; hasSubElements = $true; state = 'Available' }) }
            } elseif ($Uri.Query -eq '?rootId=schemas&page=2') {
                @{ value = @(@{ id = 'schema/obj='; displayName = 'obj'; type = 'Schema'; hasSubElements = $true; state = 'Available' }) }
            } elseif (-not $Uri.Query) {
                @{ value = $(if ($state.NoTables) { @() } else { @(@{ id = 'schemas'; displayName = 'Schemas'; type = 'Schemas'; hasSubElements = $true; state = $(if ($state.SchemaDenied) { 'AccessDenied' } else { 'Available' }) }) }) }
            } else { throw "Unexpected schema query: $Uri" }
            break
        }
        '^/v1/workspaces/[^/]+/dataAgents/[^/]+/staging/settings$' {
            if ($Method -eq 'PATCH') {
                $state.SavedInstructions = ($Body | ConvertFrom-Json).aiInstructions
                if ($state.SaveAsync) { return [pscustomobject]@{ StatusCode = 202; Headers = @{ Location = 'https://api.fabric.microsoft.com/v1/operations/save' }; Content = '' } }
                @{ aiInstructions = $state.SavedInstructions }
            } else { @{ aiInstructions = 'Keep existing instructions.' } }
            break
        }
        '^/v1/workspaces/[^/]+/dataAgents/[^/]+/staging/publish$' {
            Assert-True ($Method -eq 'POST' -and $MaximumRetryCount -eq 0) 'Publishing must not retry blindly.'
            Assert-True (($Body | ConvertFrom-Json).publishedDescription -eq 'Data agent for querying a Fabric data source.') 'Publication description missing.'
            @{ publishedDescription = 'Published' }; break
        }
        '^/v1/workspaces/[^/]+/dataAgents$' {
            Assert-True ($Method -eq 'POST' -and $MaximumRetryCount -eq 0) 'Create must not retry blindly.'
            $payload = $Body | ConvertFrom-Json
            $state.CreatedName = $payload.displayName
            Assert-True ($payload.definition.parts.Count -eq 3) 'Expected draft definition parts.'
            foreach ($part in $payload.definition.parts) {
                $decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($part.payload)) | ConvertFrom-Json
                Assert-True ($part.payloadType -eq 'InlineBase64' -and $decoded.'$schema') 'Invalid definition encoding.'
                if ($part.path.EndsWith('/datasource.json')) {
                    Assert-True ($decoded.artifactId -eq $state.SourceId -and $decoded.workspaceId -eq $state.WorkspaceId -and $decoded.type -eq 'mirrored_database') 'Wrong source binding.'
                }
            }
            if ($state.Async) {
                $responseHeaders = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.IEnumerable[string]]]::new([StringComparer]::OrdinalIgnoreCase)
                $responseHeaders.Add('Location', [string[]]@($(if ($state.LocationOverride) { $state.LocationOverride } else { 'https://api.fabric.microsoft.com/v1/operations/test' })))
                if ($state.OperationId) { $responseHeaders.Add('x-ms-operation-id', [string[]]@($state.OperationId)) }
                return [pscustomobject]@{ StatusCode = 202; Headers = $responseHeaders; Content = '' }
            }
            @{ id = 'agent-id'; displayName = $payload.displayName }; break
        }
        '^/v1/operations/[^/]+$' { @{ status = $(if ($state.Failure) { 'Failed' } else { 'Succeeded' }) }; break }
        '^/v1/operations/[^/]+/result$' { @{ id = 'agent-id'; displayName = $state.CreatedName }; break }
        default { throw "Unexpected API: $Uri" }
    }
    [pscustomobject]@{ StatusCode = 200; Headers = @{}; Content = ($content | ConvertTo-Json -Depth 30 -Compress) }
}
& $scriptPath -DataSource 'test' -WhatIf
& $scriptPath -WhatIf
Assert-True ($state.Calls.Count -eq 0) 'WhatIf made HTTP requests.'
Write-Host 'PASS: Offline WhatIf and parsing.'
$result = & $scriptPath -DataSource 'InsuranceCustomerBase-ins-1'
Assert-True ($result.DataAgentId -eq 'agent-id' -and -not $result.Published -and $state.Choices.Count -eq 0) 'Picker or creation failed.'
Assert-True ($result.DataAgentName -eq 'fws-da-InsuranceCustomerBase-ins-1') 'Default name must use fws-da- followed by the source display name.'
Write-Host 'PASS: Interactive selection retries invalid input and creates source-bound draft.'
$state.Choices = @('1', 'bad', '0', '2', '1')
$state.Items = @(@{ id = 'report-id'; displayName = 'AAA Report'; type = 'Report' })
$state.PaginateItems = $true
$result = & $scriptPath
Assert-True ($result.DataSourceId -eq $state.SourceId -and $result.DataAgentName -eq 'fws-da-InsuranceCustomerBase-ins-1' -and $state.Choices.Count -eq 0) 'Interactive source selection, filtering, or pagination failed.'
Write-Host 'PASS: No arguments selects workspace then supported source across paginated items, retrying invalid input.'
$state.PaginateItems = $false
foreach ($scenario in @('CancelSource', 'NoSources', 'UnsupportedOnly')) {
    $state.Calls = @(); $state.Choices = @('q'); $state.Items = @()
    $state.NoSources = $scenario -ne 'CancelSource'
    if ($scenario -eq 'UnsupportedOnly') { $state.Items = @(@{ id = 'report-id'; displayName = 'Report'; type = 'Report' }) }
    if ($scenario -eq 'CancelSource') { $null = & $scriptPath -WorkspaceId $workspaceId }
    else {
        try { & $scriptPath -WorkspaceId $workspaceId; throw 'Expected failure' }
        catch { Assert-True ($_.Exception.Message -like 'No supported data sources*') "Unexpected $scenario error: $_" }
    }
    Assert-True (@($state.Calls | Where-Object Method -EQ 'POST').Count -eq 0) "$scenario mutated resources."
    Write-Host "PASS: $scenario stops without mutation."
}
function Test-AgentConfigurationWorkflow {
$PSDefaultParameterValues.Remove('create-fabric-data-agent.ps1:DraftOnly')
$state.CliFailure = $false; $state.Poison = $false; $state.Empty = $false; $state.Async = $false
$state.Items = @(@{ id = 'existing-agent'; displayName = 'fws-da-InsuranceCustomerBase-ins-1'; type = 'DataAgent' })
$state.Choices = @('c', '0', '', '1,1', 'Use obj.Customer for customer counts.', 'y', 'How many customers?', '', 'y')
$state.Calls = @(); $state.SaveAsync = $true
$result = & $scriptPath -DataSource $sourceId -WorkspaceId $workspaceId -PythonExecutable Test-AgentPython
Assert-True ($result.DataAgentId -eq 'existing-agent' -and $result.Published -and $result.SelectedTables.Count -eq 1 -and $result.SelectedTables[0] -eq 'obj.Customer') 'Existing-agent table selection or publication failed.'
Assert-True ($state.SavedInstructions -eq 'Use obj.Customer for customer counts.' -and $state.Choices.Count -eq 0) 'Instruction edit or interactive sequence failed.'
$selections = @($state.Calls | Where-Object { $_.Method -eq 'PATCH' -and $_.Uri.AbsolutePath.EndsWith('/elements') })
Assert-True ($selections.Count -eq 2 -and ($selections[0].Body | ConvertFrom-Json).isSelected -and -not ($selections[1].Body | ConvertFrom-Json).isSelected) 'Unchosen tables were not deselected.'
Assert-True ($selections[0].Uri.Query -eq '?id=table%2Fcustomer%2B%3D') 'Opaque element ID was not escaped correctly.'
Assert-True (@($state.Calls | Where-Object { $_.Uri.AbsolutePath.EndsWith('/dataAgents') }).Count -eq 0) 'Existing agent was recreated.'
Assert-True (@($state.Calls | Where-Object { $_.Uri.AbsolutePath.EndsWith('/operations/save/result') }).Count -eq 0) 'Result-free settings update fetched an item result.'
Assert-True ($state.TestQuestion -eq 'How many customers?' -and $state.PythonArguments[1] -like '*ai_skill_stage="sandbox"*' -and $state.PythonArguments[2] -eq 'existing-agent') 'Quick test did not target the selected draft via SDK.'
Write-Host 'PASS: Existing agent, recursive obj tables, invalid choices, deduplication, encoded IDs, instructions, result-free LRO, SDK test, and confirmed publish.'
$state.SaveAsync = $false
foreach ($scenario in @('CancelExisting', 'CancelTables', 'DeclineSave', 'DeclinePublish', 'TestFailure', 'NoTables', 'SchemaDenied', 'AddBinding', 'CreateAndConfigure')) {
    $state.Calls = @(); $state.TestFailure = $scenario -eq 'TestFailure'; $state.NoTables = $scenario -eq 'NoTables'
    $state.SchemaDenied = $scenario -eq 'SchemaDenied'; $state.BindingMissing = $scenario -eq 'AddBinding'
    $state.Items = @(@{ id = 'existing-agent'; displayName = 'fws-da-InsuranceCustomerBase-ins-1'; type = 'DataAgent' })
    switch ($scenario) {
        'CancelExisting' { $state.Choices = @('q') }
        'CancelTables' { $state.Choices = @('y', 'q') }
        'DeclineSave' { $state.Choices = @('y', 'a', 'n') }
        'DeclinePublish' { $state.Choices = @('y', 'a', 'y', '', 'n') }
        'TestFailure' { $state.Choices = @('y', '1', 'y', 'How many customers?', '') }
        'NoTables' { $state.Choices = @('y'); $expected = 'No available tables*' }
        'SchemaDenied' { $state.Choices = @('y'); $expected = '*AccessDenied*' }
        'AddBinding' { $state.Choices = @('y', 'a', 'y', '', 'n') }
        'CreateAndConfigure' { $state.Items = @(); $state.Choices = @('a', 'y', '', 'n') }
    }
    $parameters = @{ DataSource = $sourceId; WorkspaceId = $workspaceId; Instructions = 'Explicit instructions'; PythonExecutable = 'Test-AgentPython' }
    if ($scenario -in @('TestFailure', 'NoTables', 'SchemaDenied')) {
        if ($scenario -eq 'TestFailure') { $expected = 'The last quick test failed*' }
        try { & $scriptPath @parameters; throw 'Expected failure' }
        catch { Assert-True ($_.Exception.Message -like $expected) "Unexpected $scenario error: $_" }
    } else { $result = & $scriptPath @parameters }
    Assert-True (@($state.Calls | Where-Object { $_.Uri.AbsolutePath.EndsWith('/staging/publish') }).Count -eq 0) "$scenario unexpectedly published."
    if ($scenario -in @('CancelExisting', 'CancelTables', 'DeclineSave', 'NoTables', 'SchemaDenied')) {
        Assert-True (@($state.Calls | Where-Object Method -EQ 'PATCH').Count -eq 0) "$scenario changed selections/settings."
    }
    if ($scenario -eq 'AddBinding') {
        Assert-True (@($state.Calls | Where-Object { $_.Method -eq 'POST' -and $_.Uri.AbsolutePath.EndsWith('/staging/datasources') }).Count -eq 1) 'Missing source was not attached.'
    }
    Assert-True ($state.Choices.Count -eq 0) "$scenario did not consume the expected prompts."
    Write-Host "PASS: Workflow $scenario leaves publication unchanged."
}
foreach ($scenario in @('TestExisting', 'FinishExisting', 'FailExisting')) {
    $state.Calls = @(); $state.TestQuestion = $null; $state.PythonArguments = @()
    $state.Items = @(@{ id = 'existing-agent'; displayName = 'fws-da-InsuranceCustomerBase-ins-1'; type = 'DataAgent' })
    $state.TestFailure = $scenario -eq 'FailExisting'
    $state.Choices = switch ($scenario) {
        'TestExisting' { @('invalid', 'T', 'How many customers?', 'How many policies?', '') }
        'FinishExisting' { @('t', '') }
        'FailExisting' { @('t', 'How many customers?') }
    }
    if ($state.TestFailure) {
        try { & $scriptPath -DataSource $sourceId -WorkspaceId $workspaceId -PythonExecutable Test-AgentPython; throw 'Expected failure' }
        catch { Assert-True ($_.Exception.Message -like 'Draft test failed*') "Unexpected test-only failure: $_" }
    } else { $null = & $scriptPath -DataSource $sourceId -WorkspaceId $workspaceId -PythonExecutable Test-AgentPython }
    Assert-True (@($state.Calls | Where-Object Method -NE 'GET').Count -eq 0) "$scenario mutated the agent."
    Assert-True (@($state.Calls | Where-Object { $_.Uri.AbsolutePath -like '*/staging/*' }).Count -eq 0) "$scenario entered configuration."
    if ($scenario -eq 'TestExisting') {
        Assert-True ($state.TestQuestion -eq 'How many policies?' -and $state.PythonArguments[2] -eq 'existing-agent') 'Test-only did not use the existing agent or support repeated questions.'
    }
    if ($scenario -eq 'FinishExisting') { Assert-True ($state.PythonArguments.Count -eq 0) 'Finishing without a question invoked Python.' }
    Assert-True ($state.Choices.Count -eq 0) "$scenario did not consume the expected prompts."
    Write-Host "PASS: $scenario tests only, without configuration or publication."
}
}
$state.NoSources = $false
$state.Items = @()
$state.Async = $true
$result = & $scriptPath -DataSource $sourceId -WorkspaceId $workspaceId -AgentName 'CustomAgent'
Assert-True ($result.DataAgentId -eq 'agent-id') 'Async create failed.'
Assert-True ($result.DataAgentName -eq 'CustomAgent') 'Explicit agent name must be preserved.'
Write-Host 'PASS: Explicit workspace, GUID source, custom name, and async result.'
$result = & $scriptPath -DataSource $sourceId -WorkspaceId $workspaceId
Assert-True ($result.DataAgentName -eq 'fws-da-InsuranceCustomerBase-ins-1') 'GUID sources must resolve the display name for default naming.'
Write-Host 'PASS: GUID source uses resolved display name for the default agent name.'
$state.OperationId = 'bbbbbbbb-1111-2222-3333-444444444444'
$state.LocationOverride = 'https://regional.example.com/v1/operations/ignored?secret=hidden'
$state.Calls = @()
$result = & $scriptPath -DataSource $sourceId -WorkspaceId $workspaceId
Assert-True ($result.DataAgentId -eq 'agent-id' -and @($state.Calls | Where-Object { $_.Uri.AbsolutePath -eq "/v1/operations/$($state.OperationId)" }).Count -eq 1) 'Operation ID must use the canonical Fabric API host.'
Write-Host 'PASS: Real HTTP header collections and operation ID polling ignore noncanonical Location.'
$state.OperationId = '../invalid'
try { & $scriptPath -DataSource $sourceId -WorkspaceId $workspaceId; throw 'Expected failure' }
catch { Assert-True ($_.Exception.Message -like 'Fabric returned an invalid x-ms-operation-id*') 'Invalid operation ID not rejected.' }
$state.OperationId = $null
try { & $scriptPath -DataSource $sourceId -WorkspaceId $workspaceId; throw 'Expected failure' }
catch {
    Assert-True ($_.Exception.Message -like 'Unexpected Fabric request URL:*regional.example.com*' -and $_.Exception.Message -notlike '*secret=hidden*') 'Unsafe Location must fail with sanitized diagnostics.'
}
$state.LocationOverride = $null
Write-Host 'PASS: Invalid operation IDs and untrusted fallback URLs remain rejected without query disclosure.'
$state.Failure = $true
try { & $scriptPath -DataSource $sourceId -WorkspaceId $workspaceId; throw 'Expected failure' }
catch { Assert-True ($_.Exception.Message -like 'Fabric operation failed:*') 'Async failure not surfaced.' }
$state.Failure = $false
Write-Host 'PASS: Async failure stops provisioning.'
foreach ($scenario in @('Missing', 'Duplicate', 'Unsupported', 'Existing', 'Cancel', 'Poison', 'Empty', 'CliFailure')) {
    $state.Calls = @(); $state.Items = @(); $state.Choices = @('q')
    $state.Poison = $scenario -eq 'Poison'; $state.Empty = $scenario -eq 'Empty'; $state.CliFailure = $scenario -eq 'CliFailure'
    $parameters = @{ DataSource = $sourceId; WorkspaceId = $workspaceId }
    switch ($scenario) {
        'Missing' { $parameters.DataSource = 'missing'; $expected = '*was not found*' }
        'Duplicate' { $parameters.DataSource = 'InsuranceCustomerBase-ins-1'; $state.Items = @(@{ id = 'other'; displayName = $parameters.DataSource; type = 'Warehouse' }); $expected = 'Multiple items*' }
        'Unsupported' { $parameters.DataSource = 'Report'; $state.Items = @(@{ id = 'other'; displayName = 'Report'; type = 'Report' }); $expected = 'Unsupported data source type*' }
        'Existing' { $state.Items = @(@{ id = 'other'; displayName = 'fws-da-InsuranceCustomerBase-ins-1'; type = 'DataAgent' }); $expected = '*already exists*' }
        'Cancel' { $parameters.Remove('WorkspaceId') }
        'Poison' { $parameters.Remove('WorkspaceId'); $expected = 'Unexpected Fabric request URL*' }
        'Empty' { $parameters.Remove('WorkspaceId'); $expected = 'No accessible Fabric workspaces*' }
        'CliFailure' { $expected = 'Azure CLI failed:*' }
    }
    if ($scenario -eq 'Cancel') { $null = & $scriptPath @parameters }
    else {
        try { & $scriptPath @parameters; throw 'Expected failure' }
        catch { Assert-True ($_.Exception.Message -like $expected) "Unexpected $scenario error: $_" }
    }
    Assert-True (@($state.Calls | Where-Object Method -EQ 'POST').Count -eq 0) "$scenario mutated resources."
    Write-Host "PASS: $scenario stops without mutation."
}
Test-AgentConfigurationWorkflow
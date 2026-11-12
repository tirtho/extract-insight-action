#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot '../fabric/create-insurance-business-knowledgebase.ps1'
$parseErrors = $null
$tokens = $null
$syntax = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
function Assert-True { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
function az { throw 'WhatIf must not call Azure CLI.' }
function Read-Host { throw 'WhatIf must not prompt.' }
& $scriptPath -WhatIf -Environment ins -Suffix 1
Write-Host 'PASS: Parser and offline WhatIf.'
foreach ($definition in $syntax.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($definition.Extent.Text))
}
$knowledgeSourceName = 'insurance-business-onelake'
$knowledgeBaseName = 'fou-iq-kb-business'
$targetPath = 'InsuranceBusinessKnowledge'
$source = New-KnowledgeSourceDefinition 'bfdbced0-16ef-4af2-b335-8635f8d75af3' '073ecfd3-8b1e-4ef6-a4a2-acb19a32f004'
Assert-True ($source.kind -eq 'indexedOneLake') 'Must use managed OneLake ingestion, not a manually built index.'
Assert-True ($source.indexedOneLakeParameters.targetPath -ceq 'InsuranceBusinessKnowledge') 'Must scope to the current document root.'
Assert-True ($source.indexedOneLakeParameters.ingestionParameters.ingestionSchedule.interval -eq 'PT1H') 'Must refresh incrementally.'
Assert-True ($source.indexedOneLakeParameters.ingestionParameters.contentExtractionMode -eq 'minimal') 'PDF text extraction must not require model deployments.'
$base = New-KnowledgeBaseDefinition
Assert-True ($base.name -ceq 'fou-iq-kb-business' -and $base.knowledgeSources[0].name -eq $source.name) 'Knowledge base name or source binding mismatch.'
$roundTrip = $source | ConvertTo-Json -Depth 20 | ConvertFrom-Json
Assert-True ($roundTrip.indexedOneLakeParameters.fabricWorkspaceId -eq 'bfdbced0-16ef-4af2-b335-8635f8d75af3') 'Workspace must survive JSON serialization.'
Write-Host 'PASS: Managed source, knowledge base naming, source binding, schedule, and JSON contracts.'
$SearchServiceName = 'aais-bzkb-eia-ins-1'
$tokenCache = @{}
foreach ($badUri in @('http://management.azure.com/test', 'https://evil.example/test', 'https://other.search.windows.net/test', 'https://graph.microsoft.com:444/test')) {
    $failed = $false
    try { Invoke-KnowledgeRequest $badUri } catch { $failed = $true }
    Assert-True $failed "Unsafe endpoint accepted: $badUri"
}
Write-Host 'PASS: Request endpoints reject unsafe or unrelated hosts before authentication.'

$workflow = [scriptblock]::Create($syntax.Extent.Text)
$global:KnowledgeTestState = @{}
function az {
    if ($args[0] -eq 'account' -and $args[1] -eq 'show') {
        '{"id":"11111111-1111-1111-1111-111111111111","user":{"type":"user"}}'
    } else { '{"accessToken":"test-token"}' }
    $global:LASTEXITCODE = 0
}
function Read-Host { $global:KnowledgeTestState.Prompts++; return $global:KnowledgeTestState.Answer }
function Start-Sleep { param($Seconds) $global:KnowledgeTestState.Waits++ }
function Invoke-WebRequest {
    param($Uri, $Method, $Headers, $ContentType, $TimeoutSec, $MaximumRedirection, $SkipHttpErrorCheck, $Body)
    $state = $global:KnowledgeTestState
    $address = [uri]$Uri
    $payload = if ($Body) { $Body | ConvertFrom-Json } else { $null }
    $state.Requests.Add(@{ Uri = $Uri; Method = $Method; Body = $payload; Headers = $Headers })
    $content = @{}
    $status = 200
    $responseHeaders = @{}
    switch -Regex ($address.AbsolutePath) {
        '^/bfdbced0-16ef-4af2-b335-8635f8d75af3$' {
            $filePath = '073ecfd3-8b1e-4ef6-a4a2-acb19a32f004/Files/InsuranceBusinessKnowledge/Auto/MA/Compliance/Auto_MA_Compliance.pdf'
            $modified = if ($state.NewerFile) { '2026-11-11T13:00:00Z' } else { '2026-11-11T10:00:00Z' }
            $content = @{ paths = @(@{ name = $filePath; isDirectory = $false; lastModified = $modified }) }
            if ($state.EmptyFiles) { $content.paths = @() }
            if ($state.PaginateFiles -and $address.Query -notmatch 'continuation=') {
                $content.paths = @(@{ name = 'directory'; isDirectory = 'true' })
                $responseHeaders['x-ms-continuation'] = @('page+2/token=')
            }
            if ($state.PaginateFiles -and $address.Query -match 'continuation=') {
                Assert-True ($address.Query.Contains('continuation=page%2B2%2Ftoken%3D')) 'OneLake continuation must be URL encoded.'
            }
            break
        }
        '/indexes/[^/]+/docs/search$' {
            $content = @{ value = @(@{ doc_url = 'https://onelake.blob.fabric.microsoft.com/bfdbced0-16ef-4af2-b335-8635f8d75af3/073ecfd3-8b1e-4ef6-a4a2-acb19a32f004/Files/InsuranceBusinessKnowledge/Auto/MA/Compliance/Auto_MA_Compliance.pdf' }) }
            if ($state.MissingFile) { $content.value = @(@{ doc_url = 'https://onelake.blob.fabric.microsoft.com/unrelated.pdf' }) }
            if ($state.PaginateIndex -and $payload.skip -eq 0) {
                $content.value = @(1..1000 | ForEach-Object { @{ doc_url = 'https://onelake.blob.fabric.microsoft.com/duplicate-chunk.pdf' } })
            }
            break
        }
        '/indexers/[^/]+/status$' {
            $content = @{ status = 'running'; lastResult = @{ status = 'success'; startTime = '2026-11-11T11:59:00Z'; endTime = '2026-11-11T12:00:00Z'; itemsProcessed = 0; itemsFailed = $state.IndexerFailures } }
            if ($state.RunningReads -gt 0) {
                $state.RunningReads--
                $content.lastResult = @{ status = 'inProgress'; startTime = '2026-11-11T11:59:00Z'; itemsProcessed = 10; itemsFailed = 0 }
            }
            break
        }
        '/resourceGroups/rg-eia-ins-1$' { $content = @{ location = 'centralus' }; break }
        '/items$' { $content = @{ value = @(@{ id = '073ecfd3-8b1e-4ef6-a4a2-acb19a32f004'; type = 'Lakehouse'; displayName = 'InsuranceBusinessDocuments' }, @{ id = '22222222-2222-2222-2222-222222222222'; type = 'SQLEndpoint'; displayName = 'InsuranceBusinessDocuments' }) }; break }
        '/items/[^/]+$' { $content = @{ type = 'Lakehouse' }; break }
        '/v1.0/me$' { $content = @{ id = '33333333-3333-3333-3333-333333333333' }; break }
        '/roleAssignments$' {
            if ($Method -eq 'POST') { $state.FabricGrants++ }
            $content = @{ value = @() }
            break
        }
        '/roleAssignments/[^/]+$' { break }
        '/searchServices/[^/]+$' {
            if ($Method -eq 'PUT') { $state.ServiceCreated = $true }
            if (-not $state.ServiceCreated) { $status = 404 } else {
                $content = @{ sku = @{ name = 'basic' }; properties = @{ provisioningState = 'succeeded'; publicNetworkAccess = 'enabled' }; identity = @{ principalId = '44444444-4444-4444-4444-444444444444' } }
                if ($state.ProvisioningPendingReads -gt 0) {
                    $state.ProvisioningPendingReads--
                    $content.properties.provisioningState = 'provisioning'
                    $content.properties.status = 'provisioning'
                    $content.properties.statusDetails = 'Capacity allocation in progress'
                }
                if ($state.ProvisioningFailure) { $content.properties.provisioningState = 'failed' }
            }
            break
        }
        '/knowledgesources$' {
            if ($state.Throttle) { $state.Throttle = $false; $status = 403 }
            break
        }
        '/knowledgesources/[^/]+/status$' {
            $content = @{ synchronizationStatus = 'active'; lastSynchronizationState = @{ endTime = '2026-11-11T12:00:00Z'; itemsUpdatesProcessed = 450; itemsUpdatesFailed = $state.IngestionFailures; itemsSkipped = 0 } }
            if ($state.PendingIngestion) {
                $state.PendingIngestion = $false
                $content.currentSynchronizationState = @{ startTime = '2026-11-11T11:59:00Z'; itemsUpdatesProcessed = 10; itemsUpdatesFailed = 0 }
                if ($state.HistoricalFailure) { $content.lastSynchronizationState.itemsUpdatesFailed = 1 }
            }
            break
        }
        '/knowledgesources/[^/]+$' {
            if ($Method -eq 'GET') {
                if ($state.Source) { $content = $state.Source } else { $status = 404 }
            } else {
                $payload.indexedOneLakeParameters | Add-Member -NotePropertyName createdResources -NotePropertyValue @{ indexer = 'insurance-business-onelake-indexer'; index = 'insurance-business-onelake-index' }
                $state.Source = $payload; $content = $payload
                Assert-True ($Headers['If-None-Match'] -eq '*') 'Source creation must be conditional.'
            }
            break
        }
        '/knowledgebases/[^/]+$' {
            if ($Method -eq 'GET') {
                if ($state.Base) { $content = $state.Base } else { $status = 404 }
            } else {
                $state.Base = $payload; $content = $payload
                Assert-True ($Headers['If-None-Match'] -eq '*') 'Base creation must be conditional.'
            }
            break
        }
        default { throw "Unexpected request $Method $Uri" }
    }
    @{ StatusCode = $status; Content = ($content | ConvertTo-Json -Depth 30); Headers = $responseHeaders }
}
function Invoke-TestKnowledgeWorkflow {
    param([hashtable]$Extra = @{})
    $parameters = @{ Environment = 'ins'; Suffix = '1'; WorkspaceId = 'bfdbced0-16ef-4af2-b335-8635f8d75af3'; GrantFabricAccess = $true }
    foreach ($key in $Extra.Keys) { $parameters[$key] = $Extra[$key] }
    & $workflow @parameters
}
$global:KnowledgeTestState = @{ Requests = [Collections.Generic.List[object]]::new(); Prompts = 0; Answer = ''; Waits = 0; Throttle = $true; FabricGrants = 0; IngestionFailures = 0; PendingIngestion = $true }
$result = Invoke-TestKnowledgeWorkflow
Assert-True ($result.VerifiedFileCount -eq 1) 'Default monitoring must verify actual file URLs, not incremental processed counts.'
Assert-True ($result.KnowledgeBaseName -eq 'fou-iq-kb-business' -and $result.SearchServiceName -eq 'aais-bzkb-eia-ins-1') 'Default naming failed.'
Assert-True ($global:KnowledgeTestState.Waits -eq 2 -and $global:KnowledgeTestState.FabricGrants -eq 1) 'RBAC readiness, ingestion completion, or explicit Fabric grant failed.'
Assert-True ($global:KnowledgeTestState.Source.indexedOneLakeParameters.lakehouseId -eq '073ecfd3-8b1e-4ef6-a4a2-acb19a32f004') 'Must ignore same-name SQL endpoint.'
Write-Host 'PASS: Full mocked provisioning, naming prompt, lakehouse selection, managed identity, roles, RBAC propagation and ingestion status.'
$global:KnowledgeTestState.ProvisioningPendingReads = 63
$waitsBefore = $global:KnowledgeTestState.Waits
$null = Invoke-TestKnowledgeWorkflow
Assert-True (($global:KnowledgeTestState.Waits - $waitsBefore) -gt 60) 'Provisioning must support services that take longer than the old ten-minute limit.'
$global:KnowledgeTestState.ProvisioningPendingReads = 10
$failed = $false
try { $null = Invoke-TestKnowledgeWorkflow @{ ProvisioningTimeoutMinutes = 1 } } catch {
    $failed = $_.Exception.Message -like '*timed out*' -and $_.Exception.Message -like '*Capacity allocation in progress*' -and $_.Exception.Message -like '*resource was not deleted*'
}
Assert-True $failed 'Provisioning timeout must report the last service state and safe rerun guidance.'
$global:KnowledgeTestState.ProvisioningPendingReads = 0
$global:KnowledgeTestState.ProvisioningFailure = $true
$waitsBefore = $global:KnowledgeTestState.Waits
$failed = $false
try { $null = Invoke-TestKnowledgeWorkflow } catch { $failed = $_.Exception.Message -like '*Search provisioning failed*' }
Assert-True ($failed -and $global:KnowledgeTestState.Waits -eq $waitsBefore) 'Terminal provisioning failures must stop immediately.'
$global:KnowledgeTestState.ProvisioningFailure = $false
Write-Host 'PASS: Slow provisioning, configurable timeout diagnostics, and terminal failure handling.'
$global:KnowledgeTestState.Requests.Clear()
$null = Invoke-TestKnowledgeWorkflow
Assert-True (@($global:KnowledgeTestState.Requests | Where-Object { $_.Method -eq 'PUT' -and $_.Uri -match '/(knowledgesources|knowledgebases|searchServices)/[^/?]+\?' }).Count -eq 0) 'Matching resources must not be overwritten.'
$global:KnowledgeTestState.Source.indexedOneLakeParameters.fabricWorkspaceId = '<redacted>'
$global:KnowledgeTestState.Requests.Clear()
$result = Invoke-TestKnowledgeWorkflow
Assert-True ($result.VerifiedFileCount -eq 1) 'A redacted workspace must reuse the exact lakehouse verified by Fabric in the selected workspace.'
Assert-True (@($global:KnowledgeTestState.Requests | Where-Object { $_.Method -eq 'PUT' -and $_.Uri -match '/(knowledgesources|knowledgebases|searchServices)/[^/?]+\?' }).Count -eq 0) 'Redacted workspace reuse must not overwrite existing resources.'
$global:KnowledgeTestState.Source.indexedOneLakeParameters.lakehouseId = '22222222-2222-2222-2222-222222222222'
$failed = $false
try { $null = Invoke-TestKnowledgeWorkflow } catch { $failed = $_.Exception.Message -like '*different data*' }
Assert-True $failed 'A redacted workspace must not allow a different lakehouse.'
$global:KnowledgeTestState.Source.indexedOneLakeParameters.lakehouseId = '073ecfd3-8b1e-4ef6-a4a2-acb19a32f004'
foreach ($invalidWorkspace in @('22222222-2222-2222-2222-222222222222', '')) {
    $global:KnowledgeTestState.Source.indexedOneLakeParameters.fabricWorkspaceId = $invalidWorkspace
    $failed = $false
    try { $null = Invoke-TestKnowledgeWorkflow } catch { $failed = $_.Exception.Message -like '*different data*' -and $_.Exception.Message -like '*Expected kind=*' }
    Assert-True $failed 'A visible conflicting or missing workspace must still be rejected with scope diagnostics.'
}
$global:KnowledgeTestState.Source.indexedOneLakeParameters.fabricWorkspaceId = '<REDACTED>'
$global:KnowledgeTestState.Source.indexedOneLakeParameters.targetPath = 'Knowledge'
$failed = $false
try { $null = Invoke-TestKnowledgeWorkflow } catch { $failed = $_.Exception.Message -like '*different data*' }
Assert-True $failed 'Mismatched knowledge sources must be rejected.'
Write-Host 'PASS: Safe reuse, redacted-workspace handling, and conflicting-source protection.'
$global:KnowledgeTestState.Answer = 'Q'
$global:KnowledgeTestState.Requests.Clear()
$null = Invoke-TestKnowledgeWorkflow
Assert-True ($global:KnowledgeTestState.Requests.Count -eq 0) 'Cancellation must precede cloud requests.'
$global:KnowledgeTestState.Answer = 'custom-business-search'
$global:KnowledgeTestState.Source = $null
$global:KnowledgeTestState.Base = $null
$result = Invoke-TestKnowledgeWorkflow
Assert-True ($result.SearchServiceName -eq 'custom-business-search') 'Name override prompt failed.'
$global:KnowledgeTestState.IngestionFailures = 1
$failed = $false
try { $null = Invoke-TestKnowledgeWorkflow @{ WaitForIngestion = $true } } catch { $failed = $_.Exception.Message -like '*did not fully succeed*' }
Assert-True $failed 'Partial ingestion must not be reported as complete.'
Write-Host 'PASS: Cancellation, name override, and partial-ingestion failure reporting.'
$global:KnowledgeTestState.IngestionFailures = 0
$global:KnowledgeTestState.Requests.Clear()
$global:KnowledgeTestState.RunningReads = 1
$global:KnowledgeTestState.PendingIngestion = $true
$global:KnowledgeTestState.HistoricalFailure = $true
$waitsBefore = $global:KnowledgeTestState.Waits
$result = Invoke-TestKnowledgeWorkflow
Assert-True ($result.VerifiedFileCount -eq 1 -and $global:KnowledgeTestState.Waits -gt $waitsBefore) 'An existing active run must be monitored despite an older failed run.'
Assert-True (@($global:KnowledgeTestState.Requests | Where-Object {
    ($_.Method -eq 'PUT' -and $_.Uri -match '/(knowledgesources|knowledgebases|searchServices|indexers|indexes)/[^/?]+\?') -or
    ($_.Method -ne 'GET' -and $_.Uri -match '/indexers/')
}).Count -eq 0) 'Rerunning must not duplicate, restart, reset, or overwrite managed resources.'
Write-Host 'PASS: Active resource reuse, historical failure recovery, and no indexer mutations.'
$global:KnowledgeTestState.PaginateFiles = $true
$global:KnowledgeTestState.PaginateIndex = $true
$result = Invoke-TestKnowledgeWorkflow
Assert-True ($result.VerifiedFileCount -eq 1) 'Coverage must follow OneLake and Search pages and deduplicate chunks.'
$global:KnowledgeTestState.PaginateFiles = $false
$global:KnowledgeTestState.PaginateIndex = $false
Write-Host 'PASS: OneLake continuation, directory exclusion, Search pagination, and distinct source coverage.'
foreach ($scenario in @('MissingFile', 'NewerFile')) {
    $global:KnowledgeTestState[$scenario] = $true
    $failed = $false
    try { $null = Invoke-TestKnowledgeWorkflow @{ IngestionTimeoutMinutes = 1 } } catch {
        $failed = $_.Exception.Message -like '*Ingestion wait timed out*' -and $_.Exception.Message -like '*left unchanged*'
    }
    Assert-True $failed "$scenario must time out without claiming completion or restarting the indexer."
    $global:KnowledgeTestState[$scenario] = $false
}
Write-Host 'PASS: Missing indexed files and uploads newer than the last run prevent completion.'
$global:KnowledgeTestState.IndexerFailures = 1
$failed = $false
try { $null = Invoke-TestKnowledgeWorkflow } catch { $failed = $_.Exception.Message -like '*Indexer did not fully succeed*' }
Assert-True $failed 'A successful indexer status with failed items must not count as complete.'
$global:KnowledgeTestState.IndexerFailures = 0
$global:KnowledgeTestState.EmptyFiles = $true
$failed = $false
try { $null = Invoke-TestKnowledgeWorkflow } catch { $failed = $_.Exception.Message -like '*No files found*' }
Assert-True $failed 'An empty source must not produce a false completion claim.'
$global:KnowledgeTestState.EmptyFiles = $false
$result = Invoke-TestKnowledgeWorkflow @{ WaitForIngestion = $false }
Assert-True ($null -eq $result.VerifiedFileCount) 'Explicit submission-only mode must not claim verified coverage.'
Write-Host 'PASS: Indexer partial failures, empty sources, and explicit monitoring opt-out.'
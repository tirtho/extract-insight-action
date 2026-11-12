#Requires -Version 7.0
<#
.SYNOPSIS
Creates a Foundry IQ knowledge base with managed OneLake ingestion.
.DESCRIPTION
Uses the Azure CLI login, Azure AI Search Basic or higher, and the stable
2026-04-01 Search API. Search manages PDF text extraction, chunking, and indexing.
Uses extractive retrieval without embedding or chat model deployments.
Existing resources are reused only when their configuration matches.
Fabric Contributor access is requested explicitly before it is granted.
.EXAMPLE
./create-insurance-business-knowledgebase.ps1 -Environment ins -Suffix 1 -WorkspaceId bfdbced0-16ef-4af2-b335-8635f8d75af3
.LINK
https://learn.microsoft.com/azure/search/agentic-knowledge-source-how-to-onelake
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidatePattern('^[a-z0-9]+$')][string]$Environment = 'dev',
    [ValidatePattern('^[a-z0-9]+$')][string]$Suffix = '1',
    [string]$ResourceGroupName,
    [guid]$SubscriptionId = [guid]::Empty,
    [guid]$WorkspaceId = [guid]::Empty,
    [guid]$LakehouseId = [guid]::Empty,
    [string]$SearchServiceName,
    [string]$Location,
    [ValidateSet('basic', 'standard', 'standard2', 'standard3')][string]$Sku = 'basic',
    [guid]$CallerObjectId = [guid]::Empty,
    [switch]$GrantFabricAccess,
    [switch]$WaitForIngestion = $true,
    [ValidateRange(1, 120)][int]$ProvisioningTimeoutMinutes = 30,
    [ValidateRange(1, 120)][int]$IngestionTimeoutMinutes = 30
)

$ErrorActionPreference = 'Stop'
$knowledgeBaseName = 'fou-iq-kb-business'
$knowledgeSourceName = 'insurance-business-onelake'
$targetPath = 'InsuranceBusinessKnowledge'
$searchApiVersion = '2026-04-01'
$tokenCache = @{}

function Invoke-KnowledgeCli {
    param([string[]]$Arguments)
    $result = & az @Arguments --only-show-errors --output json
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI failed: $($Arguments[0..1] -join ' '). Check az login." }
    if ($result) { ($result -join "`n") | ConvertFrom-Json }
}

function Invoke-KnowledgeRequest {
    param([string]$Uri, [string]$Method = 'GET', [object]$Body, [hashtable]$ExtraHeaders = @{}, [switch]$AllowNotFound, [ref]$ResponseHeaders)
    $address = [uri]$Uri
    $audience = switch ($address.Host) {
        'management.azure.com' { 'https://management.azure.com/' }
        'api.fabric.microsoft.com' { 'https://api.fabric.microsoft.com' }
        'graph.microsoft.com' { 'https://graph.microsoft.com/' }
        'onelake.dfs.fabric.microsoft.com' { 'https://storage.azure.com/' }
        default {
            if ($address.Host -cne "$SearchServiceName.search.windows.net") { throw 'Unexpected request host.' }
            'https://search.azure.com'
        }
    }
    if ($address.Scheme -ne 'https' -or $address.Port -ne 443 -or $address.UserInfo -or $address.Fragment) {
        throw 'Only public Azure HTTPS endpoints without redirects are supported.'
    }
    if (-not $tokenCache.ContainsKey($audience) -or $tokenCache[$audience].RefreshAt -lt [datetime]::UtcNow) {
        $token = Invoke-KnowledgeCli @('account', 'get-access-token', '--resource', $audience, '--subscription', "$SubscriptionId")
        if (-not $token.accessToken) { throw "No access token for $audience." }
        $tokenCache[$audience] = @{ Value = $token.accessToken; RefreshAt = [datetime]::UtcNow.AddMinutes(5) }
    }
    $headers = @{ Authorization = "Bearer $($tokenCache[$audience].Value)"; Prefer = 'return=representation' }
    foreach ($key in $ExtraHeaders.Keys) { $headers[$key] = $ExtraHeaders[$key] }
    $parameters = @{
        Uri = $Uri; Method = $Method; Headers = $headers; ContentType = 'application/json'
        TimeoutSec = 120; MaximumRedirection = 0; SkipHttpErrorCheck = $true
    }
    if ($null -ne $Body) { $parameters.Body = $Body | ConvertTo-Json -Depth 30 -Compress }
    $response = Invoke-WebRequest @parameters
    $status = [int]$response.StatusCode
    if ($AllowNotFound -and $status -eq 404) { return $null }
    if ($status -lt 200 -or $status -ge 300) {
        throw "HTTP $status for $Method $($address.AbsolutePath): $($response.Content)"
    }
    if ($ResponseHeaders) { $ResponseHeaders.Value = $response.Headers }
    if ($response.Content) { return $response.Content | ConvertFrom-Json }
}

function Get-KnowledgeFiles {
    $directory = "$LakehouseId/Files/$targetPath"
    $listUri = "https://onelake.dfs.fabric.microsoft.com/${WorkspaceId}?resource=filesystem&recursive=true&directory=$([uri]::EscapeDataString($directory))&maxResults=5000"
    $continuation = ''
    $visited = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    do {
        $pageUri = $listUri
        if ($continuation) { $pageUri += "&continuation=$([uri]::EscapeDataString($continuation))" }
        $responseHeaders = $null
        $page = Invoke-KnowledgeRequest $pageUri -ResponseHeaders ([ref]$responseHeaders)
        foreach ($file in $page.paths) {
            if ($file.isDirectory -in @($true, 'true')) { continue }
            if (-not $file.name.StartsWith("$directory/", [StringComparison]::Ordinal)) { throw 'OneLake returned a file outside the selected folder.' }
            if (-not $file.lastModified) { throw "OneLake did not return lastModified for $($file.name)." }
            [pscustomobject]@{ Path = "/$WorkspaceId/$($file.name)"; LastModified = [datetimeoffset]::Parse($file.lastModified) }
        }
        $continuation = ($responseHeaders['x-ms-continuation'] -join '')
        if ($continuation -and (-not $visited.Add($continuation) -or $visited.Count -gt 1000)) { throw 'Invalid OneLake pagination sequence.' }
    } while ($continuation)
}

function Get-KnowledgeIndexedPaths {
    param([string]$IndexName)
    $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $skip = 0
    do {
        $page = Invoke-KnowledgeRequest "$searchRoot/indexes/$IndexName/docs/search?api-version=$searchApiVersion" 'POST' @{
            search = '*'; select = 'doc_url'; orderby = 'uid asc'; top = 1000; skip = $skip
        }
        foreach ($document in $page.value) {
            $documentUri = $null
            if ([uri]::TryCreate($document.doc_url, [UriKind]::Absolute, [ref]$documentUri) -and
                $documentUri.Scheme -eq 'https' -and $documentUri.Host -in @('onelake.blob.fabric.microsoft.com', 'onelake.dfs.fabric.microsoft.com')) {
                $null = $paths.Add([uri]::UnescapeDataString($documentUri.AbsolutePath))
            }
        }
        $skip += @($page.value).Count
        if ($skip -ge 100000) { throw 'Coverage verification reached the Search paging limit; no completion claim was made.' }
    } while (@($page.value).Count -eq 1000)
    return ,$paths
}

function Get-KnowledgeFabricCollection {
    param([string]$Path)
    $visited = [Collections.Generic.HashSet[string]]::new()
    do {
        $address = [uri]$Path
        if ($address.Host -ne 'api.fabric.microsoft.com' -or -not $address.AbsolutePath.StartsWith('/v1/')) {
            throw 'Unexpected Fabric pagination URL.'
        }
        if (-not $visited.Add($Path) -or $visited.Count -gt 1000) { throw 'Invalid Fabric pagination sequence.' }
        $page = Invoke-KnowledgeRequest $Path
        $page.value
        $Path = $page.continuationUri
    } while ($Path)
}

function New-KnowledgeSourceDefinition {
    param([guid]$FabricWorkspaceId, [guid]$FabricLakehouseId)
    @{
        name = $knowledgeSourceName; kind = 'indexedOneLake'
        description = 'Auto, Home, and Business insurance guidelines, compliance, and regulatory review documents.'
        indexedOneLakeParameters = @{
            fabricWorkspaceId = "$FabricWorkspaceId"; lakehouseId = "$FabricLakehouseId"; targetPath = $targetPath
            ingestionParameters = @{
                contentExtractionMode = 'minimal'; disableImageVerbalization = $true
                ingestionSchedule = @{ interval = 'PT1H' }
            }
        }
    }
}

function New-KnowledgeBaseDefinition {
    @{
        name = $knowledgeBaseName
        description = 'Insurance business documents. Regulatory items are unverified review tasks, not verified legal requirements.'
        knowledgeSources = @(@{ name = $knowledgeSourceName })
    }
}

function Grant-KnowledgeSearchRole {
    param([string]$Scope, [guid]$PrincipalId, [string]$RoleId, [string]$PrincipalType)
    $roleDefinitionId = "/subscriptions/$SubscriptionId/providers/Microsoft.Authorization/roleDefinitions/$RoleId"
    $existing = Invoke-KnowledgeRequest "https://management.azure.com$Scope/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&`$filter=atScope()"
    if (@($existing.value | Where-Object { $_.properties.principalId -eq "$PrincipalId" -and $_.properties.roleDefinitionId -eq $roleDefinitionId }).Count) { return }
    $bytes = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes("$Scope/$PrincipalId/$RoleId".ToLowerInvariant()))
    $assignmentId = [guid]::new([byte[]]$bytes[0..15])
    $uri = "https://management.azure.com$Scope/providers/Microsoft.Authorization/roleAssignments/${assignmentId}?api-version=2022-04-01"
    $null = Invoke-KnowledgeRequest $uri 'PUT' @{
        properties = @{
            principalId = "$PrincipalId"; principalType = $PrincipalType
            roleDefinitionId = $roleDefinitionId
        }
    }
}

if (-not $ResourceGroupName) { $ResourceGroupName = "rg-eia-$Environment-$Suffix" }
if (-not $SearchServiceName) { $SearchServiceName = "aais-bzkb-eia-$Environment-$Suffix" }
if ($WhatIfPreference) {
    $null = $PSCmdlet.ShouldProcess("$ResourceGroupName/$SearchServiceName/$knowledgeBaseName", 'Create managed OneLake knowledge source and Foundry IQ knowledge base')
    return
}
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Azure CLI is required. Install it and run az login.' }
$chosenName = Read-Host "AI Search name [$SearchServiceName] (Enter keeps default, Q cancels)"
if ($chosenName -ieq 'q') { return }
if (-not [string]::IsNullOrWhiteSpace($chosenName)) { $SearchServiceName = $chosenName.Trim() }
if ($SearchServiceName.Length -lt 2 -or $SearchServiceName.Length -gt 60 -or
    $SearchServiceName -cnotmatch '^[a-z0-9][a-z0-9-]*[a-z0-9]$' -or $SearchServiceName.Contains('--')) {
    throw 'Search service name must be 2-60 lowercase letters, digits or single hyphens, beginning and ending with a letter or digit.'
}
$account = Invoke-KnowledgeCli @('account', 'show')
if ($SubscriptionId -eq [guid]::Empty) { $SubscriptionId = [guid]$account.id }
$groupUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/${ResourceGroupName}?api-version=2021-04-01"
$group = Invoke-KnowledgeRequest $groupUri
if (-not $Location) { $Location = $group.location }
if ($WorkspaceId -eq [guid]::Empty) {
    $workspaces = @(Get-KnowledgeFabricCollection 'https://api.fabric.microsoft.com/v1/workspaces')
    for ($index = 0; $index -lt $workspaces.Count; $index++) { Write-Host "$($index + 1). $($workspaces[$index].displayName) [$($workspaces[$index].id)]" }
    $choice = Read-Host 'Select workspace number (Q cancels)'
    if ($choice -ieq 'q') { return }
    $selection = 0
    if (-not [int]::TryParse($choice, [ref]$selection) -or $selection -lt 1 -or $selection -gt $workspaces.Count) { throw 'Invalid workspace selection.' }
    $WorkspaceId = [guid]$workspaces[$selection - 1].id
}
if ($LakehouseId -eq [guid]::Empty) {
    $items = @(Get-KnowledgeFabricCollection "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/items")
    $matches = @($items | Where-Object { $_.type -eq 'Lakehouse' -and $_.displayName -ceq 'InsuranceBusinessDocuments' })
    if ($matches.Count -ne 1) { throw 'Expected exactly one InsuranceBusinessDocuments lakehouse in the selected workspace.' }
    $LakehouseId = [guid]$matches[0].id
}
$lakehouse = Invoke-KnowledgeRequest "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/items/$LakehouseId"
if ($lakehouse.type -ne 'Lakehouse') { throw 'The selected item is not a lakehouse.' }
$scope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Search/searchServices/$SearchServiceName"
$serviceUri = "https://management.azure.com${scope}?api-version=2023-11-01"
$service = Invoke-KnowledgeRequest $serviceUri -AllowNotFound
if ($service -and ($service.sku.name -eq 'free' -or -not $service.identity.principalId)) {
    throw 'Existing Search must be Basic or higher with a system-assigned identity. Its configuration was not changed.'
}
if ($CallerObjectId -eq [guid]::Empty) {
    if ($account.user.type -ne 'user') { throw 'For service-principal logins, supply -CallerObjectId with the principal object ID.' }
    $caller = Invoke-KnowledgeRequest 'https://graph.microsoft.com/v1.0/me?$select=id'
    $CallerObjectId = [guid]$caller.id
}
Write-Host "Knowledge base: $knowledgeBaseName; Search: $SearchServiceName; location: $Location; SKU: $Sku"
Write-Host "Source: $WorkspaceId/$LakehouseId/Files/$targetPath (all descendants); hourly refresh."
Write-Warning 'New Azure AI Search resources incur ongoing charges. This script uses public endpoints with Entra authentication; it does not configure private networking or document-level ACL trimming.'
if (-not $PSCmdlet.ShouldProcess("$scope -> $WorkspaceId/$LakehouseId/Files/$targetPath", 'Provision Search, assign caller roles, and create managed knowledge ingestion')) { return }
if (-not $service) {
    $null = Invoke-KnowledgeRequest $serviceUri 'PUT' @{
        location = $Location; sku = @{ name = $Sku }; identity = @{ type = 'SystemAssigned' }
        properties = @{ replicaCount = 1; partitionCount = 1; hostingMode = 'default'; publicNetworkAccess = 'enabled'; disableLocalAuth = $true; semanticSearch = 'free' }
    }
}
$provisioningAttempts = $ProvisioningTimeoutMinutes * 6
for ($attempt = 0; $attempt -lt $provisioningAttempts; $attempt++) {
    $service = Invoke-KnowledgeRequest $serviceUri
    $readinessDetails = "provisioningState='$($service.properties.provisioningState)', status='$($service.properties.status)', identityReady=$([bool]$service.identity.principalId), statusDetails='$($service.properties.statusDetails)'"
    if ($service.properties.provisioningState -in @('failed', 'canceled')) { throw "Search provisioning failed for ${scope}: $readinessDetails. Inspect the resource in Azure before rerunning." }
    if ($service.properties.provisioningState -eq 'succeeded' -and $service.identity.principalId) { break }
    if ($attempt -eq ($provisioningAttempts - 1)) {
        throw "Search provisioning timed out after approximately $ProvisioningTimeoutMinutes minutes for ${scope}: $readinessDetails. The resource was not deleted; inspect Azure and rerun to reuse it, or increase -ProvisioningTimeoutMinutes."
    }
    if ($attempt % 6 -eq 0) { Write-Host "Waiting for Search provisioning (limit $ProvisioningTimeoutMinutes minutes): $readinessDetails" }
    Start-Sleep -Seconds 10
}
if ($service.sku.name -eq 'free' -or -not $service.identity.principalId) { throw 'Existing Search must be Basic or higher with a system-assigned identity.' }
if ($service.properties.publicNetworkAccess -eq 'disabled') { throw 'This script requires an accessible public Search endpoint; it does not change existing network restrictions.' }
Grant-KnowledgeSearchRole $scope $CallerObjectId '7ca78c08-252a-4471-8644-bb5ff32d4ba0' $(if ($account.user.type -eq 'user') { 'User' } else { 'ServicePrincipal' })
Grant-KnowledgeSearchRole $scope $CallerObjectId '8ebe5a00-799e-43f5-93ac-243d3dce84a7' $(if ($account.user.type -eq 'user') { 'User' } else { 'ServicePrincipal' })
$assignments = @(Get-KnowledgeFabricCollection "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/roleAssignments")
$existingAccess = @($assignments | Where-Object { $_.principal.id -eq $service.identity.principalId -and $_.role -in @('Admin', 'Member', 'Contributor') })
if (-not $existingAccess) {
    $lowerAccess = @($assignments | Where-Object { $_.principal.id -eq $service.identity.principalId })
    if ($lowerAccess.Count) { throw 'Search identity already has a lower Fabric role. Upgrade it to Contributor manually and rerun; this script does not overwrite role assignments.' }
    if (-not $GrantFabricAccess) {
        $permission = Read-Host "Grant Search identity $($service.identity.principalId) Contributor on Fabric workspace $WorkspaceId? This grants write access to the whole workspace [y/N]"
        if ($permission -ine 'y') { throw 'Fabric access not granted. Grant the Search identity Contributor manually, then rerun, or use -GrantFabricAccess to approve.' }
    }
    $null = Invoke-KnowledgeRequest "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId/roleAssignments" 'POST' @{
        principal = @{ id = $service.identity.principalId; type = 'ServicePrincipal' }; role = 'Contributor'
    }
}
$searchRoot = "https://$SearchServiceName.search.windows.net"
for ($attempt = 0; $attempt -lt 30; $attempt++) {
    try {
        $null = Invoke-KnowledgeRequest "$searchRoot/knowledgesources?api-version=$searchApiVersion"
        break
    } catch {
        if ($_.Exception.Message -notmatch '^HTTP (401|403|503) ' -or $attempt -eq 29) { throw }
        Write-Host 'Waiting for Search endpoint and caller RBAC propagation...'
        Start-Sleep -Seconds 10
    }
}
$sourceUri = "$searchRoot/knowledgesources/${knowledgeSourceName}?api-version=$searchApiVersion"
$baseUri = "$searchRoot/knowledgebases/${knowledgeBaseName}?api-version=$searchApiVersion"
$existingSource = Invoke-KnowledgeRequest $sourceUri -AllowNotFound
if ($existingSource) {
    $sourceParameters = $existingSource.indexedOneLakeParameters
    $workspaceMatches = $sourceParameters.fabricWorkspaceId -eq "$WorkspaceId"
    if ($sourceParameters.fabricWorkspaceId -ieq '<redacted>') {
        $workspaceMatches = $lakehouse.type -eq 'Lakehouse' -and $sourceParameters.lakehouseId -eq "$LakehouseId"
    }
    if ($existingSource.kind -ne 'indexedOneLake' -or -not $workspaceMatches -or
        $sourceParameters.lakehouseId -ne "$LakehouseId" -or $sourceParameters.targetPath -cne $targetPath) {
        throw "Existing knowledge source points to different data. It was not overwritten. Expected kind=indexedOneLake, workspace=$WorkspaceId, lakehouse=$LakehouseId, folder=$targetPath; received kind=$($existingSource.kind), workspace=$($sourceParameters.fabricWorkspaceId), lakehouse=$($sourceParameters.lakehouseId), folder=$($sourceParameters.targetPath)."
    }
} else {
    $existingSource = Invoke-KnowledgeRequest $sourceUri 'PUT' (New-KnowledgeSourceDefinition $WorkspaceId $LakehouseId) @{ 'If-None-Match' = '*' }
}
$existingBase = Invoke-KnowledgeRequest $baseUri -AllowNotFound
if ($existingBase) {
    if (@($existingBase.knowledgeSources).Count -ne 1 -or $existingBase.knowledgeSources[0].name -ne $knowledgeSourceName) {
        throw 'Existing knowledge base references different sources. It was not overwritten.'
    }
} else {
    $null = Invoke-KnowledgeRequest $baseUri 'PUT' (New-KnowledgeBaseDefinition) @{ 'If-None-Match' = '*' }
}
$statusUri = "$searchRoot/knowledgesources/$knowledgeSourceName/status?api-version=$searchApiVersion"
$ingestionStatus = Invoke-KnowledgeRequest $statusUri
$verifiedFileCount = $null
$indexerStatusUri = $null
if ($WaitForIngestion) {
    $deadline = [datetime]::UtcNow.AddMinutes($IngestionTimeoutMinutes)
    $progressDetails = 'Waiting for the managed indexer to start.'
    for ($poll = 0; ; $poll++) {
        $lastState = $ingestionStatus.lastSynchronizationState
        $currentState = $ingestionStatus.currentSynchronizationState
        if ($currentState.errors -or $currentState.itemsUpdatesFailed -gt 0 -or
            (-not $currentState -and $lastState.endTime -and ($lastState.itemsUpdatesFailed -gt 0 -or $lastState.errors))) {
            throw "Ingestion did not fully succeed: $($ingestionStatus | ConvertTo-Json -Depth 20 -Compress)"
        }
        $resources = $existingSource.indexedOneLakeParameters.createdResources
        if (-not $resources.indexer -or -not $resources.index) {
            $existingSource = Invoke-KnowledgeRequest $sourceUri
            $resources = $existingSource.indexedOneLakeParameters.createdResources
        }
        if ($resources.indexer -and $resources.index) {
            $indexerStatusUri = "$searchRoot/indexers/$($resources.indexer)/status?api-version=$searchApiVersion"
            $indexerStatus = Invoke-KnowledgeRequest $indexerStatusUri -AllowNotFound
            $execution = $indexerStatus.lastResult
            $progressDetails = "indexer='$($resources.indexer)', run='$($execution.status)', processed=$($execution.itemsProcessed), failed=$($execution.itemsFailed)"
            if ($indexerStatus.status -eq 'error' -or ($execution.endTime -and $execution.status -ne 'inProgress' -and
                -not $currentState -and ($execution.status -ne 'success' -or $execution.itemsFailed -gt 0 -or $execution.errors))) {
                throw "Indexer did not fully succeed: $($indexerStatus | ConvertTo-Json -Depth 20 -Compress)"
            }
            if ($execution.status -eq 'success' -and $execution.endTime -and $lastState.endTime -and -not $currentState) {
                $files = @(Get-KnowledgeFiles)
                if (-not $files.Count) { throw 'No files found in the selected OneLake folder; indexing completion cannot be verified.' }
                $indexedPaths = Get-KnowledgeIndexedPaths $resources.index
                $missing = @($files | Where-Object { -not $indexedPaths.Contains($_.Path) })
                $changed = @($files | Where-Object { -not $execution.startTime -or $_.LastModified -gt [datetimeoffset]::Parse($execution.startTime) })
                $progressDetails += "; source files=$($files.Count), missing=$($missing.Count), newer than run=$($changed.Count), skipped=$($lastState.itemsSkipped)"
                if (-not $missing.Count -and -not $changed.Count) {
                    $verifiedFileCount = $files.Count
                    if ($execution.warnings) { Write-Warning ($execution.warnings | ConvertTo-Json -Depth 10 -Compress) }
                    break
                }
                if ($missing.Count) { $progressDetails += "; first missing='$($missing[0].Path)'" }
            }
        }
        if ([datetime]::UtcNow -ge $deadline -or $poll -ge $IngestionTimeoutMinutes * 4) {
            throw "Ingestion wait timed out after $IngestionTimeoutMinutes minutes: $progressDetails. Inspect $statusUri and $indexerStatusUri. Existing resources and scheduled indexing were left unchanged; rerun to continue monitoring."
        }
        Write-Host "Waiting for managed OneLake ingestion: $progressDetails"
        Start-Sleep -Seconds 15
        $ingestionStatus = Invoke-KnowledgeRequest $statusUri
    }
}
Write-Host ($ingestionStatus | ConvertTo-Json -Depth 20)
if ($null -ne $verifiedFileCount) {
    Write-Host "Indexing completed successfully. Verified all $verifiedFileCount OneLake files in the index. Monitoring stopped; hourly scheduled indexing remains enabled."
} else { Write-Host 'Monitoring skipped. File coverage has not been verified.' }
[pscustomobject]@{
    KnowledgeBaseName = $knowledgeBaseName; SearchServiceName = $SearchServiceName; SearchResourceId = $scope
    WorkspaceId = $WorkspaceId; LakehouseId = $LakehouseId; Folder = "Files/$targetPath"
    KnowledgeBaseUrl = $baseUri; IngestionStatusUrl = $statusUri
    IndexerStatusUrl = $indexerStatusUri; VerifiedFileCount = $verifiedFileCount
    RetrieveUrl = "$searchRoot/knowledgebases/$knowledgeBaseName/retrieve?api-version=$searchApiVersion"
}
#Requires -Version 7.0
param([switch]$RenderPdf)
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot '../fabric/create-insurance-business-documents.ps1'
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Assert-Fails {
    param([scriptblock]$Action, [string]$Pattern)
    try { & $Action; throw 'Expected failure was not raised.' }
    catch { Assert-True ($_.Exception.Message -like $Pattern) "Unexpected error: $($_.Exception.Message)" }
}
$workspaceId = '11111111-1111-4111-8111-111111111111'
$lakehouseId = '22222222-2222-4222-8222-222222222222'
$operationId = '33333333-3333-4333-8333-333333333333'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "business-documents-tests-$([guid]::NewGuid())"
$functions = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false))
foreach ($function in $functions) { . ([scriptblock]::Create($function.Extent.Text)) }
$exportFunction = $functions | Where-Object Name -EQ 'Export-BusinessPdf'
$mockExport = @'
function Export-BusinessPdf {
    param($Document, $Destination, $Browser)
    $html = ConvertTo-BusinessHtml $Document
    if ($Destination -like '*render-failure*' -and $Document.Kind -eq 'Compliance') { throw 'Renderer failed' }
    if ($Destination -like '*reuse-local*') { throw 'Existing PDF must not be rendered again' }
    [IO.File]::WriteAllBytes($Destination, [Text.Encoding]::ASCII.GetBytes("%PDF-1.7`n$html`n%%EOF"))
}
'@
$workflow = [scriptblock]::Create($ast.Extent.Text.Remove($exportFunction.Extent.StartOffset, $exportFunction.Extent.EndOffset - $exportFunction.Extent.StartOffset).Insert($exportFunction.Extent.StartOffset, $mockExport))
function Reset-BusinessTest {
    $global:BusinessDocumentTestState = @{
        Rendered = @(); Requests = @(); CliCalls = @(); Remote = @{}; Directories = @{}
        Items = @(); Async = $false; BadLength = $false; AppendFailure = $false
        AuthFailure = $false; BadNext = $null; OperationFailure = $false; DirectoryFailure = $false
        FailurePhase = ''; FailuresRemaining = 0; HttpStatus = 500; Delays = @(); InitialLocalCount = 0
        PromptAnswers = [Collections.Generic.Queue[string]]::new()
    }
}
function az {
    $state = $global:BusinessDocumentTestState
    $state.CliCalls += ,$args
    $global:LASTEXITCODE = if ($state.AuthFailure) { 1 } else { 0 }
    @{ accessToken = "token:$($args[[array]::IndexOf($args, '--resource') + 1])" } | ConvertTo-Json -Compress
}
function Start-Sleep { param($Seconds) $global:BusinessDocumentTestState.Delays += $Seconds }
function Read-Host { param($Prompt) $global:BusinessDocumentTestState.PromptAnswers.Dequeue() }
function Invoke-WebRequest {
    param([uri]$Uri, $Method, $Headers, $TimeoutSec, $MaximumRedirection, $MaximumRetryCount, $InFile, $ContentType, $Body)
    $state = $global:BusinessDocumentTestState
    $state.Requests += $PSBoundParameters
    Assert-True ($MaximumRedirection -eq 0 -and $MaximumRetryCount -eq 0) 'Requests must not redirect or replay writes.'
    $response = @{ StatusCode = 200; Headers = @{}; Content = '' }
    $phase = if ($Method -eq 'GET') { 'read' } else { '' }
    if ($Uri.Host -eq 'onelake.dfs.fabric.microsoft.com') {
        Assert-True ($Headers.Authorization -eq 'Bearer token:https://storage.azure.com/') 'Incorrect OneLake token audience.'
        $root = "https://onelake.dfs.fabric.microsoft.com/$workspaceId/$lakehouseId/Files/"
        $key = $Uri.GetLeftPart([UriPartial]::Path)
        Assert-True ($key.StartsWith($root)) 'Unexpected file root.'
        $relative = $key.Substring($root.Length)
        if ($Method -eq 'HEAD' -and $state.Directories.ContainsKey($key)) {
            $response.Headers['x-ms-resource-type'] = 'directory'
        } elseif ($Uri.Query -eq '?resource=directory') {
            Assert-True ($Method -eq 'PUT' -and $Headers['If-None-Match'] -eq '*') 'Unsafe directory creation.'
            if ($state.DirectoryFailure) { throw 'Directory access denied' }
            $state.Directories[$key] = $true
        } elseif ($relative -notlike '*.pdf' -and $Method -eq 'HEAD') {
            $failure = [Exception]::new('Directory not found')
            Add-Member -InputObject $failure -NotePropertyName Response -NotePropertyValue @{ StatusCode = 404 }
            throw $failure
        } elseif ($Method -eq 'PUT') {
            $phase = 'create'
            Assert-True ($relative -cmatch '^InsuranceBusinessKnowledge/(?<line>Auto|Home|Business)/(?<state>[A-Z]{2})/(?<kind>Compliance|Guidelines|Regulatory)/\k<line>_\k<state>_\k<kind>\.pdf$') 'Incorrect remote layout or filename.'
            $parent = $key.Substring(0, $key.LastIndexOf('/'))
            Assert-True ($state.Directories.ContainsKey($parent)) 'Parent directory must exist before file creation.'
            if ($state.Remote.ContainsKey($key) -and $Headers['If-None-Match'] -eq '*') { throw 'Remote PDF already exists' }
            $state.Remote[$key] = [byte[]]@()
        } elseif ($Method -eq 'PATCH' -and $Uri.Query -like '*action=append*') {
            $phase = 'append'
            if ($state.AppendFailure) { throw 'Append failed' }
            Assert-True ($ContentType -eq 'application/octet-stream' -and $Uri.Query -like '*position=0*') 'Incorrect append.'
            if ($state.Remote.Count -eq 1 -and $InFile -notlike '*reuse-local*') {
                $outputRoot = Split-Path (Split-Path (Split-Path $InFile -Parent) -Parent) -Parent
                $outputRoot = Split-Path (Split-Path $outputRoot -Parent) -Parent
                Assert-True (@(Get-ChildItem $outputRoot -Filter '*.pdf' -Recurse).Count -le ($state.InitialLocalCount + 2)) 'Uploader must start before the remaining PDFs are rendered.'
            }
            $state.Remote[$key] = [IO.File]::ReadAllBytes($InFile)
        } elseif ($Method -eq 'PATCH' -and $Uri.Query -like '*action=flush*') {
            $phase = 'flush'
            Assert-True (-not $InFile -and $null -eq $Body -and $Headers['x-ms-content-type'] -eq 'application/pdf') 'Incorrect flush body or content type.'
            Assert-True ($Uri.Query -eq "?action=flush&position=$($state.Remote[$key].Length)&close=true") 'Incorrect flush length.'
        } elseif ($Method -eq 'HEAD') {
            $phase = 'verify'
            $response.Headers['Content-Length'] = if ($state.BadLength) { '0' } else { [string]$state.Remote[$key].Length }
        } else { throw "Unexpected storage request $Method $Uri" }
    } else {
        Assert-True ($Headers.Authorization -eq 'Bearer token:https://api.fabric.microsoft.com') 'Incorrect Fabric token audience.'
        switch ($Uri.AbsolutePath) {
            '/v1/workspaces' { $response.Content = @{ value = @(@{ id = $workspaceId; displayName = 'Test workspace' }) } | ConvertTo-Json -Depth 5 }
            "/v1/workspaces/$workspaceId" { $response.Content = @{ capacityId = $operationId } | ConvertTo-Json }
            "/v1/workspaces/$workspaceId/items" { $response.Content = @{ value = $state.Items; continuationUri = $state.BadNext } | ConvertTo-Json -Depth 5 }
            "/v1/workspaces/$workspaceId/lakehouses" {
                Assert-True ($Method -eq 'POST' -and ($Body | ConvertFrom-Json).displayName -eq 'InsuranceBusinessDocuments') 'Wrong lakehouse creation.'
                $response.StatusCode = if ($state.Async) { 202 } else { 201 }
                $response.Headers = @{ 'x-ms-operation-id' = $operationId; Location = 'https://untrusted.invalid'; 'Retry-After' = '1' }
                $response.Content = @{ id = $lakehouseId } | ConvertTo-Json
            }
            "/v1/operations/$operationId" { $response.Content = @{ status = $(if ($state.OperationFailure) { 'Failed' } else { 'Succeeded' }) } | ConvertTo-Json }
            "/v1/operations/$operationId/result" { $response.Content = @{ id = $lakehouseId } | ConvertTo-Json }
            default { throw "Unexpected Fabric request $Method $Uri" }
        }
    }
    if ($phase -and $state.FailurePhase -eq $phase -and $state.FailuresRemaining -gt 0) {
        $state.FailuresRemaining--
        $httpResponse = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]$state.HttpStatus)
        $httpResponse.Headers.RetryAfter = [Net.Http.Headers.RetryConditionHeaderValue]::new([timespan]::FromSeconds(7))
        throw [Microsoft.PowerShell.Commands.HttpResponseException]::new("Injected HTTP $($state.HttpStatus) at $phase", $httpResponse)
    }
    [pscustomobject]$response
}
function Invoke-BusinessTestWorkflow {
    param([string]$Name, [hashtable]$Options = @{})
    $parameters = @{ WorkspaceId = $workspaceId; States = @('MA'); OutputDirectory = (Join-Path $testRoot $Name); BrowserExecutable = (Get-Process -Id $PID).Path }
    foreach ($key in $Options.Keys) { $parameters[$key] = $Options[$key] }
    if ($parameters.WorkspaceId -eq [guid]::Empty) { $parameters.Remove('WorkspaceId') }
    & $workflow @parameters
}
try {
    Reset-BusinessTest
    & $scriptPath -WhatIf -OutputDirectory (Join-Path $testRoot 'whatif')
    Assert-True (-not (Test-Path $testRoot) -and $global:BusinessDocumentTestState.CliCalls.Count -eq 0) 'WhatIf must do no work.'
    Assert-Fails { & $scriptPath -States ZZ -WhatIf } '*Unknown US state*'
    Write-Host 'PASS: Parser, offline WhatIf, and state validation.'

    $states = Get-BusinessStates
    Assert-True ($states.Count -eq 50 -and $states.MA -eq 'Massachusetts' -and $states.HI -eq 'Hawaii') 'Incorrect state catalog.'
    foreach ($stateCode in $states.Keys) {
        foreach ($line in @('auto','home','business')) {
            foreach ($kind in @('Guidelines','Compliance','Regulatory')) {
                $document = [pscustomobject]@{ StateCode = $stateCode; StateName = $states[$stateCode]; Line = $line; Kind = $kind }
                $sections = @(Get-BusinessSections $stateCode $states[$stateCode] $line $kind)
                Assert-True ($sections.Count -ge 7 -and @($sections | Where-Object { $_ -isnot [array] -or $_.Count -ne 2 }).Count -eq 0) 'Each section must have a heading and paragraph.'
                $html = ConvertTo-BusinessHtml $document
                Assert-True ($html.Contains($states[$stateCode]) -and $html.Contains("IBD-$stateCode-$line-$kind")) 'Missing jurisdiction or document ID.'
                Assert-True ($html -notmatch '(?i)\b(demo|example|sample|fictional)\b') 'Unwanted document label.'
                Assert-True ($html.Contains('Legal source status: Not verified') -and $html.Length -gt 3000) 'Missing content or authority distinction.'
                if ($kind -eq 'Regulatory') { Assert-True ($html.Contains('Pending jurisdictional verification')) 'Unverified regulation presented as established law.' }
            }
        }
    }
    $escaped = ConvertTo-BusinessHtml ([pscustomobject]@{ StateCode = 'MA'; StateName = '<Massachusetts> &'; Line = 'auto'; Kind = 'Guidelines' })
    Assert-True ($escaped.Contains('&lt;Massachusetts&gt; &amp;') -and -not $escaped.Contains('<Massachusetts>')) 'HTML values must be encoded.'
    Write-Host 'PASS: All 450 document bodies, section structure, authority, and encoding.'

    Reset-BusinessTest
    $result = @(Invoke-BusinessTestWorkflow 'all-states' @{ States = @($states.Keys) })
    Assert-True ($result.Count -eq 450 -and $global:BusinessDocumentTestState.Remote.Count -eq 450 -and $global:BusinessDocumentTestState.Directories.Count -eq 604) 'All-state layout or upload count mismatch.'
    Assert-True ($result[0].OneLakeUrl.EndsWith('/InsuranceBusinessKnowledge/Auto/AL/Compliance/Auto_AL_Compliance.pdf') -and $result[150].OneLakeUrl.EndsWith('/InsuranceBusinessKnowledge/Home/AL/Compliance/Home_AL_Compliance.pdf') -and $result[300].OneLakeUrl.EndsWith('/InsuranceBusinessKnowledge/Business/AL/Compliance/Business_AL_Compliance.pdf')) 'Generation must follow line/state/document order.'
    Write-Host 'PASS: 450 named uploads, line-first order, 604 directories, MIME, token audiences, flush and size checks.'

    Reset-BusinessTest
    $global:BusinessDocumentTestState.Items = @(@{ displayName = 'InsuranceBusinessDocuments'; type = 'SQLEndpoint'; id = $operationId }, @{ displayName = 'InsuranceBusinessDocuments'; type = 'Lakehouse'; id = $lakehouseId })
    $null = Invoke-BusinessTestWorkflow 'reuse' @{ States = @('ma','MA') }
    Assert-True (@(Get-ChildItem (Join-Path $testRoot 'reuse') -Filter '*.pdf' -Recurse).Count -eq 9 -and @($global:BusinessDocumentTestState.Requests | Where-Object Method -EQ 'POST').Count -eq 0) 'Lakehouse reuse or state deduplication failed.'
    $null = Invoke-BusinessTestWorkflow 'overwrite' @{ Overwrite = $true }
    Assert-Fails { $null = Invoke-BusinessTestWorkflow 'reuse' } '*File already exists*'
    Assert-Fails { $null = Invoke-BusinessTestWorkflow 'remote-collision' } '*Remote PDF already exists*'
    Write-Host 'PASS: Lakehouse/SQL endpoint reuse, normalized states, local/remote collision protection and overwrite.'

    Reset-BusinessTest
    $null = Invoke-BusinessTestWorkflow 'local' @{ LocalOnly = $true }
    Assert-True ($global:BusinessDocumentTestState.Requests.Count -eq 0 -and $global:BusinessDocumentTestState.CliCalls.Count -eq 0) 'LocalOnly must not authenticate or upload.'
    $global:BusinessDocumentTestState.PromptAnswers.Enqueue('q')
    $null = Invoke-BusinessTestWorkflow 'cancel' @{ WorkspaceId = [guid]::Empty }
    Assert-True (@($global:BusinessDocumentTestState.Requests | Where-Object Method -EQ 'POST').Count -eq 0) 'Cancellation created a lakehouse.'
    Write-Host 'PASS: Local-only mode and workspace selection cancellation.'

    Reset-BusinessTest
    $global:BusinessDocumentTestState.Async = $true
    $null = Invoke-BusinessTestWorkflow 'async'
    Assert-True (@($global:BusinessDocumentTestState.Requests | Where-Object { $_.Uri.AbsolutePath -eq "/v1/operations/$operationId/result" }).Count -eq 1) 'Async creation did not retrieve canonical result.'
    foreach ($failureCase in @(
        @('BadLength','*size mismatch*'), @('AppendFailure','*Append failed*'),
        @('AuthFailure','*Unable to acquire token*'), @('DirectoryFailure','*Directory access denied*'),
        @('OperationFailure','*Lakehouse creation failed*')
    )) {
        Reset-BusinessTest
        $global:BusinessDocumentTestState[$failureCase[0]] = $true
        if ($failureCase[0] -eq 'OperationFailure') { $global:BusinessDocumentTestState.Async = $true }
        Assert-Fails { $null = Invoke-BusinessTestWorkflow $failureCase[0] } $failureCase[1]
        $failureDirectory = Join-Path $testRoot $failureCase[0]
        if ($failureCase[0] -in @('AuthFailure','OperationFailure')) {
            Assert-True (-not (Test-Path $failureDirectory)) 'Resolve Fabric before spending time rendering.'
        } else {
            $retainedCount = @(Get-ChildItem $failureDirectory -Filter '*.pdf' -Recurse).Count
            Assert-True ($retainedCount -ge 1 -and $retainedCount -le 2) 'Retain completed PDFs and stop further rendering on upload failure.'
        }
    }
    Reset-BusinessTest
    $global:BusinessDocumentTestState.BadNext = 'https://untrusted.invalid/next'
    Assert-Fails { $null = Invoke-BusinessTestWorkflow 'unsafe-pagination' } '*Rejected request URL*'
    Reset-BusinessTest
    $global:BusinessDocumentTestState.Items = @(@{ displayName = 'InsuranceBusinessDocuments'; type = 'Warehouse'; id = $lakehouseId })
    Assert-Fails { $null = Invoke-BusinessTestWorkflow 'name-collision' } '*Ambiguous or non-lakehouse*'
    Write-Host 'PASS: Async creation, safe pagination, item collisions, and failure preservation.'

    Reset-BusinessTest
    Assert-Fails { $null = Invoke-BusinessTestWorkflow 'render-failure' } '*Renderer failed*'
    Assert-True ($global:BusinessDocumentTestState.Remote.Count -eq 0) 'A failed render must not upload that PDF or render the rest.'
    Write-Host 'PASS: Bounded render/upload overlap and renderer failure propagation.'

    Reset-BusinessTest
    $reuseDirectory = Join-Path $testRoot 'reuse-local'
    foreach ($line in @('Auto','Home','Business')) {
        foreach ($kind in @('Guidelines','Compliance','Regulatory')) {
            $null = [IO.Directory]::CreateDirectory((Join-Path $reuseDirectory "InsuranceBusinessKnowledge/$line/MA/$kind"))
            [IO.File]::WriteAllText((Join-Path $reuseDirectory "InsuranceBusinessKnowledge/$line/MA/$kind/${line}_MA_${kind}.pdf"), "%PDF-1.7`nExisting complete PDF`n%%EOF")
        }
    }
    $null = Invoke-BusinessTestWorkflow 'reuse-local' @{ LocalOnly = $true; ReuseLocal = $true }
    $null = Invoke-BusinessTestWorkflow 'reuse-local' @{ ReuseLocal = $true; Overwrite = $true }
    Assert-True ($global:BusinessDocumentTestState.Remote.Count -eq 9) 'ReuseLocal must upload all complete local PDFs without rendering.'
    [IO.File]::WriteAllText((Join-Path $reuseDirectory 'InsuranceBusinessKnowledge/Auto/MA/Guidelines/Auto_MA_Guidelines.pdf'), '%PDF-incomplete')
    Assert-Fails { $null = Invoke-BusinessTestWorkflow 'reuse-local' @{ ReuseLocal = $true; Overwrite = $true } } '*Cannot reuse incomplete or invalid PDF*'
    Write-Host 'PASS: Local PDF reuse in both modes and incomplete-file rejection.'

    foreach ($phase in @('create','append','flush','verify')) {
        Reset-BusinessTest
        $global:BusinessDocumentTestState.FailurePhase = $phase
        $global:BusinessDocumentTestState.FailuresRemaining = 1
        $result = @(Invoke-BusinessTestWorkflow "transient-$phase" @{ Overwrite = $true })
        $fileCreates = @($global:BusinessDocumentTestState.Requests | Where-Object { $_.Method -eq 'PUT' -and $_.Uri.Query -eq '?resource=file' })
        Assert-True ($result.Count -eq 9 -and $global:BusinessDocumentTestState.Delays.Count -eq 1 -and $global:BusinessDocumentTestState.Delays[0] -ge 7) 'Transient failure must recover and honor Retry-After.'
        $expectedCreates = if ($phase -eq 'verify') { 9 } else { 10 }
        Assert-True ($fileCreates.Count -eq $expectedCreates) 'Uncertain writes must restart from file creation; verification reads retry without replacing the file.'
    }
    Reset-BusinessTest
    $global:BusinessDocumentTestState.FailurePhase = 'append'
    $global:BusinessDocumentTestState.FailuresRemaining = 10
    Assert-Fails { $null = Invoke-BusinessTestWorkflow 'retry-exhausted' @{ Overwrite = $true } } '*Injected HTTP 500*'
    Assert-True ($global:BusinessDocumentTestState.Delays.Count -eq 3 -and @($global:BusinessDocumentTestState.Requests | Where-Object { $_.Method -eq 'PATCH' -and $_.Uri.Query -like '*action=append*' }).Count -eq 4) 'Upload retry budget must be bounded.'
    Reset-BusinessTest
    $global:BusinessDocumentTestState.FailurePhase = 'append'
    $global:BusinessDocumentTestState.FailuresRemaining = 1
    Assert-Fails { $null = Invoke-BusinessTestWorkflow 'no-unsafe-retry' } '*Injected HTTP 500*'
    Assert-True ($global:BusinessDocumentTestState.Delays.Count -eq 0) 'Default conditional writes must not be replayed after an uncertain failure.'
    Reset-BusinessTest
    $global:BusinessDocumentTestState.FailurePhase = 'append'
    $global:BusinessDocumentTestState.FailuresRemaining = 1
    $global:BusinessDocumentTestState.HttpStatus = 403
    Assert-Fails { $null = Invoke-BusinessTestWorkflow 'no-auth-retry' @{ Overwrite = $true } } '*Injected HTTP 403*'
    Assert-True ($global:BusinessDocumentTestState.Delays.Count -eq 0) 'Authorization failures must not be retried.'
    Reset-BusinessTest
    $global:BusinessDocumentTestState.FailurePhase = 'read'
    $global:BusinessDocumentTestState.FailuresRemaining = 1
    $global:BusinessDocumentTestState.HttpStatus = 429
    $tokenCache = @{}
    $null = Invoke-BusinessRequest 'workspaces'
    Assert-True ($global:BusinessDocumentTestState.Requests.Count -eq 2) 'Read throttling must retry.'
    Write-Host 'PASS: Bounded retries, ambiguous-write restart, Retry-After, throttling, and nonretryable errors.'

    Reset-BusinessTest
    $skippedDirectory = Join-Path $testRoot 'start-at/InsuranceBusinessKnowledge/Auto/MA/Guidelines'
    $null = [IO.Directory]::CreateDirectory($skippedDirectory)
    [IO.File]::WriteAllText((Join-Path $skippedDirectory 'Auto_MA_Guidelines.pdf'), 'Earlier file must not be touched')
    $global:BusinessDocumentTestState.InitialLocalCount = 1
    $result = @(Invoke-BusinessTestWorkflow 'start-at' @{ StartAt = 'InsuranceBusinessKnowledge/Home/MA/Compliance/Home_MA_Compliance.pdf' })
    Assert-True ($result.Count -eq 6 -and $result[0].OneLakeUrl.EndsWith('/InsuranceBusinessKnowledge/Home/MA/Compliance/Home_MA_Compliance.pdf')) 'StartAt must include the failed file and skip earlier documents.'
    Assert-True ([IO.File]::ReadAllText((Join-Path $skippedDirectory 'Auto_MA_Guidelines.pdf')) -eq 'Earlier file must not be touched') 'StartAt changed an earlier local file.'
    Assert-Fails { $null = Invoke-BusinessTestWorkflow 'invalid-start' @{ StartAt = 'InsuranceBusinessKnowledge/Auto/CA/Compliance/Auto_CA_Compliance.pdf' } } '*not in the selected states*'
    Assert-Fails { $null = Invoke-BusinessTestWorkflow 'mismatched-start' @{ StartAt = 'InsuranceBusinessKnowledge/Auto/MA/Compliance/Home_MA_Compliance.pdf' } } '*does not match its folders*'
    Write-Host 'PASS: Exact-path resume skips earlier local and remote documents.'

    if ($RenderPdf) {
        $realDirectory = Join-Path $testRoot 'edge-render'
        & $scriptPath -States MA -LocalOnly -OutputDirectory $realDirectory | Out-Null
        $pdfs = @(Get-ChildItem $realDirectory -Filter '*.pdf' -Recurse)
        Assert-True ($pdfs.Count -eq 9 -and @($pdfs | Where-Object Length -LT 1000).Count -eq 0) 'Real PDF rendering failed.'
        Write-Host 'PASS: Real Edge rendering for all nine Massachusetts documents.'
        Reset-BusinessTest
        $workflow = [scriptblock]::Create($ast.Extent.Text)
        $result = @(Invoke-BusinessTestWorkflow 'edge-pipeline' @{ BrowserExecutable = $null })
        Assert-True ($result.Count -eq 9 -and @($result | Where-Object { (Get-Item $_.LocalPath).Length -lt 1000 }).Count -eq 0) 'Real background rendering failed.'
        Write-Host 'PASS: Real background Edge rendering overlapped with mocked uploads for nine PDFs.'
    }
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Variable BusinessDocumentTestState -Scope Global -ErrorAction SilentlyContinue
}
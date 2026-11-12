#Requires -Version 7.0
param([switch]$RenderPdf)
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot '../fabric/create-insurance-customer-policy-documents.ps1'
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$parseErrors)
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
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "policy-workflow-tests-$([guid]::NewGuid())"
$null = [IO.Directory]::CreateDirectory($testRoot)
$global:PolicyDocumentTestState = @{}
function Reset-PolicyTest {
    $global:PolicyDocumentTestState = @{
        CliCalls = @(); SqlCalls = @(); Requests = @(); Rendered = @(); Remote = @{}; UpdatedUrls = @{}
        UpdateFailure = $false
        Items = @(); Async = $false; CliFailure = $false; SqlFailure = $false
        NoRows = $false; BadLength = $false; AppendFailure = $false; OperationFailure = $false
        BadNext = $null; PromptAnswers = [System.Collections.Generic.Queue[string]]::new()
    }
}
$fixtures = @(1..10 | ForEach-Object {
    $index = $_
    [pscustomobject]@{
        PolicyId = [guid]('c0570000-0003-4000-8000-{0:D12}' -f $index)
        CustomerId = [guid]('c0570000-0001-4000-8000-{0:D12}' -f $index)
        PolicyNumber = 'DEMO-CB-{0:D3}' -f $index
        FirstName = 'Skyler'; LastName = "O'Brien"; EmailAddress = 'customer10@example.com'; Phone = '+1-202-555-0110'
        PolicyType = @('Auto', 'Home', 'Business')[($index - 1) % 3]
        BusinessLine = 'Personal'; ProductName = 'Test <product> & coverage'
        PolicyStatus = 'Active'; EffectiveDate = [datetime]'2026-03-15'; ExpirationDate = [datetime]'2027-03-15'
        PremiumAmount = [decimal]'145.25'; PremiumFrequency = 'Monthly'; CurrencyCode = 'USD'
        CoverageLimitAmount = [decimal]'150000'; DeductibleAmount = [DBNull]::Value
        InsuredVehicleVIN = [DBNull]::Value; InsuredBusinessName = [DBNull]::Value
        CustomerAddress = '1010 Sample Terrace, Atlanta, Georgia, 30303, United States'
        PropertyAddress = [DBNull]::Value
    }
})
function az {
    $state = $global:PolicyDocumentTestState
    $state.CliCalls += ,$args
    $global:LASTEXITCODE = if ($state.CliFailure) { 1 } else { 0 }
    if (-not $state.CliFailure) {
        $resourceIndex = [array]::IndexOf($args, '--resource')
        @{ accessToken = "token:$($args[$resourceIndex + 1])" } | ConvertTo-Json -Compress
    }
}
function Invoke-Sqlcmd {
    param($ServerInstance, $Database, $AccessToken, $Encrypt, [switch]$AbortOnError,
          $ErrorAction, $ConnectionTimeout, $QueryTimeout, [switch]$DisableVariables, $Query)
    $global:PolicyDocumentTestState.SqlCalls += $PSBoundParameters
    if ($global:PolicyDocumentTestState.SqlFailure) { throw 'Simulated SQL failure' }
    if ($Query -match '(?m)^UPDATE obj\.InsurancePolicy') {
        $state = $global:PolicyDocumentTestState
        if ($state.UpdateFailure) { throw 'Simulated SQL update failure' }
        $urlMatch = [regex]::Match($Query, "PolicyDocumentUrl = N'(?<url>(?:''|[^'])*)'")
        $idMatch = [regex]::Match($Query, "WHERE Id = '(?<policy>[0-9a-f-]+)' AND CustomerId = '(?<customer>[0-9a-f-]+)'")
        Assert-True ($urlMatch.Success -and $idMatch.Success) 'SQL update must specify the URL and both record IDs.'
        $url = $urlMatch.Groups['url'].Value.Replace("''", "'")
        $policyId = $idMatch.Groups['policy'].Value
        $fixture = $fixtures | Where-Object { [string]$_.PolicyId -eq $policyId }
        Assert-True ($null -ne $fixture -and [string]$fixture.CustomerId -eq $idMatch.Groups['customer'].Value) 'SQL update targeted the wrong policy or customer.'
        $lastRequest = $state.Requests[-1]
        Assert-True ($lastRequest.Method -eq 'HEAD' -and $lastRequest.Uri.AbsoluteUri -eq $url -and $state.Remote.ContainsKey($url)) 'SQL URL changed before the matching upload was verified.'
        Assert-True ($AccessToken -eq 'token:https://database.windows.net/' -and $Encrypt -eq 'Mandatory' -and $AbortOnError -and $DisableVariables) 'SQL update must use secure SQL authentication and options.'
        Assert-True ($Query.Contains('UpdatedAtUtc = SYSUTCDATETIME()') -and $Query.Contains('IF @@ROWCOUNT <> 1') -and $Query.Contains('THROW 50001')) 'Missing update timestamp or row-count guard.'
        $state.UpdatedUrls[$policyId] = $url
        return
    }
    if (-not $global:PolicyDocumentTestState.NoRows) { $fixtures }
}
function Read-Host {
    param($Prompt)
    if (-not $global:PolicyDocumentTestState.PromptAnswers.Count) { throw "Unexpected prompt: $Prompt" }
    $global:PolicyDocumentTestState.PromptAnswers.Dequeue()
}
function Start-Sleep { param($Seconds) }
function Invoke-WebRequest {
    param([uri]$Uri, $Method, $Headers, $TimeoutSec, $MaximumRedirection, $MaximumRetryCount, $InFile, $ContentType, $Body)
    $state = $global:PolicyDocumentTestState
    $state.Requests += $PSBoundParameters
    Assert-True ($MaximumRedirection -eq 0 -and $MaximumRetryCount -eq 0) 'Requests must not follow redirects or replay writes.'
    $response = @{ StatusCode = 200; Headers = @{}; Content = '' }
    $path = $Uri.AbsolutePath
    if ($Uri.Host -eq 'onelake.dfs.fabric.microsoft.com') {
        Assert-True ($Headers.Authorization -eq 'Bearer token:https://storage.azure.com/') 'OneLake needs a Storage audience token.'
        Assert-True ($path.StartsWith("/$workspaceId/$lakehouseId/Files/")) 'Unexpected OneLake path.'
        $key = $Uri.GetLeftPart([UriPartial]::Path)
        if ($Method -eq 'PUT') {
            if ($state.Remote.ContainsKey($key) -and $Headers['If-None-Match'] -eq '*') { throw 'Remote PDF already exists.' }
            $state.Remote[$key] = [byte[]]@()
            $response.StatusCode = 201
        } elseif ($Method -eq 'PATCH' -and $Uri.Query -like '*action=append*') {
            if ($state.AppendFailure) { throw 'Simulated append failure' }
            Assert-True ($Uri.Query -like '*position=0*' -and $ContentType -eq 'application/octet-stream') 'Incorrect binary append.'
            $state.Remote[$key] = [IO.File]::ReadAllBytes($InFile)
            $response.StatusCode = 202
        } elseif ($Method -eq 'PATCH' -and $Uri.Query -like '*action=flush*') {
            Assert-True ($null -eq $Body -and -not $InFile) 'Flush must have no body.'
            Assert-True ($Uri.Query -like "*position=$($state.Remote[$key].Length)&close=true" -and $Headers['x-ms-content-type'] -eq 'application/pdf') 'Incorrect flush position or MIME type.'
        } elseif ($Method -eq 'HEAD') {
            $response.Headers['Content-Length'] = if ($state.BadLength) { '0' } else { [string]$state.Remote[$key].Length }
        } else { throw "Unexpected OneLake request: $Method $Uri" }
        return [pscustomobject]$response
    }
    Assert-True ($Headers.Authorization -eq 'Bearer token:https://api.fabric.microsoft.com') 'Fabric needs its own token audience.'
    if ($path -eq '/v1/workspaces' -or $Uri.Query -eq '?continuationToken=page2') {
        $response.Content = @{ value = @(@{ id = $workspaceId; displayName = 'Test workspace' }) } | ConvertTo-Json -Depth 5
    } elseif ($path -eq "/v1/workspaces/$workspaceId") {
        $response.Content = @{ id = $workspaceId; displayName = 'Test workspace'; capacityId = $operationId } | ConvertTo-Json
    } elseif ($path -eq "/v1/workspaces/$workspaceId/items") {
        $response.Content = @{ value = $state.Items; continuationUri = $state.BadNext } | ConvertTo-Json -Depth 5
    } elseif ($path -eq "/v1/workspaces/$workspaceId/lakehouses" -and $Method -eq 'POST') {
        Assert-True (($Body | ConvertFrom-Json).displayName -eq 'InsuranceCustomerPolicies') 'Wrong lakehouse name.'
        $response.StatusCode = if ($state.Async) { 202 } else { 201 }
        $response.Headers = @{ 'x-ms-operation-id' = $operationId; Location = 'https://untrusted.example/ignored'; 'Retry-After' = '1' }
        $response.Content = @{ id = $lakehouseId; type = 'Lakehouse' } | ConvertTo-Json
    } elseif ($path -eq "/v1/operations/$operationId") {
        $response.Content = @{ status = $(if ($state.OperationFailure) { 'Failed' } else { 'Succeeded' }) } | ConvertTo-Json
    } elseif ($path -eq "/v1/operations/$operationId/result") {
        $response.Content = @{ id = $lakehouseId; type = 'Lakehouse' } | ConvertTo-Json
    } else { throw "Unexpected Fabric request: $Method $Uri" }
    [pscustomobject]$response
}
$functions = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false))
foreach ($function in $functions) { . ([scriptblock]::Create($function.Extent.Text)) }
$exportFunction = $functions | Where-Object Name -EQ 'Export-PolicyPdf'
$mockExport = @'
function Export-PolicyPdf {
    param($Policy, $Destination, $Browser)
    $global:PolicyDocumentTestState.Rendered += ConvertTo-PolicyHtml $Policy
    [IO.File]::WriteAllBytes($Destination, [Text.Encoding]::ASCII.GetBytes("%PDF-1.7`nMock PDF for $($Policy.PolicyNumber)`n%%EOF"))
}
'@
$workflowText = $ast.Extent.Text.Remove($exportFunction.Extent.StartOffset, $exportFunction.Extent.EndOffset - $exportFunction.Extent.StartOffset).Insert($exportFunction.Extent.StartOffset, $mockExport)
$workflow = [scriptblock]::Create($workflowText)
function Invoke-PolicyTestWorkflow {
    param([string]$Name, [hashtable]$Options = @{})
    $parameters = @{ Environment = 'ins'; OutputDirectory = (Join-Path $testRoot $Name); BrowserExecutable = (Get-Process -Id $PID).Path; WorkspaceId = $workspaceId }
    foreach ($key in $Options.Keys) { $parameters[$key] = $Options[$key] }
    if ($parameters.WorkspaceId -eq [guid]::Empty) { $parameters.Remove('WorkspaceId') }
    & $workflow @parameters
}
try {
    Reset-PolicyTest
    & $scriptPath -WhatIf -OutputDirectory (Join-Path $testRoot 'whatif')
    Assert-True ($global:PolicyDocumentTestState.CliCalls.Count -eq 0 -and -not (Test-Path (Join-Path $testRoot 'whatif'))) 'WhatIf must do no work.'
    Write-Host 'PASS: Parser and no-dependency, no-network, no-file WhatIf.'

    $html = ConvertTo-PolicyHtml $fixtures[0]
    Assert-True ($html.Contains('2026-03-15') -and $html.Contains('2027-03-15') -and $html.Contains('USD 145.25') -and $html.Contains('USD 150,000.00')) 'Persisted dates or money changed.'
    Assert-True ($html.Contains('O&#39;Brien') -and $html.Contains('Test &lt;product&gt; &amp; coverage') -and -not $html.Contains('<product>')) 'HTML values must be encoded.'
    Assert-True ($html.Contains('Not recorded') -and $html.Contains('NOT PROOF OF INSURANCE')) 'Missing null handling or demo disclaimer.'
    Write-Host 'PASS: Database values, HTML escaping, nullable fields, and demo-only policy language.'

    $result = @(Invoke-PolicyTestWorkflow 'create')
    $state = $global:PolicyDocumentTestState
    Assert-True ($result.Count -eq 10 -and $state.Remote.Count -eq 10 -and $state.Rendered.Count -eq 10) 'Expected ten generated and uploaded PDFs.'
    $sql = $state.SqlCalls[0]
    Assert-True ($sql.ServerInstance -eq 'sql-eia-ins-1.database.windows.net' -and $sql.Database -eq 'InsuranceCustomerBase' -and $sql.Encrypt -eq 'Mandatory' -and $sql.DisableVariables -and $sql.AbortOnError) 'Incorrect SQL target or options.'
    Assert-True (([regex]::Matches($sql.Query, 'c0570000-0003-4000-8000-\d{12}')).Count -eq 10 -and $sql.Query -notmatch 'PasswordHash|PasswordSalt|(?im)^\s*(INSERT|UPDATE|DELETE|MERGE)\b') 'Export must be read-only and demo-scoped without password fields.'
    foreach ($document in $result) {
        Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($document.LocalPath)) -eq [Convert]::ToBase64String($state.Remote[$document.OneLakeUrl])) 'Uploaded bytes differ from local PDF.'
        Assert-True ($state.UpdatedUrls[$document.PolicyId] -eq $document.OneLakeUrl) 'SQL policy URL does not match the actual uploaded file.'
    }
    Assert-True ($state.UpdatedUrls.Count -eq 10 -and $state.SqlCalls.Count -eq 11) 'Expected one SQL read and ten URL updates.'
    Assert-True ($state.CliCalls.Count -eq 3) 'Expected one token per audience.'
    Write-Host 'PASS: Ten local PDFs, verified OneLake uploads, and matching per-policy SQL URL/timestamp updates.'

    Reset-PolicyTest
    $global:PolicyDocumentTestState.Items = @(@{ id = $lakehouseId; type = 'Lakehouse'; displayName = 'InsuranceCustomerPolicies' })
    $null = Invoke-PolicyTestWorkflow 'reuse'
    Assert-True (@($global:PolicyDocumentTestState.Requests | Where-Object Method -EQ 'POST').Count -eq 0) 'Existing lakehouse was recreated.'
    Write-Host 'PASS: Existing exact-name lakehouse reused without configuration changes.'

    Reset-PolicyTest
    $global:PolicyDocumentTestState.Items = @(
        @{ id = $operationId; type = 'SQLEndpoint'; displayName = 'InsuranceCustomerPolicies' }
        @{ id = $lakehouseId; type = 'Lakehouse'; displayName = 'InsuranceCustomerPolicies' }
    )
    $result = @(Invoke-PolicyTestWorkflow 'reuse-with-endpoint')
    Assert-True ($result.Count -eq 10 -and @($result | Where-Object LakehouseId -NE $lakehouseId).Count -eq 0) 'Same-name SQL endpoint prevented reuse of the correct lakehouse.'
    Assert-True (@($global:PolicyDocumentTestState.Requests | Where-Object Method -EQ 'POST').Count -eq 0 -and $global:PolicyDocumentTestState.UpdatedUrls.Count -eq 10) 'Lakehouse companion handling must reuse the item and synchronize SQL URLs.'
    Write-Host 'PASS: Lakehouse with a same-name SQL endpoint is reused for uploads and SQL URL updates.'

    Reset-PolicyTest
    $global:PolicyDocumentTestState.Async = $true
    $null = Invoke-PolicyTestWorkflow 'async'
    Assert-True (@($global:PolicyDocumentTestState.Requests | Where-Object { $_.Uri.AbsolutePath -eq "/v1/operations/$operationId/result" }).Count -eq 1) 'Async result was not retrieved.'
    Write-Host 'PASS: Async creation uses the canonical operation ID, not an arbitrary Location.'

    Reset-PolicyTest
    $null = Invoke-PolicyTestWorkflow 'local' @{ LocalOnly = $true; SqlServerName = 'custom-demo-server' }
    Assert-True ($global:PolicyDocumentTestState.Requests.Count -eq 0 -and $global:PolicyDocumentTestState.CliCalls.Count -eq 1 -and $global:PolicyDocumentTestState.SqlCalls[0].ServerInstance -eq 'custom-demo-server.database.windows.net') 'LocalOnly contacted Fabric or ignored SQL override.'
    Assert-True ($global:PolicyDocumentTestState.SqlCalls.Count -eq 1 -and $global:PolicyDocumentTestState.UpdatedUrls.Count -eq 0) 'LocalOnly must not update SQL.'
    Assert-Fails { Invoke-PolicyTestWorkflow 'local' @{ LocalOnly = $true } } 'File already exists:*'
    $null = Invoke-PolicyTestWorkflow 'local' @{ LocalOnly = $true; Overwrite = $true }
    Write-Host 'PASS: Local-only mode, server override, existing-file protection, and explicit local replacement.'

    Reset-PolicyTest
    $null = Invoke-PolicyTestWorkflow 'remote-first'
    Assert-Fails { Invoke-PolicyTestWorkflow 'remote-protected' } 'Remote PDF already exists.'
    $null = Invoke-PolicyTestWorkflow 'remote-replace' @{ Overwrite = $true }
    Write-Host 'PASS: Conditional remote creation protects existing files; Overwrite enables replacement.'

    Reset-PolicyTest
    $global:PolicyDocumentTestState.Items = @(@{ id = $lakehouseId; type = 'Warehouse'; displayName = 'InsuranceCustomerPolicies' })
    Assert-Fails { Invoke-PolicyTestWorkflow 'collision' } 'Ambiguous or non-lakehouse*'
    Assert-True (@($global:PolicyDocumentTestState.Requests | Where-Object { $_.Method -ne 'GET' }).Count -eq 0) 'Name collision caused a write.'
    Reset-PolicyTest
    $global:PolicyDocumentTestState.Items = @(
        @{ id = $lakehouseId; type = 'Lakehouse'; displayName = 'InsuranceCustomerPolicies' }
        @{ id = $operationId; type = 'Lakehouse'; displayName = 'InsuranceCustomerPolicies' }
    )
    Assert-Fails { Invoke-PolicyTestWorkflow 'duplicate-lakehouses' } 'Multiple lakehouses*'
    Assert-True (@($global:PolicyDocumentTestState.Requests | Where-Object { $_.Method -ne 'GET' }).Count -eq 0 -and $global:PolicyDocumentTestState.SqlCalls.Count -eq 1) 'Duplicate lakehouses must stop without cloud or SQL writes.'
    Reset-PolicyTest
    $global:PolicyDocumentTestState.BadNext = 'https://untrusted.example/steal-token'
    Assert-Fails { Invoke-PolicyTestWorkflow 'unsafe-next' } 'Rejected request URL*'
    Reset-PolicyTest
    $global:PolicyDocumentTestState.BadNext = "https://onelake.dfs.fabric.microsoft.com/$workspaceId/$lakehouseId/Files/continuation.json"
    Assert-Fails { Invoke-PolicyTestWorkflow 'cross-service-next' } 'Rejected request URL*'
    Write-Host 'PASS: Item type collisions and off-host pagination stop without remote writes.'

    Reset-PolicyTest
    $global:PolicyDocumentTestState.PromptAnswers.Enqueue('bad')
    $global:PolicyDocumentTestState.PromptAnswers.Enqueue('1')
    $null = Invoke-PolicyTestWorkflow 'picker' @{ WorkspaceId = [guid]::Empty }
    Reset-PolicyTest
    $global:PolicyDocumentTestState.PromptAnswers.Enqueue('q')
    $null = Invoke-PolicyTestWorkflow 'cancel' @{ WorkspaceId = [guid]::Empty }
    Assert-True (@($global:PolicyDocumentTestState.Requests | Where-Object { $_.Method -ne 'GET' }).Count -eq 0) 'Cancel performed cloud writes.'
    Write-Host 'PASS: Workspace selection validates input; cancellation retains local PDFs only.'

    Reset-PolicyTest
    $global:PolicyDocumentTestState.NoRows = $true
    Assert-Fails { Invoke-PolicyTestWorkflow 'empty' } 'No seeded policies found*'
    Assert-True (-not (Test-Path (Join-Path $testRoot 'empty'))) 'Empty SQL result created an output folder.'
    Reset-PolicyTest
    $global:PolicyDocumentTestState.CliFailure = $true
    Assert-Fails { Invoke-PolicyTestWorkflow 'auth-fail' } 'Unable to acquire token*'
    Assert-True ($global:PolicyDocumentTestState.SqlCalls.Count -eq 0) 'SQL ran after authentication failed.'
    Reset-PolicyTest
    $global:PolicyDocumentTestState.SqlFailure = $true
    Assert-Fails { Invoke-PolicyTestWorkflow 'sql-fail' } 'Simulated SQL failure'
    Write-Host 'PASS: Empty database, SQL failure, and authentication failure stop the workflow.'

    Reset-PolicyTest
    $global:PolicyDocumentTestState.BadLength = $true
    Assert-Fails { Invoke-PolicyTestWorkflow 'bad-length' } 'Uploaded size mismatch*'
    Assert-True ($global:PolicyDocumentTestState.SqlCalls.Count -eq 1) 'Size mismatch must not update SQL.'
    Reset-PolicyTest
    $global:PolicyDocumentTestState.AppendFailure = $true
    Assert-Fails { Invoke-PolicyTestWorkflow 'append-fail' } 'Simulated append failure'
    Assert-True ($global:PolicyDocumentTestState.SqlCalls.Count -eq 1) 'Failed upload must not update SQL.'
    Assert-True (@($global:PolicyDocumentTestState.Requests | Where-Object { $_.Uri.Query -like '*action=flush*' }).Count -eq 0) 'Flush ran after failed append.'
    Reset-PolicyTest
    $global:PolicyDocumentTestState.Async = $true
    $global:PolicyDocumentTestState.OperationFailure = $true
    Assert-Fails { Invoke-PolicyTestWorkflow 'operation-fail' } 'Lakehouse creation failed*'
    Write-Host 'PASS: Upload and async failures propagate; local PDFs remain available for recovery.'

    Reset-PolicyTest
    $global:PolicyDocumentTestState.UpdateFailure = $true
    Assert-Fails { Invoke-PolicyTestWorkflow 'update-fail' } 'PDF uploaded, but SQL URL update failed*Simulated SQL update failure'
    Assert-True ($global:PolicyDocumentTestState.Remote.Count -eq 1 -and $global:PolicyDocumentTestState.SqlCalls.Count -eq 2) 'SQL update failure must stop subsequent uploads and updates.'
    Assert-True ((Get-ChildItem (Join-Path $testRoot 'update-fail') -Filter '*.pdf').Count -eq 10) 'SQL update failure must retain local PDFs.'
    Write-Host 'PASS: SQL update failures stop processing with recovery guidance and preserve uploaded/local files.'

    if ($RenderPdf) {
        $browser = "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
        if (-not (Test-Path -LiteralPath $browser)) { throw 'RenderPdf needs Microsoft Edge at its standard Windows location.' }
        $Overwrite = $false
        foreach ($fixture in $fixtures[0..2]) {
            $destination = Join-Path $testRoot "$($fixture.PolicyType).pdf"
            Export-PolicyPdf $fixture $destination $browser
            $bytes = [IO.File]::ReadAllBytes($destination)
            $pdfText = [Text.Encoding]::ASCII.GetString($bytes)
            $pages = ([regex]::Matches($pdfText, '/Type\s*/Page\b')).Count
            Assert-True ($bytes.Length -gt 10000 -and $pages -eq 2) "Expected a nonempty two-page $($fixture.PolicyType) PDF, got $pages pages."
        }
        Write-Host 'PASS: Real Edge export produces valid two-page Auto, Home, and Business PDFs without Python.'
    }
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Variable PolicyDocumentTestState -Scope Global
}
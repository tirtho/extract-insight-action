#Requires -Version 7.0
<#
.SYNOPSIS
Generates demo insurance policy PDFs from SQL and uploads them to a Fabric lakehouse.
.DESCRIPTION
Reads only the ten stable demo policy IDs used by populate-insurance-customer-base-db.ps1.
Uses Azure CLI sign-in, SqlServer module 22+, and Microsoft Edge or Google Chrome.
Creates or reuses InsuranceCustomerPolicies in a selected workspace. PDFs are stored
beside this script in InsuranceCustomerPolicies and uploaded to the lakehouse Files root.
After each verified upload, updates that policy's PolicyDocumentUrl and UpdatedAtUtc
in Azure SQL. Does not modify permissions, capacity, or an existing data agent.
Existing files are protected unless Overwrite is supplied. LocalOnly skips all
Fabric operations and SQL updates.
.EXAMPLE
./create-insurance-customer-policy-documents.ps1 -Environment ins -Suffix 1
.EXAMPLE
./create-insurance-customer-policy-documents.ps1 -Environment ins -LocalOnly
.EXAMPLE
./create-insurance-customer-policy-documents.ps1 -Environment ins -WorkspaceId '<workspace-guid>' -Overwrite
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidatePattern('^[a-z][a-z0-9-]{0,19}$')]
    [string]$Environment = 'dev',
    [ValidatePattern('^[0-9]{1,10}$')]
    [string]$Suffix = '1',
    [ValidatePattern('^[a-z0-9][a-z0-9-]{0,61}[a-z0-9]$')]
    [string]$SqlServerName,
    [guid]$WorkspaceId = [guid]::Empty,
    [ValidateNotNullOrWhiteSpace()]
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'InsuranceCustomerPolicies'),
    [string]$BrowserExecutable,
    [switch]$LocalOnly,
    [switch]$Overwrite
)

$ErrorActionPreference = 'Stop'
$lakehouseName = 'InsuranceCustomerPolicies'
$tokenCache = @{}

function Get-PolicyToken {
    param([string]$Resource)
    if (-not $tokenCache.ContainsKey($Resource) -or $tokenCache[$Resource].RefreshAt -lt [datetime]::UtcNow) {
        $result = & az account get-access-token --resource $Resource --only-show-errors --output json
        if ($LASTEXITCODE -ne 0) { throw "Unable to acquire token for $Resource. Check Azure CLI sign-in." }
        $token = ($result -join "`n") | ConvertFrom-Json
        if (-not $token.accessToken) { throw "Azure CLI returned no token for $Resource." }
        $tokenCache[$Resource] = @{ Value = $token.accessToken; RefreshAt = [datetime]::UtcNow.AddMinutes(5) }
    }
    $tokenCache[$Resource].Value
}

function Invoke-PolicyRequest {
    param([string]$Path, [string]$Method = 'GET', [object]$Body, [hashtable]$ExtraHeaders = @{}, [string]$InFile, [switch]$OneLake)
    $expectedHost = if ($OneLake) { 'onelake.dfs.fabric.microsoft.com' } else { 'api.fabric.microsoft.com' }
    $uri = $null
    if (-not [uri]::TryCreate([uri]'https://api.fabric.microsoft.com/v1/', $Path, [ref]$uri) -or
        $uri.Scheme -ne 'https' -or $uri.Port -ne 443 -or $uri.UserInfo -or $uri.Fragment -or
        $uri.Host -ne $expectedHost -or
        ($uri.Host -eq 'api.fabric.microsoft.com' -and -not $uri.AbsolutePath.StartsWith('/v1/', [StringComparison]::Ordinal))) {
        throw 'Rejected request URL. Only public Fabric v1 and OneLake HTTPS endpoints are allowed.'
    }
    $resource = if ($uri.Host -eq 'api.fabric.microsoft.com') { 'https://api.fabric.microsoft.com' } else { 'https://storage.azure.com/' }
    $headers = @{ Authorization = "Bearer $(Get-PolicyToken $resource)" }
    if ($uri.Host -eq 'onelake.dfs.fabric.microsoft.com') { $headers['x-ms-version'] = '2021-06-08' }
    foreach ($key in $ExtraHeaders.Keys) { $headers[$key] = $ExtraHeaders[$key] }
    $parameters = @{
        Uri = $uri; Method = $Method; Headers = $headers; TimeoutSec = 120
        MaximumRedirection = 0; MaximumRetryCount = 0
    }
    if ($InFile) { $parameters.InFile = $InFile; $parameters.ContentType = 'application/octet-stream' }
    elseif ($null -ne $Body) { $parameters.Body = ConvertTo-Json -InputObject $Body -Depth 10 -Compress; $parameters.ContentType = 'application/json' }
    Invoke-WebRequest @parameters
}

function Get-PolicyCollection {
    param([string]$Path)
    $visited = [System.Collections.Generic.HashSet[string]]::new()
    do {
        if (-not $visited.Add($Path) -or $visited.Count -gt 1000) { throw 'Invalid Fabric pagination sequence.' }
        $response = Invoke-PolicyRequest $Path
        $page = $response.Content | ConvertFrom-Json
        $page.value
        $Path = $page.continuationUri
    } while ($Path)
}

function Set-PolicyDocumentUrl {
    param([guid]$PolicyId, [guid]$CustomerId, [string]$OneLakeUrl)
    $escapedUrl = $OneLakeUrl.Replace("'", "''")
    $updateQuery = @"
SET NOCOUNT ON;
SET XACT_ABORT ON;
UPDATE obj.InsurancePolicy
SET PolicyDocumentUrl = N'$escapedUrl', UpdatedAtUtc = SYSUTCDATETIME()
WHERE Id = '$PolicyId' AND CustomerId = '$CustomerId';
IF @@ROWCOUNT <> 1
    THROW 50001, 'Expected exactly one matching insurance policy for document URL update.', 1;
"@
    try {
        $null = Invoke-Sqlcmd -ServerInstance "$SqlServerName.database.windows.net" -Database 'InsuranceCustomerBase' `
            -AccessToken (Get-PolicyToken 'https://database.windows.net/') -Encrypt Mandatory -AbortOnError -ErrorAction Stop `
            -ConnectionTimeout 15 -QueryTimeout 120 -DisableVariables -Query $updateQuery
    } catch {
        throw "PDF uploaded, but SQL URL update failed for policy $PolicyId. The uploaded file is retained. Check the database and rerun with -Overwrite after resolving the error. $($_.Exception.Message)"
    }
}

function New-PolicyLakehouse {
    param([string]$Path)
    $response = Invoke-PolicyRequest $Path 'POST' @{ displayName = $lakehouseName; description = 'Fictional insurance customer policy PDFs for demonstration only.' }
    if ([int]$response.StatusCode -eq 202) {
        $operationId = [guid]::Empty
        $header = [string]($response.Headers.'x-ms-operation-id' | Select-Object -First 1)
        if (-not [guid]::TryParse($header, [ref]$operationId) -or $operationId -eq [guid]::Empty) {
            throw 'Lakehouse creation returned no valid operation ID. Check the workspace before rerunning.'
        }
        $operationPath = "operations/$operationId"
        for ($attempt = 0; $attempt -lt 60; $attempt++) {
            $delay = 5
            $headerDelay = 0
            if ([int]::TryParse([string]($response.Headers.'Retry-After' | Select-Object -First 1), [ref]$headerDelay)) {
                $delay = [Math]::Clamp($headerDelay, 1, 60)
            }
            Start-Sleep -Seconds $delay
            $response = Invoke-PolicyRequest $operationPath
            $operation = $response.Content | ConvertFrom-Json
            if ($operation.status -eq 'Succeeded') {
                $response = Invoke-PolicyRequest "$operationPath/result"
                return $response.Content | ConvertFrom-Json
            }
            if ($operation.status -in @('Failed', 'Cancelled')) { throw "Lakehouse creation failed: $($operation | ConvertTo-Json -Depth 10 -Compress)" }
        }
        throw 'Lakehouse creation timed out. Check the workspace before rerunning; local PDFs are retained.'
    }
    $response.Content | ConvertFrom-Json
}

function ConvertTo-PolicyHtml {
    param([object]$Policy)
    function Encode-PolicyValue {
        param([object]$Value)
        if ($null -eq $Value -or $Value -is [DBNull] -or [string]::IsNullOrWhiteSpace([string]$Value)) { return 'Not recorded' }
        [System.Net.WebUtility]::HtmlEncode([string]$Value)
    }
    function Format-PolicyMoney {
        param([object]$Value)
        if ($null -eq $Value -or $Value -is [DBNull]) { return 'Not recorded' }
        Encode-PolicyValue ('{0} {1}' -f $Policy.CurrencyCode, ([decimal]$Value).ToString('N2', [cultureinfo]'en-US'))
    }
    $rows = [ordered]@{
        'Policy number' = (Encode-PolicyValue $Policy.PolicyNumber)
        'Policy ID' = (Encode-PolicyValue $Policy.PolicyId)
        'Named customer' = (Encode-PolicyValue "$($Policy.FirstName) $($Policy.LastName)")
        'Customer ID' = (Encode-PolicyValue $Policy.CustomerId)
        'Insured business' = (Encode-PolicyValue $Policy.InsuredBusinessName)
        'Product' = (Encode-PolicyValue $Policy.ProductName)
        'Policy type / business line' = (Encode-PolicyValue "$($Policy.PolicyType) / $($Policy.BusinessLine)")
        'Status' = (Encode-PolicyValue $Policy.PolicyStatus)
        'Effective date' = (Encode-PolicyValue ([datetime]$Policy.EffectiveDate).ToString('yyyy-MM-dd'))
        'Expiration date' = $(if ($null -eq $Policy.ExpirationDate -or $Policy.ExpirationDate -is [DBNull]) { 'Not recorded' } else { Encode-PolicyValue ([datetime]$Policy.ExpirationDate).ToString('yyyy-MM-dd') })
        'Premium per billing period' = (Format-PolicyMoney $Policy.PremiumAmount)
        'Billing frequency' = (Encode-PolicyValue $Policy.PremiumFrequency)
        'Coverage limit' = (Format-PolicyMoney $Policy.CoverageLimitAmount)
        'Deductible' = (Format-PolicyMoney $Policy.DeductibleAmount)
        'Vehicle VIN' = (Encode-PolicyValue $Policy.InsuredVehicleVIN)
        'Customer address' = (Encode-PolicyValue $Policy.CustomerAddress)
        'Insured property address' = (Encode-PolicyValue $Policy.PropertyAddress)
        'Email / phone' = (Encode-PolicyValue "$($Policy.EmailAddress) / $($Policy.Phone)")
    }
    $tableRows = foreach ($key in $rows.Keys) { "<tr><th>$(Encode-PolicyValue $key)</th><td>$($rows[$key])</td></tr>" }
    @"
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><title>Demo policy $(Encode-PolicyValue $Policy.PolicyNumber)</title>
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
<style>
@page { size: Letter; margin: 16mm; }
body { font-family: 'Segoe UI', sans-serif; font-size: 10pt; color: #202a30; line-height: 1.4; }
h1 { font-size: 23pt; margin: 5mm 0 2mm; } h2 { font-size: 13pt; margin-top: 7mm; }
.notice { border: 2px solid #a22b36; color: #83232c; padding: 3mm; font-weight: 700; }
.caption { color: #4a6263; margin-bottom: 5mm; }
table { width: 100%; border-collapse: collapse; table-layout: fixed; }
th, td { padding: 2mm 3mm; border-bottom: 1px solid #ccd5d5; text-align: left; vertical-align: top; overflow-wrap: anywhere; }
th { width: 35%; background: #edf3f1; font-weight: 600; } tr { break-inside: avoid; }
.terms { break-before: page; } p { margin: 3mm 0; }
</style></head><body>
<div class="notice">DEMO ONLY - FICTIONAL POLICY - NOT PROOF OF INSURANCE</div>
<h1>Insurance Policy</h1><div class="caption">Sample declarations | $(Encode-PolicyValue $Policy.PolicyNumber)</div>
<table>$($tableRows -join "`n")</table>
<section class="terms"><div class="notice">DEMO ONLY - NOT A LEGAL INSURANCE CONTRACT</div>
<h2>Policy Schedule and Interpretation</h2>
<p>This sample document describes the fictional $(Encode-PolicyValue $Policy.ProductName) policy recorded for $(Encode-PolicyValue "$($Policy.FirstName) $($Policy.LastName)"). The declarations reproduce the saved customer database values at generation time.</p>
<h2>Recorded Coverage and Premium</h2>
<p>The database records a coverage limit of $(Format-PolicyMoney $Policy.CoverageLimitAmount) and a deductible of $(Format-PolicyMoney $Policy.DeductibleAmount). The premium is $(Format-PolicyMoney $Policy.PremiumAmount) per $(Encode-PolicyValue $Policy.PremiumFrequency) billing period. These figures are distinct; a premium is not a coverage limit or a deductible.</p>
<h2>Term and Insured Subject</h2>
<p>The dates, status, policy type, insured business, vehicle identification, and property address are shown exactly where recorded. "Not recorded" means the database supplies no value; no replacement value has been invented.</p>
<h2>Scope of This Demonstration</h2>
<p>The source database does not define covered perils, exclusions, endorsements, claim conditions, cancellation provisions, or an issuing insurer. This document does not invent these terms, grant coverage, or establish an obligation to pay a claim. It is not a binder, certificate, renewal notice, or evidence of payment.</p>
<h2>Document Provenance</h2>
<p>Source: InsuranceCustomerBase / obj.InsurancePolicy, obj.Customer, obj.CustomerAddress, and obj.Address. Policy and customer IDs are included for matching the PDF to the structured records. Generated UTC: $([datetime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss')).</p>
</section></body></html>
"@
}

function Export-PolicyPdf {
    param([object]$Policy, [string]$Destination, [string]$Browser)
    $temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) "insurance-policy-$([guid]::NewGuid())"
    $null = [IO.Directory]::CreateDirectory($temporaryDirectory)
    $process = $null
    try {
        $htmlPath = Join-Path $temporaryDirectory 'policy.html'
        $pdfPath = Join-Path $temporaryDirectory 'policy.pdf'
        [IO.File]::WriteAllText($htmlPath, (ConvertTo-PolicyHtml $Policy), [Text.UTF8Encoding]::new($false))
        $startInfo = [Diagnostics.ProcessStartInfo]::new($Browser)
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.RedirectStandardOutput = $true
        foreach ($argument in @('--headless', '--disable-gpu', '--no-first-run', '--disable-extensions', '--disable-background-networking', '--disable-sync',
            '--no-pdf-header-footer', "--user-data-dir=$(Join-Path $temporaryDirectory 'profile')", "--print-to-pdf=$pdfPath", ([uri]$htmlPath).AbsoluteUri)) {
            $startInfo.ArgumentList.Add($argument)
        }
        $process = [Diagnostics.Process]::Start($startInfo)
        $errorOutput = $process.StandardError.ReadToEndAsync()
        $standardOutput = $process.StandardOutput.ReadToEndAsync()
        if (-not $process.WaitForExit(60000)) { $process.Kill($true); $process.WaitForExit(); throw 'PDF rendering timed out.' }
        $null = $errorOutput.GetAwaiter().GetResult()
        $null = $standardOutput.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0 -or -not [IO.File]::Exists($pdfPath)) { throw 'Browser failed to generate the policy PDF.' }
        $signature = [IO.File]::ReadAllBytes($pdfPath)
        if ($signature.Length -lt 5 -or [Text.Encoding]::ASCII.GetString($signature, 0, 5) -ne '%PDF-') { throw 'Renderer output is not a PDF.' }
        Move-Item -LiteralPath $pdfPath -Destination $Destination -Force:$Overwrite
    } finally {
        if ($process) { $process.Dispose() }
        Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if (-not $SqlServerName) { $SqlServerName = "sql-eia-$Environment-$Suffix" }
if ($PSBoundParameters.ContainsKey('WorkspaceId') -and $WorkspaceId -eq [guid]::Empty) { throw 'WorkspaceId must not be empty.' }
$action = if ($LocalOnly) { 'Generate local demo policy PDFs' } else { 'Generate local demo policy PDFs, create/reuse InsuranceCustomerPolicies lakehouse, upload PDFs, and update SQL policy document URLs' }
if (-not $PSCmdlet.ShouldProcess("$SqlServerName/InsuranceCustomerBase -> $OutputDirectory -> workspace $WorkspaceId", $action)) { return }
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Install Azure CLI and sign in first.' }
if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq [System.Runtime.InteropServices.Architecture]::Arm64 -and $IsWindows) {
    [AppContext]::SetSwitch('Switch.Microsoft.Data.SqlClient.UseManagedNetworkingOnWindows', $true)
}
if (-not (Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue) -or -not (Get-Command Invoke-Sqlcmd).Parameters.ContainsKey('Encrypt')) {
    throw 'Install SqlServer PowerShell module 22 or later.'
}
if (-not $BrowserExecutable) {
    $browserCandidates = @(
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe"
        "$env:LOCALAPPDATA\Microsoft\Edge\Application\msedge.exe"
    )
    $BrowserExecutable = $browserCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
}
if (-not $BrowserExecutable -or -not (Test-Path -LiteralPath $BrowserExecutable -PathType Leaf)) {
    throw 'Install Microsoft Edge or Google Chrome, or pass its full path with -BrowserExecutable.'
}
$query = @'
SET NOCOUNT ON;
SELECT policy.Id AS PolicyId, policy.CustomerId, policy.PolicyNumber,
       customer.FirstName, customer.LastName, customer.EmailAddress, customer.Phone,
       policy.PolicyType, policy.BusinessLine, policy.ProductName, policy.PolicyStatus,
       policy.EffectiveDate, policy.ExpirationDate, policy.PremiumAmount,
       policy.PremiumFrequency, policy.CurrencyCode, policy.CoverageLimitAmount,
       policy.DeductibleAmount, policy.InsuredVehicleVIN, policy.InsuredBusinessName,
       mailing.CustomerAddress,
       CASE WHEN property.Id IS NULL THEN NULL ELSE
           CONCAT_WS(', ', property.AddressLine1, property.AddressLine2, property.City,
                     property.StateProvince, property.PostalCode, property.CountryRegion)
       END AS PropertyAddress
FROM obj.InsurancePolicy AS policy
JOIN obj.Customer AS customer ON customer.Id = policy.CustomerId
LEFT JOIN obj.Address AS property ON property.Id = policy.InsuredPropertyAddressId
OUTER APPLY (
    SELECT TOP (1) CONCAT_WS(', ', address.AddressLine1, address.AddressLine2, address.City,
                            address.StateProvince, address.PostalCode, address.CountryRegion) AS CustomerAddress
    FROM obj.CustomerAddress AS link
    JOIN obj.Address AS address ON address.Id = link.AddressId
    WHERE link.CustomerId = customer.Id
    ORDER BY CASE WHEN address.Id = policy.InsuredPropertyAddressId THEN 0 ELSE 1 END,
             link.ModifiedDate DESC, address.Id
) AS mailing
WHERE policy.Id IN (
    'c0570000-0003-4000-8000-000000000001', 'c0570000-0003-4000-8000-000000000002',
    'c0570000-0003-4000-8000-000000000003', 'c0570000-0003-4000-8000-000000000004',
    'c0570000-0003-4000-8000-000000000005', 'c0570000-0003-4000-8000-000000000006',
    'c0570000-0003-4000-8000-000000000007', 'c0570000-0003-4000-8000-000000000008',
    'c0570000-0003-4000-8000-000000000009', 'c0570000-0003-4000-8000-000000000010'
)
ORDER BY policy.PolicyNumber, policy.Id;
'@
$policies = @(Invoke-Sqlcmd -ServerInstance "$SqlServerName.database.windows.net" -Database 'InsuranceCustomerBase' `
    -AccessToken (Get-PolicyToken 'https://database.windows.net/') -Encrypt Mandatory -AbortOnError -ErrorAction Stop `
    -ConnectionTimeout 15 -QueryTimeout 120 -DisableVariables -Query $query)
if (-not $policies.Count) { throw 'No seeded policies found. Run populate-insurance-customer-base-db.ps1 against this database first.' }
if ($policies.Count -ne 10) { Write-Warning "Found $($policies.Count) of the ten demo policies. Only existing records will be exported." }
$OutputDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
$documents = @($policies | ForEach-Object {
    $policy = $_
    $safeNumber = [regex]::Replace([string]$policy.PolicyNumber, '[^A-Za-z0-9_-]', '_')
    if (-not $safeNumber) { $safeNumber = 'Policy' }
    $fileName = "$safeNumber-$([guid]$policy.PolicyId).pdf"
    $localPath = Join-Path $OutputDirectory $fileName
    if ((Test-Path -LiteralPath $localPath) -and -not $Overwrite) { throw "File already exists: $localPath. Use -Overwrite to replace local and remote PDFs." }
    [pscustomobject]@{ Policy = $policy; FileName = $fileName; LocalPath = $localPath }
})
$null = [IO.Directory]::CreateDirectory($OutputDirectory)
foreach ($document in $documents) {
    Export-PolicyPdf -Policy $document.Policy -Destination $document.LocalPath -Browser $BrowserExecutable
    Write-Host "Generated $($document.FileName)"
}
if ($LocalOnly) {
    $documents | Select-Object FileName, LocalPath
    return
}
if ($WorkspaceId -eq [guid]::Empty) {
    $workspaces = @(Get-PolicyCollection 'workspaces')
    if (-not $workspaces.Count) { throw 'No accessible Fabric workspaces found. Local PDFs are retained.' }
    Write-Host 'Accessible Fabric workspaces:'
    for ($index = 0; $index -lt $workspaces.Count; $index++) { Write-Host ('{0}. {1} [{2}]' -f ($index + 1), $workspaces[$index].displayName, $workspaces[$index].id) }
    do {
        $selection = (Read-Host 'Select a workspace number, or Q to keep only local PDFs').Trim()
        if ($selection -eq 'q') { Write-Host "Local PDFs retained in $OutputDirectory. Nothing uploaded."; return }
        $number = 0
        $valid = [int]::TryParse($selection, [ref]$number) -and $number -ge 1 -and $number -le $workspaces.Count
        if (-not $valid) { Write-Warning 'Select a listed workspace number or Q.' }
    } until ($valid)
    $WorkspaceId = [guid]$workspaces[$number - 1].id
}
$workspacePath = "workspaces/$WorkspaceId"
$workspaceResponse = Invoke-PolicyRequest $workspacePath
$workspace = $workspaceResponse.Content | ConvertFrom-Json
if (-not $workspace.capacityId) { throw 'The selected workspace has no Fabric capacity. Local PDFs are retained.' }
$items = @(Get-PolicyCollection "$workspacePath/items")
$namedItems = @($items | Where-Object displayName -EQ $lakehouseName)
$matchingLakehouses = @($namedItems | Where-Object type -EQ 'Lakehouse')
if ($matchingLakehouses.Count -gt 1) { throw "Multiple lakehouses named $lakehouseName. No item was changed." }
if (-not $matchingLakehouses.Count -and $namedItems.Count) { throw "Ambiguous or non-lakehouse item named $lakehouseName. No item was changed." }
$lakehouse = if ($matchingLakehouses.Count) { $matchingLakehouses[0] } else { New-PolicyLakehouse "$workspacePath/lakehouses" }
$lakehouseId = [guid]$lakehouse.id
if ($lakehouseId -eq [guid]::Empty) { throw 'Fabric returned no lakehouse ID. Check the workspace before rerunning.' }
Write-Host "Using lakehouse $lakehouseName [$lakehouseId]."
foreach ($document in $documents) {
    $fileUri = "https://onelake.dfs.fabric.microsoft.com/$WorkspaceId/$lakehouseId/Files/$([uri]::EscapeDataString($document.FileName))"
    $createHeaders = @{ 'x-ms-content-type' = 'application/pdf' }
    if (-not $Overwrite) { $createHeaders['If-None-Match'] = '*' }
    $null = Invoke-PolicyRequest "$fileUri`?resource=file" 'PUT' -ExtraHeaders $createHeaders -OneLake
    $null = Invoke-PolicyRequest "$fileUri`?action=append&position=0" 'PATCH' -InFile $document.LocalPath -OneLake
    $length = (Get-Item -LiteralPath $document.LocalPath).Length
    $null = Invoke-PolicyRequest "$fileUri`?action=flush&position=$length&close=true" 'PATCH' -ExtraHeaders @{ 'x-ms-content-type' = 'application/pdf' } -OneLake
    $properties = Invoke-PolicyRequest $fileUri 'HEAD' -OneLake
    if ([long]([string]($properties.Headers.'Content-Length' | Select-Object -First 1)) -ne $length) { throw "Uploaded size mismatch for $($document.FileName). Local PDF retained." }
    Set-PolicyDocumentUrl -PolicyId $document.Policy.PolicyId -CustomerId $document.Policy.CustomerId -OneLakeUrl $fileUri
    Write-Host "Uploaded and verified $($document.FileName); updated SQL PolicyDocumentUrl."
    [pscustomobject]@{ PolicyId = [string]$document.Policy.PolicyId; PolicyNumber = $document.Policy.PolicyNumber; LocalPath = $document.LocalPath; WorkspaceId = "$WorkspaceId"; LakehouseId = "$lakehouseId"; OneLakeUrl = $fileUri }
}
#Requires -Version 7.0
<#
.SYNOPSIS
Generates state-specific insurance business PDFs and uploads them to OneLake.
.DESCRIPTION
Creates Guidelines.pdf, Compliance.pdf, and Regulatory.pdf for auto, home, and
business insurance in all 50 US states. Content defines internal operating
standards and regulatory review tasks, not verified statements of current law.
Uses Edge or Chrome for local PDFs and Azure CLI authentication for Fabric.
Creates or reuses InsuranceBusinessDocuments; never changes SQL or data agents.
Renders one PDF ahead of uploads. ReuseLocal skips rendering existing complete
PDFs; combine with Overwrite when restarting a partially uploaded run.
StartAt selects the first relative PDF path to process, skipping earlier paths.
.EXAMPLE
./create-insurance-business-documents.ps1 -WorkspaceId '<workspace-guid>'
.EXAMPLE
./create-insurance-business-documents.ps1 -States MA,CA -LocalOnly
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [guid]$WorkspaceId = [guid]::Empty,
    [ValidateNotNullOrEmpty()]
    [string[]]$States,
    [ValidateNotNullOrWhiteSpace()]
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'InsuranceBusinessDocuments'),
    [string]$BrowserExecutable,
    [ValidatePattern('^InsuranceBusinessKnowledge/(Auto|Home|Business)/[A-Z]{2}/(Compliance|Guidelines|Regulatory)/(Auto|Home|Business)_[A-Z]{2}_(Compliance|Guidelines|Regulatory)\.pdf$')]
    [string]$StartAt,
    [switch]$LocalOnly,
    [switch]$ReuseLocal,
    [switch]$Overwrite
)

$ErrorActionPreference = 'Stop'
$lakehouseName = 'InsuranceBusinessDocuments'
$tokenCache = @{}

function Get-BusinessStates {
    [ordered]@{
        AL = 'Alabama'; AK = 'Alaska'; AZ = 'Arizona'; AR = 'Arkansas'; CA = 'California'
        CO = 'Colorado'; CT = 'Connecticut'; DE = 'Delaware'; FL = 'Florida'; GA = 'Georgia'
        HI = 'Hawaii'; ID = 'Idaho'; IL = 'Illinois'; IN = 'Indiana'; IA = 'Iowa'
        KS = 'Kansas'; KY = 'Kentucky'; LA = 'Louisiana'; ME = 'Maine'; MD = 'Maryland'
        MA = 'Massachusetts'; MI = 'Michigan'; MN = 'Minnesota'; MS = 'Mississippi'; MO = 'Missouri'
        MT = 'Montana'; NE = 'Nebraska'; NV = 'Nevada'; NH = 'New Hampshire'; NJ = 'New Jersey'
        NM = 'New Mexico'; NY = 'New York'; NC = 'North Carolina'; ND = 'North Dakota'; OH = 'Ohio'
        OK = 'Oklahoma'; OR = 'Oregon'; PA = 'Pennsylvania'; RI = 'Rhode Island'; SC = 'South Carolina'
        SD = 'South Dakota'; TN = 'Tennessee'; TX = 'Texas'; UT = 'Utah'; VT = 'Vermont'
        VA = 'Virginia'; WA = 'Washington'; WV = 'West Virginia'; WI = 'Wisconsin'; WY = 'Wyoming'
    }
}

function Get-BusinessSections {
    param([string]$StateCode, [string]$StateName, [string]$Line, [string]$Kind)
    $lineTitles = @{ auto = 'Auto'; home = 'Home'; business = 'Business' }
    $lineTitle = $lineTitles[$Line]
    $focus = [Collections.Generic.List[string]]::new()
    $focus.Add('address-level flood, severe weather, fire, theft, liability, and service interruption exposure')
    if ($StateCode -in @('AK','CO','CT','ID','IL','IN','IA','ME','MA','MI','MN','MT','NE','NH','NJ','NY','ND','OH','PA','RI','SD','UT','VT','WA','WI','WY')) {
        $focus.Add('winter driving, freeze damage, snow loading, and seasonal access')
    }
    if ($StateCode -in @('AL','CT','DE','FL','GA','HI','LA','ME','MD','MA','MS','NH','NJ','NY','NC','RI','SC','TX','VA')) {
        $focus.Add('coastal wind, storm surge, evacuation, and post-storm repair capacity where the address is exposed')
    }
    if ($StateCode -in @('AK','AZ','CA','CO','HI','ID','MT','NV','NM','OK','OR','TX','UT','WA','WY')) {
        $focus.Add('wildland interface, smoke, evacuation access, and vegetation management where relevant')
    }
    if ($StateCode -in @('AL','AR','CO','GA','IL','IN','IA','KS','KY','LA','MS','MO','NE','NC','ND','OH','OK','SC','SD','TN','TX','WI')) {
        $focus.Add('hail, straight-line wind, tornado, and accumulated catastrophe concentration')
    }
    $riskText = "For $StateName ($StateCode), screen for $($focus -join '; '). These are internal screening priorities, not a finding that a particular location has the exposure. Validate the individual risk with current evidence."
    $lineGuidance = @{
        auto = @(
            @('Application and eligibility', 'Record named insureds, garaging address, vehicle identification, ownership, annual mileage, permitted drivers, vehicle use, prior coverage, and loss history. Refer delivery, rideshare, fleet, modified vehicles, and commercial use to the appropriate product specialist. Do not bind when material facts remain unresolved.'),
            @('Coverage design', 'Compare bodily injury, property damage, collision, comprehensive, medical-related coverages, uninsured and underinsured motorist options, rental, and roadside assistance against the insured need. Record selected limits and deductibles. A checklist entry is not a coverage grant; the issued forms and endorsements control.'),
            @('Risk selection and referral', 'Use authorized rating inputs only. Review driver and vehicle reports through approved access. Route eligibility exceptions, disputed report data, unusual use, and coverage gaps to an underwriter. Document reasons and prohibit unsupported proxy discrimination.'),
            @('Claims handling', 'Capture loss date, location, parties, injuries, police-report availability, photographs, repair estimates, and coverage facts. Escalate injury, litigation, suspected fraud, and disputed coverage. Do not promise payment before coverage and authority are established.')
        )
        home = @(
            @('Application and eligibility', 'Record occupancy, construction, year built, roof condition, replacement-cost estimate, protection systems, maintenance, prior losses, and mortgage interests. Refer vacant, short-term rental, major renovation, unusual construction, and high-value property exposures.'),
            @('Coverage design', 'Review dwelling, other structures, personal property, loss of use, personal liability, and medical payments against the proposed form. Discuss valuation, deductibles, sublimits, exclusions, and optional endorsements. Assess flood and earthquake needs separately; never imply they are included without checking the contract.'),
            @('Inspection and mitigation', 'Obtain address-level hazard evidence and inspection consent as appropriate. Record roof, electrical, plumbing, heating, water-leak, defensible-space, and security findings. Use risk-specific evidence, not a state code alone, to request mitigation or refer the risk.'),
            @('Claims handling', 'Record cause, date, damaged property, emergency mitigation, occupancy impact, photographs, inventory, and estimates. Assess additional living expense only under the issued terms. Escalate disputed causation, catastrophe losses, litigation, and coverage interpretation.')
        )
        business = @(
            @('Application and eligibility', 'Record legal entities, operations, locations, revenue, payroll, headcount, property values, vehicles, subcontractors, contracts, prior losses, and requested lines. Verify business classification and refer hazardous operations, complex ownership, and material overseas exposure.'),
            @('Coverage design', 'Evaluate property, general liability, business income, commercial auto, workers compensation, professional liability, cyber, and umbrella needs. Not every line is included in a business package. Record named insureds, locations, limits, deductibles, waiting periods, exclusions, and endorsements.'),
            @('Risk engineering and contracts', 'Review fire protection, equipment maintenance, fleet controls, workplace safety, subcontractor transfer, data security, and continuity plans. Route contractual indemnity, additional insured, waiver, and certificate requests to authorized reviewers. Certificates do not amend coverage.'),
            @('Claims handling', 'Capture affected entities, locations, operations, injury or damage, potential third parties, downtime records, and immediate mitigation. Preserve relevant evidence. Escalate employee injury, cyber incidents, litigation, environmental issues, and multi-policy coverage questions.')
        )
    }
    if ($Kind -eq 'Guidelines') {
        ,@('Purpose and authority', "Internal $lineTitle insurance operating guidelines for $StateName ($StateCode). Apply only within delegated underwriting and claims authority. These standards do not create coverage, replace policy wording, or establish government requirements.")
        foreach ($section in $lineGuidance[$Line]) { ,$section }
        ,@('State risk review', $riskText)
        ,@('Decision record and quality control', "Record the $StateCode jurisdiction, product, form version, evidence, coverage discussion, referral decision, approver, and communication history. Require a second review for authority exceptions. Keep internal business rules separate from legally required rules and retain the evidence under the approved retention schedule.")
        return
    }
    if ($Kind -eq 'Compliance') {
        ,@('Scope and review status', "Internal compliance control checklist for $StateName ($StateCode), $lineTitle insurance. Jurisdictional legal validation is pending. This document assigns review tasks; it is not an authoritative statement of state or federal law. No statutory deadline, mandatory limit, or legal conclusion is established here.")
        ,@('Licensing and authority', "Before transacting $lineTitle insurance in $StateName, have Compliance confirm carrier authority, producer licensing, appointments where applicable, and the relevant admitted or nonadmitted placement process. Record the verified source, scope, verification date, and reviewer. Block release while required validation is unresolved.")
        ,@('Forms, rates, and disclosures', "Confirm the applicable $StateCode product filing or approval process, authorized form and endorsement versions, rating rules, and required notices with Compliance. Verify any product-specific disclosure and consent requirements. Do not invent filing identifiers or infer that another state's approval applies.")
        ,@('Fair treatment and consumer information', 'Use approved decision factors and communications. If consumer reports or insurance scores are used, obtain review of applicable Fair Credit Reporting Act obligations, permissible purpose, disputes, and adverse-action notices. Confirm state restrictions separately. Route complaints and accessibility needs through documented service channels.')
        ,@('Privacy, security, and financial crime', 'Ask Compliance to determine applicable Gramm-Leach-Bliley Act and state privacy or insurance data-security obligations, notice and consent requirements, service-provider controls, and incident reporting duties. Refer potential sanctions matches for Office of Foreign Assets Control review. Applicability and required actions must be established by the responsible legal reviewer.')
        ,@('Policy lifecycle and claims controls', "Have Compliance verify $StateName rules for issuance, billing, cancellation, nonrenewal, reinstatement, refunds, claim communications, settlement, and catastrophe directives for this product. Obtain exact triggers, calendar conventions, notice methods, exceptions, and citations from current authoritative sources before setting operational timers.")
        ,@('Control evidence and escalation', 'Record each control owner, applicability decision, evidence location, verified legal source, reviewer, approval date, and next review. Track status as Pending verification, Approved, Not applicable with reason, or Remediation required. Escalate unresolved conflicts to Legal; do not convert an internal target into a statutory requirement.')
        return
    }
    $specificReview = @{
        auto = 'Validate financial responsibility and liability requirements; no-fault or personal injury protection applicability; uninsured and underinsured motorist offers, selections, and rejections; proof-of-insurance reporting; permissive use; repair and total-loss handling; and use-based or telematics restrictions. No coverage minimum or no-fault classification is assigned by this document.'
        home = 'Validate policy-form and deductible disclosures; wind, hail, flood, and earthquake communications; replacement-cost and valuation requirements; inspection restrictions; mortgage-interest notices; cancellation and nonrenewal protections; catastrophe moratoria or emergency orders; and any residual-market requirements. No catastrophe order or coverage mandate is asserted here.'
        business = 'Validate requirements separately for each included commercial line, including workers compensation where relevant, commercial auto, surplus-lines placement, certificates, additional insured endorsements, premium audits, and industry-specific liability. Do not assume that a general business package meets compulsory insurance obligations.'
    }
    ,@('Regulatory review register', "Jurisdiction: $StateName ($StateCode). Line: $lineTitle. Owner: Legal and Regulatory Affairs. Status: Pending jurisdictional verification. This register identifies research and approval tasks, not enacted requirements. No government publication, legal citation, or regulatory approval has been fabricated.")
    ,@('State insurance authority', "Locate the current $StateName insurance regulator through the National Association of Insurance Commissioners directory at https://content.naic.org/state-insurance-departments. Consult the regulator's official publications and the state's official statutes and administrative rules. The directory is a discovery source, not evidence that an individual rule applies.")
    ,@('Line-specific research', $specificReview[$Line])
    ,@('Other government authorities', 'Determine whether motor vehicle, labor or workers compensation, building or fire, emergency management, privacy, and other authorities have relevant jurisdiction. Evaluate federal requirements only when the entity, transaction, information use, and product meet the applicable scope. Avoid treating every listed authority as applicable to every insured.')
    ,@('Requirement record schema', 'For each verified requirement, record the issuing authority, official title and URL, citation, publication and effective dates, jurisdiction, applicable entity and product, obligation, trigger, deadline calculation, exceptions, required evidence, control owner, and legal approver. Leave unverified fields unresolved rather than filling them with inferred values.')
    ,@('Change monitoring and release', "Monitor official $StateName publications, bulletins, emergency orders, and relevant federal changes on an approved schedule. Record superseded versions and the impact on $lineTitle forms, rates, notices, systems, and staff guidance. Release operational changes only after documented legal approval and testing.")
    ,@('Interpretation and conflict resolution', 'Do not answer a legal-requirement question from this register alone. Retrieve the verified primary source and applicable approved requirement record. Escalate conflicts between internal guidance, contract wording, and law. Internal underwriting preferences must never be cited as government mandates.')
}

function ConvertTo-BusinessHtml {
    param([object]$Document)
    $title = "$($Document.StateName) - $($Document.Line) Insurance - $($Document.Kind)"
    $encode = { param($Value) [Net.WebUtility]::HtmlEncode([string]$Value) }
    $sections = @(Get-BusinessSections $Document.StateCode $Document.StateName $Document.Line $Document.Kind)
    $body = foreach ($section in $sections) { "<section><h2>$(& $encode $section[0])</h2><p>$(& $encode $section[1])</p></section>" }
    @"
<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><title>$(& $encode $title)</title>
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
<style>
@page { size: Letter; margin: 18mm; }
body { font-family: 'Segoe UI', sans-serif; font-size: 11pt; line-height: 1.5; color: #233138; }
h1 { font-size: 22pt; line-height: 1.2; margin-bottom: 5mm; }
h2 { font-size: 12pt; color: #12645c; margin: 5mm 0 2mm; }
p { margin: 0 0 4mm; } section { break-inside: avoid; }
.meta { border-top: 2px solid #12645c; border-bottom: 1px solid #bdc9ca; padding: 3mm 0; font-size: 9pt; }
footer { margin-top: 6mm; font-size: 9pt; color: #526168; }
</style></head><body><h1>$(& $encode $title)</h1>
<div class="meta">Document ID: IBD-$($Document.StateCode)-$($Document.Line)-$($Document.Kind) | Version: 1.0<br>
Jurisdiction: $(& $encode $Document.StateName) ($($Document.StateCode)) | Prepared UTC: $([datetime]::UtcNow.ToString('yyyy-MM-dd'))<br>
Authority: Internal operating standards | Legal source status: Not verified</div>
$($body -join "`n")
<footer>$($Document.StateCode) / $($Document.Line) / $($Document.Kind) | Owner: Insurance Operations and Compliance</footer>
</body></html>
"@
}

function Export-BusinessPdf {
    param([object]$Document, [string]$Destination, [string]$Browser)
    $temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) "insurance-business-$([guid]::NewGuid())"
    $null = [IO.Directory]::CreateDirectory($temporaryDirectory)
    $process = $null
    try {
        $htmlPath = Join-Path $temporaryDirectory 'document.html'
        $pdfPath = Join-Path $temporaryDirectory 'document.pdf'
        [IO.File]::WriteAllText($htmlPath, (ConvertTo-BusinessHtml $Document), [Text.UTF8Encoding]::new($false))
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
        if ($process.ExitCode -ne 0 -or -not [IO.File]::Exists($pdfPath)) { throw 'Browser failed to generate the business PDF.' }
        $signature = [IO.File]::ReadAllBytes($pdfPath)
        if ($signature.Length -lt 5 -or [Text.Encoding]::ASCII.GetString($signature, 0, 5) -ne '%PDF-') { throw 'Renderer output is not a PDF.' }
        Move-Item -LiteralPath $pdfPath -Destination $Destination -Force:$Overwrite
    } finally {
        if ($process) {
            if (-not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
            $process.Dispose()
        }
        Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Start-BusinessRender {
    param([Management.Automation.PowerShell]$Renderer, [object]$Document, [string]$Browser)
    if ($Document.Reuse) { return $null }
    $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Document.LocalPath))
    $Renderer.Commands.Clear()
    $Renderer.Streams.Error.Clear()
    $null = $Renderer.AddCommand('Export-BusinessPdf').AddParameter('Document', $Document).
        AddParameter('Destination', $Document.LocalPath).AddParameter('Browser', $Browser)
    $Renderer.BeginInvoke()
}

function Test-BusinessTransientError {
    param([Management.Automation.ErrorRecord]$Failure)
    $exception = $Failure.Exception
    while ($exception) {
        if ($exception.Response -and $exception.Response.StatusCode) {
            return [int]$exception.Response.StatusCode -in @(408,429,500,502,503,504)
        }
        if ($exception -is [Net.Http.HttpRequestException] -or $exception -is [TimeoutException] -or $exception -is [Threading.Tasks.TaskCanceledException]) { return $true }
        $exception = $exception.InnerException
    }
    return $false
}

function Wait-BusinessRetry {
    param([Management.Automation.ErrorRecord]$Failure, [int]$Attempt, [string]$Context)
    $delay = [int][Math]::Pow(2, $Attempt) + (Get-Random -Minimum 0 -Maximum 3)
    $retryAfter = $Failure.Exception.Response.Headers.RetryAfter
    if ($retryAfter.Delta) { $delay = [Math]::Max($delay, [Math]::Ceiling($retryAfter.Delta.TotalSeconds)) }
    elseif ($retryAfter.Date) { $delay = [Math]::Max($delay, [Math]::Ceiling(($retryAfter.Date - [datetimeoffset]::UtcNow).TotalSeconds)) }
    $delay = [int][Math]::Clamp($delay, 1, 120)
    Write-Warning "$Context failed transiently. Retry $Attempt/3 in $delay seconds."
    Start-Sleep -Seconds $delay
}

function Invoke-BusinessRequest {
    param([string]$Path, [string]$Method = 'GET', [object]$Body, [hashtable]$ExtraHeaders = @{}, [string]$InFile, [switch]$OneLake)
    $expectedHost = if ($OneLake) { 'onelake.dfs.fabric.microsoft.com' } else { 'api.fabric.microsoft.com' }
    $uri = $null
    if (-not [uri]::TryCreate([uri]'https://api.fabric.microsoft.com/v1/', $Path, [ref]$uri) -or
        $uri.Scheme -ne 'https' -or $uri.Port -ne 443 -or $uri.UserInfo -or $uri.Fragment -or $uri.Host -ne $expectedHost -or
        (-not $OneLake -and -not $uri.AbsolutePath.StartsWith('/v1/', [StringComparison]::Ordinal))) {
        throw 'Rejected request URL. Only public Fabric v1 and OneLake HTTPS endpoints are allowed.'
    }
    $resource = if ($OneLake) { 'https://storage.azure.com/' } else { 'https://api.fabric.microsoft.com' }
    if (-not $tokenCache.ContainsKey($resource) -or $tokenCache[$resource].RefreshAt -lt [datetime]::UtcNow) {
        $result = & az account get-access-token --resource $resource --only-show-errors --output json
        if ($LASTEXITCODE -ne 0) { throw "Unable to acquire token for $resource. Check Azure CLI sign-in." }
        $token = ($result -join "`n") | ConvertFrom-Json
        if (-not $token.accessToken) { throw "Azure CLI returned no token for $resource." }
        $tokenCache[$resource] = @{ Value = $token.accessToken; RefreshAt = [datetime]::UtcNow.AddMinutes(5) }
    }
    $headers = @{ Authorization = "Bearer $($tokenCache[$resource].Value)" }
    if ($OneLake) { $headers['x-ms-version'] = '2021-06-08' }
    foreach ($key in $ExtraHeaders.Keys) { $headers[$key] = $ExtraHeaders[$key] }
    $parameters = @{ Uri = $uri; Method = $Method; Headers = $headers; TimeoutSec = 120; MaximumRedirection = 0; MaximumRetryCount = 0 }
    if ($InFile) { $parameters.InFile = $InFile; $parameters.ContentType = 'application/octet-stream' }
    elseif ($null -ne $Body) { $parameters.Body = ConvertTo-Json -InputObject $Body -Depth 10 -Compress; $parameters.ContentType = 'application/json' }
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        try { return Invoke-WebRequest @parameters }
        catch {
            if ($Method -notin @('GET','HEAD') -or $attempt -eq 4 -or -not (Test-BusinessTransientError $_)) { throw }
            Wait-BusinessRetry $_ $attempt "$Method $($uri.AbsolutePath)"
        }
    }
}

function Send-BusinessPdf {
    param([object]$Document, [string]$FileUri, [switch]$ReplaceExisting)
    $length = (Get-Item -LiteralPath $Document.LocalPath).Length
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        $stage = 'create'
        try {
            $createHeaders = @{ 'x-ms-content-type' = 'application/pdf' }
            if (-not $ReplaceExisting) { $createHeaders['If-None-Match'] = '*' }
            $null = Invoke-BusinessRequest "$FileUri`?resource=file" 'PUT' -ExtraHeaders $createHeaders -OneLake
            $stage = 'append'
            $null = Invoke-BusinessRequest "$FileUri`?action=append&position=0" 'PATCH' -InFile $Document.LocalPath -OneLake
            $stage = 'flush'
            $null = Invoke-BusinessRequest "$FileUri`?action=flush&position=$length&close=true" 'PATCH' -ExtraHeaders @{ 'x-ms-content-type' = 'application/pdf' } -OneLake
            $stage = 'verify'
            $properties = Invoke-BusinessRequest $FileUri 'HEAD' -OneLake
            $remoteLength = [long]0
            if (-not [long]::TryParse([string]($properties.Headers.'Content-Length' | Select-Object -First 1), [ref]$remoteLength) -or $remoteLength -ne $length) {
                throw "Uploaded size mismatch for $($Document.RelativePath). Local PDF retained."
            }
            return
        } catch {
            if (-not $ReplaceExisting -or $attempt -eq 4 -or -not (Test-BusinessTransientError $_)) {
                Write-Warning "Upload failed at $stage for $($Document.RelativePath) (attempt $attempt). Resume this file with -StartAt '$($Document.RelativePath)' -ReuseLocal -Overwrite."
                throw
            }
            Wait-BusinessRetry $_ $attempt "Upload $($Document.RelativePath) at $stage; restarting the entire file"
        }
    }
}

function Get-BusinessCollection {
    param([string]$Path)
    $visited = [Collections.Generic.HashSet[string]]::new()
    do {
        if (-not $visited.Add($Path) -or $visited.Count -gt 1000) { throw 'Invalid Fabric pagination sequence.' }
        $response = Invoke-BusinessRequest $Path
        $page = $response.Content | ConvertFrom-Json
        $page.value
        $Path = $page.continuationUri
    } while ($Path)
}

function New-BusinessLakehouse {
    param([string]$Path)
    $response = Invoke-BusinessRequest $Path 'POST' @{ displayName = $lakehouseName; description = 'State and insurance-line operating guidelines and compliance review documents.' }
    if ([int]$response.StatusCode -eq 202) {
        $operationId = [guid]::Empty
        if (-not [guid]::TryParse([string]($response.Headers.'x-ms-operation-id' | Select-Object -First 1), [ref]$operationId) -or $operationId -eq [guid]::Empty) {
            throw 'Lakehouse creation returned no valid operation ID. Check the workspace before rerunning.'
        }
        $operationPath = "operations/$operationId"
        for ($attempt = 0; $attempt -lt 60; $attempt++) {
            $delay = 5
            $headerDelay = 0
            if ([int]::TryParse([string]($response.Headers.'Retry-After' | Select-Object -First 1), [ref]$headerDelay)) { $delay = [Math]::Clamp($headerDelay, 1, 60) }
            Start-Sleep -Seconds $delay
            $response = Invoke-BusinessRequest $operationPath
            $operation = $response.Content | ConvertFrom-Json
            if ($operation.status -eq 'Succeeded') {
                $response = Invoke-BusinessRequest "$operationPath/result"
                return $response.Content | ConvertFrom-Json
            }
            if ($operation.status -in @('Failed','Cancelled')) { throw 'Lakehouse creation failed. Local PDFs retained.' }
        }
        throw 'Lakehouse creation timed out. Check the workspace before rerunning; local PDFs retained.'
    }
    $response.Content | ConvertFrom-Json
}

function Initialize-BusinessDirectory {
    param([string]$Uri)
    try { $null = Invoke-BusinessRequest $Uri 'HEAD' -OneLake }
    catch {
        if ([int]$_.Exception.Response.StatusCode -ne 404) { throw }
        try { $null = Invoke-BusinessRequest "$Uri`?resource=directory" 'PUT' -ExtraHeaders @{ 'If-None-Match' = '*' } -OneLake }
        catch {
            if ([int]$_.Exception.Response.StatusCode -notin @(409,412)) { throw }
        }
    }
    $response = Invoke-BusinessRequest $Uri 'HEAD' -OneLake
    if ([string]($response.Headers.'x-ms-resource-type' | Select-Object -First 1) -ne 'directory') { throw "Expected a directory at $Uri." }
}

$allStates = Get-BusinessStates
if ($PSBoundParameters.ContainsKey('States')) {
    $States = @($States | ForEach-Object { $_.ToUpperInvariant() } | Select-Object -Unique)
    foreach ($stateCode in $States) { if (-not $allStates.Contains($stateCode)) { throw "Unknown US state code: $stateCode. Use a two-letter code for one of the 50 states." } }
} else { $States = @($allStates.Keys) }
if ($PSBoundParameters.ContainsKey('WorkspaceId') -and $WorkspaceId -eq [guid]::Empty) { throw 'WorkspaceId must not be empty.' }
$action = if ($LocalOnly) { 'Generate local business PDFs' } else { 'Generate business PDFs, create/reuse InsuranceBusinessDocuments, and upload to OneLake' }
if (-not $PSCmdlet.ShouldProcess("$($States.Count) states / $($States.Count * 9) PDFs -> $OutputDirectory -> workspace $WorkspaceId", $action)) { return }
if (-not $LocalOnly -and -not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Install Azure CLI and sign in first.' }
if (-not $BrowserExecutable) {
    $BrowserExecutable = @(
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe"
        "$env:LOCALAPPDATA\Microsoft\Edge\Application\msedge.exe"
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
}
if (-not $BrowserExecutable -or -not (Test-Path -LiteralPath $BrowserExecutable -PathType Leaf)) { throw 'Install Edge or Chrome, or supply -BrowserExecutable.' }
$OutputDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
$startReached = -not $StartAt
$documents = @(foreach ($line in @('auto','home','business')) {
    $lineFolder = @{ auto = 'Auto'; home = 'Home'; business = 'Business' }[$line]
    foreach ($stateCode in $States) {
        foreach ($kind in @('Compliance','Guidelines','Regulatory')) {
            $relativePath = "InsuranceBusinessKnowledge/$lineFolder/$stateCode/$kind/${lineFolder}_${stateCode}_${kind}.pdf"
            if (-not $startReached) {
                if ($relativePath -ceq $StartAt) { $startReached = $true } else { continue }
            }
            $localPath = Join-Path $OutputDirectory $relativePath
            $reuse = $false
            if (Test-Path -LiteralPath $localPath) {
                if ($ReuseLocal) {
                    $bytes = [IO.File]::ReadAllBytes($localPath)
                    if ($bytes.Length -lt 10 -or [Text.Encoding]::ASCII.GetString($bytes, 0, 5) -ne '%PDF-' -or
                        -not [Text.Encoding]::ASCII.GetString($bytes, [Math]::Max(0, $bytes.Length - 1024), [Math]::Min(1024, $bytes.Length)).Contains('%%EOF')) {
                        throw "Cannot reuse incomplete or invalid PDF: $localPath. Remove -ReuseLocal and use -Overwrite to regenerate."
                    }
                    $reuse = $true
                } elseif (-not $Overwrite) { throw "File already exists: $localPath. Use -ReuseLocal to keep it or -Overwrite to replace local and remote PDFs." }
            }
            [pscustomobject]@{ StateCode = $stateCode; StateName = $allStates[$stateCode]; Line = $line; Kind = $kind; RelativePath = $relativePath; LocalPath = $localPath; Reuse = $reuse }
        }
    }
})
if (-not $startReached) { throw "StartAt path '$StartAt' is not in the selected states or does not match its folders. Use the exact InsuranceBusinessKnowledge/Line/State/Kind/Line_State_Kind.pdf path." }
if ($LocalOnly) {
    foreach ($document in $documents) {
        if (-not $document.Reuse) {
            $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($document.LocalPath))
            Export-BusinessPdf $document $document.LocalPath $BrowserExecutable
        }
        Write-Host "Local PDF ready: $($document.RelativePath)"
    }
    $documents | Select-Object StateCode, Line, Kind, LocalPath
    return
}
if ($WorkspaceId -eq [guid]::Empty) {
    $workspaces = @(Get-BusinessCollection 'workspaces')
    if (-not $workspaces.Count) { throw 'No accessible Fabric workspaces found. Local PDFs retained.' }
    for ($index = 0; $index -lt $workspaces.Count; $index++) { Write-Host ('{0}. {1} [{2}]' -f ($index + 1), $workspaces[$index].displayName, $workspaces[$index].id) }
    do {
        $selection = (Read-Host 'Select a workspace number, or Q to keep only local PDFs').Trim()
        if ($selection -eq 'q') { Write-Host 'Cancelled before rendering or uploading. Existing local PDFs are unchanged.'; return }
        $number = 0
        $valid = [int]::TryParse($selection, [ref]$number) -and $number -ge 1 -and $number -le $workspaces.Count
    } until ($valid)
    $WorkspaceId = [guid]$workspaces[$number - 1].id
}
$workspacePath = "workspaces/$WorkspaceId"
$workspace = (Invoke-BusinessRequest $workspacePath).Content | ConvertFrom-Json
if (-not $workspace.capacityId) { throw 'The selected workspace has no Fabric capacity. Local PDFs retained.' }
$namedItems = @(Get-BusinessCollection "$workspacePath/items" | Where-Object displayName -EQ $lakehouseName)
$lakehouses = @($namedItems | Where-Object type -EQ 'Lakehouse')
if ($lakehouses.Count -gt 1 -or (-not $lakehouses.Count -and $namedItems.Count)) { throw "Ambiguous or non-lakehouse item named $lakehouseName. No item was changed." }
$lakehouse = if ($lakehouses.Count) { $lakehouses[0] } else { New-BusinessLakehouse "$workspacePath/lakehouses" }
$lakehouseId = [guid]$lakehouse.id
if ($lakehouseId -eq [guid]::Empty) { throw 'Fabric returned no lakehouse ID. Check the workspace before rerunning.' }
$rootUri = "https://onelake.dfs.fabric.microsoft.com/$WorkspaceId/$lakehouseId/Files"
$directories = [Collections.Generic.HashSet[string]]::new()
Write-Host "Using lakehouse $lakehouseName [$lakehouseId]."
$renderer = $null
$renderRunspace = $null
$pendingRender = $null
$uploadedCount = 0
try {
    $session = [Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    foreach ($functionName in @('Get-BusinessSections','ConvertTo-BusinessHtml','Export-BusinessPdf')) {
        $session.Commands.Add([Management.Automation.Runspaces.SessionStateFunctionEntry]::new($functionName, (Get-Command $functionName -CommandType Function).Definition))
    }
    $session.Variables.Add([Management.Automation.Runspaces.SessionStateVariableEntry]::new('Overwrite', [bool]$Overwrite, ''))
    $session.Variables.Add([Management.Automation.Runspaces.SessionStateVariableEntry]::new('ErrorActionPreference', 'Stop', ''))
    $renderRunspace = [runspacefactory]::CreateRunspace($session)
    $renderRunspace.Open()
    $renderer = [Management.Automation.PowerShell]::Create()
    $renderer.Runspace = $renderRunspace
    $pendingRender = Start-BusinessRender $renderer $documents[0] $BrowserExecutable
    for ($documentIndex = 0; $documentIndex -lt $documents.Count; $documentIndex++) {
        $document = $documents[$documentIndex]
        if ($pendingRender) {
            $null = $renderer.EndInvoke($pendingRender)
            $pendingRender = $null
            if ($renderer.HadErrors) { throw $renderer.Streams.Error[0] }
        }
        $renderStatus = if ($document.Reuse) { 'Reused' } else { 'Generated' }
        Write-Host "$renderStatus $($document.RelativePath)"
        if ($documentIndex + 1 -lt $documents.Count) {
            $pendingRender = Start-BusinessRender $renderer $documents[$documentIndex + 1] $BrowserExecutable
        }
        $directory = ''
        $pathSegments = $document.RelativePath.Split('/')
        foreach ($segment in $pathSegments[0..($pathSegments.Count - 2)]) {
            $directory = if ($directory) { "$directory/$segment" } else { $segment }
            if ($directories.Add($directory)) { Initialize-BusinessDirectory "$rootUri/$directory" }
        }
        $fileUri = "$rootUri/$($document.RelativePath)"
        Send-BusinessPdf $document $fileUri -ReplaceExisting:$Overwrite
        $uploadedCount++
        Write-Host "Uploaded and verified [$uploadedCount/$($documents.Count)] $($document.RelativePath)"
        Write-Progress -Activity 'Insurance business documents' -Status "$uploadedCount / $($documents.Count) uploaded and verified" -PercentComplete (100 * $uploadedCount / $documents.Count)
        [pscustomobject]@{ StateCode = $document.StateCode; Line = $document.Line; Kind = $document.Kind; LocalPath = $document.LocalPath; WorkspaceId = "$WorkspaceId"; LakehouseId = "$lakehouseId"; OneLakeUrl = $fileUri }
    }
} catch {
    Write-Warning "Stopped after $uploadedCount verified uploads. Completed local PDFs and remote files are retained. Rerun with -ReuseLocal -Overwrite to reuse local PDFs and replace partial remote files."
    throw
} finally {
    if ($renderer) {
        if ($pendingRender) { $renderer.Stop() }
        $renderer.Dispose()
    }
    if ($renderRunspace) { $renderRunspace.Dispose() }
    Write-Progress -Activity 'Insurance business documents' -Completed
}
#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot '../fabric/populate-insurance-customer-base-db.ps1'
$parseErrors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$global:CustomerBaseSeedTestState = @{ CliCalls = 0; SqlCalls = @(); CliFailure = $false; SqlFailure = $false }
function az {
    $global:CustomerBaseSeedTestState.CliCalls++
    $global:LASTEXITCODE = if ($global:CustomerBaseSeedTestState.CliFailure) { 1 } else { 0 }
    if (-not $global:CustomerBaseSeedTestState.CliFailure) { '{"accessToken":"offline-test-token"}' }
}
function Invoke-Sqlcmd {
    param($ServerInstance, $Database, $AccessToken, $Encrypt, [switch]$AbortOnError,
          $ErrorAction, $ConnectionTimeout, $QueryTimeout, [switch]$DisableVariables, $Query)
    $global:CustomerBaseSeedTestState.SqlCalls += $PSBoundParameters
    if ($global:CustomerBaseSeedTestState.SqlFailure) { throw 'Simulated SQL failure' }
    [pscustomobject]@{ CustomersInserted = 10; AddressesInserted = 10; CustomerAddressesInserted = 10; PoliciesInserted = 10 }
}

& $scriptPath -WhatIf
Assert-True ($global:CustomerBaseSeedTestState.CliCalls -eq 0 -and $global:CustomerBaseSeedTestState.SqlCalls.Count -eq 0) 'WhatIf must not contact SQL or Azure.'
Write-Host 'PASS: WhatIf performs no remote calls.'

$result = & $scriptPath -Environment ins -Suffix 2
$call = $global:CustomerBaseSeedTestState.SqlCalls[-1]
Assert-True ($call.ServerInstance -eq 'sql-eia-ins-2.database.windows.net' -and $call.Database -eq 'InsuranceCustomerBase') 'Incorrect SQL target.'
Assert-True ($call.AccessToken -eq 'offline-test-token' -and $call.Encrypt -eq 'Mandatory' -and $call.AbortOnError -and $call.DisableVariables) 'Missing SQL security options.'
$match = [regex]::Match($call.Query, "DECLARE @demo nvarchar\(max\) = N'(?<json>(?:''|[^'])*)';")
Assert-True $match.Success 'Demo JSON not found.'
$rows = @($match.Groups['json'].Value.Replace("''", "'") | ConvertFrom-Json)
Assert-True ($rows.Count -eq 10 -and $result.CustomersInserted -eq 10) 'Expected ten customers.'
foreach ($key in @('CustomerId', 'AddressId', 'PolicyId', 'PolicyNumber', 'EmailAddress')) {
    Assert-True (@($rows.$key | Sort-Object -Unique).Count -eq 10) "Duplicate $key."
}
foreach ($row in $rows) {
    $null = [guid]::Parse($row.CustomerId)
    $null = [guid]::Parse($row.AddressId)
    $null = [guid]::Parse($row.PolicyId)
    Assert-True ($row.EmailAddress.EndsWith('@example.com')) 'Only example.com emails should be seeded.'
    Assert-True ($row.PremiumAmount -gt 0 -and $row.CoverageLimitAmount -gt 0) 'Missing policy amounts.'
    Assert-True ([datetime]$row.ExpirationDate -gt [datetime]$row.EffectiveDate) 'Invalid policy dates.'
}
Assert-True ($rows[-1].LastName -eq "O'Brien") 'SQL escaping corrupted sample names.'
Assert-True (@($rows.PolicyType | Sort-Object -Unique).Count -eq 3) 'Expected auto, home, and business policies.'
Assert-True (([regex]::Matches($call.Query, 'WHERE NOT EXISTS')).Count -eq 4) 'Each insert must skip existing keys.'
Assert-True ($call.Query.Contains('SET XACT_ABORT ON') -and $call.Query.Contains('ROLLBACK TRAN') -and $call.Query.Contains('THROW;')) 'Missing transactional failure handling.'
Assert-True (-not ($call.Query -match '(?im)^\s*(UPDATE|DELETE|MERGE)\s')) 'Seeding must be insert-only.'
Write-Host 'PASS: Ten fictional customers with distinct IDs, linked inserts, safe literals, and transactional guards.'

$null = & $scriptPath -SqlServerName 'custom-demo-server'
Assert-True ($global:CustomerBaseSeedTestState.SqlCalls[-1].ServerInstance -eq 'custom-demo-server.database.windows.net') 'SQL server override ignored.'
Assert-True ($global:CustomerBaseSeedTestState.SqlCalls[-1].Query -eq $call.Query) 'Reruns must use stable demo rows.'
Write-Host 'PASS: Custom server and stable rerun data.'

$global:CustomerBaseSeedTestState.CliFailure = $true
$before = $global:CustomerBaseSeedTestState.SqlCalls.Count
try { & $scriptPath; throw 'Expected CLI failure.' }
catch { Assert-True ($_.Exception.Message -like 'Unable to acquire*') 'CLI error was not propagated.' }
Assert-True ($global:CustomerBaseSeedTestState.SqlCalls.Count -eq $before) 'SQL ran after authentication failed.'
$global:CustomerBaseSeedTestState.CliFailure = $false
$global:CustomerBaseSeedTestState.SqlFailure = $true
try { & $scriptPath; throw 'Expected SQL failure.' }
catch { Assert-True ($_.Exception.Message -eq 'Simulated SQL failure') 'SQL error was not propagated.' }
Write-Host 'PASS: Authentication and SQL errors stop the script.'
Remove-Variable CustomerBaseSeedTestState -Scope Global
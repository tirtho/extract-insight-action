#Requires -Version 5.1
<#
.SYNOPSIS
    Registers Content Understanding analyzer schemas.
.DESCRIPTION
    Reads every .json file from a schema folder, injects the completion model
    (from Key Vault) when missing, creates the analyzer via the Content
    Understanding REST API, polls until provisioning completes, and prints a
    summary table with analyzer IDs and their status.
    If analyzers already exist, prompts to delete them all before creating.
.PARAMETER Environment
    Optional. Environment name (default: dev).
.PARAMETER Suffix
    Optional. The same suffix used during infrastructure deployment.
.PARAMETER SchemaFolder
    Optional. Path to the folder containing .json schema files.
    Defaults to <script-dir>\cu-schemas.
.USAGE
    .\5.content-understanding-add-schema.ps1 -Suffix 0
    .\5.content-understanding-add-schema.ps1 -Environment dev -Suffix 0
    .\5.content-understanding-add-schema.ps1 -Suffix 0 -SchemaFolder C:\my-schemas
#>
param(
    [Parameter(HelpMessage="Environment (default: dev, example: dev)")]
    [string]$Environment,

    [Parameter(HelpMessage="Suffix used during infrastructure deployment (default: 1, example: 1)")]
    [string]$Suffix,

    [Parameter(Mandatory=$false)]
    [string]$SchemaFolder
)

$ErrorActionPreference = "Stop"

$LocationInput = Read-Host "Enter location [default: centralus, example: centralus]"
$Location = if ([string]::IsNullOrWhiteSpace($LocationInput)) { "centralus" } else { $LocationInput.Trim().ToLowerInvariant() }

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

$ProjectName = "eia"

Write-Host "[INFO] Deployment key: $ProjectName-$Environment-$Suffix (location: $Location)" -ForegroundColor Cyan

# =============================================================================
# DEFAULTS
# =============================================================================
$ApiVersion  = "2025-11-01"

if (-not $SchemaFolder) {
    $SchemaFolder = Join-Path $PSScriptRoot "cu-schemas"
}

# =============================================================================
# HELPER
# =============================================================================
function Invoke-AzCliSilent {
    param([string[]]$Arguments)
    $prevPref = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    $allOutput = & az @Arguments 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prevPref
    $stdout = ($allOutput | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n"
    $stderr = ($allOutput | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }) -join "`n"
    return @{ ExitCode = $code; Output = $stdout.Trim(); Error = $stderr.Trim() }
}

# =============================================================================
# RESOLVE ENDPOINT FROM KEY VAULT & ACQUIRE TOKEN
# =============================================================================
$KeyVaultName = "kv-$ProjectName-$Environment-$Suffix"

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Content Understanding – Register Analyzer Schemas" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

Write-Host "[INFO] Reading Content Understanding endpoint from Key Vault ($KeyVaultName)..." -ForegroundColor Cyan
$r = Invoke-AzCliSilent -Arguments @('keyvault','secret','show','--vault-name',$KeyVaultName,'--name','ContentUnderstandingEndpoint','--query','value','-o','tsv')
if ($r.ExitCode -ne 0 -or -not $r.Output) {
    Write-Host "[ERROR] Failed to read ContentUnderstandingEndpoint from Key Vault: $($r.Error)" -ForegroundColor Red
    exit 1
}
$CuEndpoint = $r.Output.TrimEnd('/')
Write-Host "[OK]   Endpoint: $CuEndpoint" -ForegroundColor Green

Write-Host "[INFO] Acquiring bearer token for Cognitive Services..." -ForegroundColor Cyan
$r = Invoke-AzCliSilent -Arguments @('account','get-access-token','--resource','https://cognitiveservices.azure.com','--query','accessToken','-o','tsv')
if ($r.ExitCode -ne 0 -or -not $r.Output) {
    Write-Host "[ERROR] Failed to acquire bearer token: $($r.Error)" -ForegroundColor Red
    exit 1
}
$BearerToken = $r.Output
Write-Host "[OK]   Token acquired" -ForegroundColor Green
Write-Host ""

# =============================================================================
# LIST EXISTING CUSTOM ANALYZERS
# =============================================================================
Write-Host "[INFO] Listing existing analyzers..." -ForegroundColor Cyan
$listUrl = "$CuEndpoint/contentunderstanding/analyzers?api-version=$ApiVersion"
try {
    $listResp = Invoke-WebRequest -Uri $listUrl -Method GET `
        -Headers @{ "Authorization" = "Bearer $BearerToken" } `
        -UseBasicParsing
    $allAnalyzers = ($listResp.Content | ConvertFrom-Json).value
    $existingAnalyzers = @($allAnalyzers | Where-Object { $_.analyzerId -notlike 'prebuilt-*' })
} catch {
    Write-Host "[WARN] Could not list analyzers: $($_.Exception.Message)" -ForegroundColor Yellow
    $existingAnalyzers = @()
}

# Build a lookup set of existing analyzer IDs
$existingIds = @{}
if ($existingAnalyzers) {
    foreach ($a in $existingAnalyzers) { $existingIds[$a.analyzerId] = $a }
}

if ($existingIds.Count -gt 0) {
    Write-Host "[INFO] Found $($existingIds.Count) custom analyzer(s):" -ForegroundColor Cyan
    $existingAnalyzers | ForEach-Object {
        Write-Host "         - $($_.analyzerId)  (status: $($_.status))" -ForegroundColor DarkGray
    }
    Write-Host ""
    $choice = Read-Host "Delete ALL custom analyzers and exit? (y/N)"
    if ($choice -eq 'y' -or $choice -eq 'Y') {
        Write-Host ""
        Write-Host "[WARNING] This will permanently delete $($existingIds.Count) custom analyzer(s). This action cannot be undone." -ForegroundColor Red
        $confirm = Read-Host "Are you sure? Type 'yes' to confirm"
        if ($confirm -ne 'yes') {
            Write-Host "[INFO] Cancelled. No analyzers deleted." -ForegroundColor Cyan
            Write-Host ""
        } else {
        foreach ($a in $existingAnalyzers) {
            $id = $a.analyzerId
            Write-Host "[INFO] Deleting analyzer '$id'..." -ForegroundColor Cyan
            $delUrl = "$CuEndpoint/contentunderstanding/analyzers/$($id)?api-version=$ApiVersion"
            try {
                Invoke-WebRequest -Uri $delUrl -Method DELETE `
                    -Headers @{ "Authorization" = "Bearer $BearerToken" } `
                    -UseBasicParsing | Out-Null
                Write-Host "[OK]   Deleted '$id'" -ForegroundColor Green
            } catch {
                Write-Host "[ERROR] Failed to delete '$id': $($_.Exception.Message)" -ForegroundColor Red
            }
        }
        Write-Host ""
        Write-Host "[INFO] All custom analyzers deleted." -ForegroundColor Cyan
        Write-Host "[INFO] Clearing ContentUnderstandingAnalyzers secret from Key Vault..." -ForegroundColor Cyan
        $kvResult = Invoke-AzCliSilent -Arguments @('keyvault','secret','set','--vault-name',$KeyVaultName,'--name','ContentUnderstandingAnalyzers','--value','[]','--output','none')
        if ($kvResult.ExitCode -eq 0) {
            Write-Host "[OK]   Secret 'ContentUnderstandingAnalyzers' cleared in $KeyVaultName" -ForegroundColor Green
        } else {
            Write-Host "[WARN] Failed to clear secret: $($kvResult.Error)" -ForegroundColor Yellow
        }
        exit 0
        }
    }
} else {
    Write-Host "[INFO] No custom analyzers found." -ForegroundColor DarkGray
}
Write-Host ""

# =============================================================================
# VALIDATE SCHEMA FOLDER
# =============================================================================
if (-not (Test-Path $SchemaFolder)) {
    Write-Host "[ERROR] Schema folder not found: $SchemaFolder" -ForegroundColor Red
    exit 1
}

$schemaFiles = Get-ChildItem -Path $SchemaFolder -Filter "*.json" -File
if ($schemaFiles.Count -eq 0) {
    Write-Host "[ERROR] No .json files found in $SchemaFolder" -ForegroundColor Red
    exit 1
}

Write-Host "[INFO] Schema folder : $SchemaFolder"
Write-Host "[INFO] Schema files  : $($schemaFiles.Count)"
Write-Host ""

Write-Host "[INFO] Reading completion model from Key Vault..." -ForegroundColor Cyan
$r = Invoke-AzCliSilent -Arguments @('keyvault','secret','show','--vault-name',$KeyVaultName,'--name','ContentUnderstandingCompletionModel','--query','value','-o','tsv')
if ($r.ExitCode -ne 0 -or -not $r.Output) {
    Write-Host "[ERROR] Failed to read ContentUnderstandingCompletionModel from Key Vault: $($r.Error)" -ForegroundColor Red
    exit 1
}
$CompletionModel = $r.Output
Write-Host "[OK]   Completion model: $CompletionModel" -ForegroundColor Green

Write-Host "[INFO] Reading embedding model from Key Vault..." -ForegroundColor Cyan
$r = Invoke-AzCliSilent -Arguments @('keyvault','secret','show','--vault-name',$KeyVaultName,'--name','ContentUnderstandingEmbeddingModel','--query','value','-o','tsv')
if ($r.ExitCode -ne 0 -or -not $r.Output) {
    Write-Host "[WARN] ContentUnderstandingEmbeddingModel not found in Key Vault – defaulting to 'text-embedding-3-large'" -ForegroundColor Yellow
    $EmbeddingModel = 'text-embedding-3-large'
} else {
    $EmbeddingModel = $r.Output
}
Write-Host "[OK]   Embedding model: $EmbeddingModel" -ForegroundColor Green
Write-Host ""

# =============================================================================
# CREATE ANALYZERS
# =============================================================================
$results = @()

foreach ($file in $schemaFiles) {
    $analyzerId = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
    Write-Host "------------------------------------------------------------" -ForegroundColor DarkGray

    # Check if this analyzer already exists
    if ($existingIds.ContainsKey($analyzerId)) {
        $existing = $existingIds[$analyzerId]
        Write-Host "[INFO] Analyzer '$analyzerId' already exists (status: $($existing.status))" -ForegroundColor Yellow
        $choice = Read-Host "       Replace it? (y/N)"
        if ($choice -eq 'y' -or $choice -eq 'Y') {
            Write-Host "[INFO] Deleting '$analyzerId' before re-creating..." -ForegroundColor Cyan
            $delUrl = "$CuEndpoint/contentunderstanding/analyzers/$($analyzerId)?api-version=$ApiVersion"
            try {
                Invoke-WebRequest -Uri $delUrl -Method DELETE `
                    -Headers @{ "Authorization" = "Bearer $BearerToken" } `
                    -UseBasicParsing | Out-Null
                Write-Host "[OK]   Deleted '$analyzerId'" -ForegroundColor Green
                $existingIds.Remove($analyzerId)
            } catch {
                Write-Host "[ERROR] Failed to delete '$analyzerId': $($_.Exception.Message)" -ForegroundColor Red
                $results += [PSCustomObject]@{
                    FileName       = $analyzerId
                    AnalyzerId     = $analyzerId
                    BaseAnalyzerId = ""
                    Status         = "error"
                    HttpCode       = ""
                }
                continue
            }
        } else {
            Write-Host "[OK]   Keeping existing '$analyzerId'" -ForegroundColor Green
            $results += [PSCustomObject]@{
                FileName       = $analyzerId
                AnalyzerId     = $analyzerId
                BaseAnalyzerId = $existing.baseAnalyzerId
                Status         = "kept"
                HttpCode       = ""
            }
            continue
        }
    }

    Write-Host "[INFO] Creating analyzer '$analyzerId' from $($file.Name)..." -ForegroundColor Cyan

    # Read and inject models.
    # - models.embedding is injected for ALL schemas (prebuilt-document, prebuilt-image,
    #   prebuilt-audio, prebuilt-video all require an embedding deployment at the
    #   analyzer level; service-level defaults alone are not sufficient).
    # - models.completion is only injected for schemas that declare a fieldSchema,
    #   since only those perform LLM-based field extraction.
    $schemaJson = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json
    if (-not $schemaJson.models) {
        $models = [PSCustomObject]@{ embedding = $EmbeddingModel }
        if ($schemaJson.fieldSchema) {
            $models | Add-Member -NotePropertyName "completion" -NotePropertyValue $CompletionModel
        }
        $schemaJson | Add-Member -NotePropertyName "models" -NotePropertyValue $models
    } else {
        if (-not $schemaJson.models.embedding) {
            $schemaJson.models | Add-Member -NotePropertyName "embedding" -NotePropertyValue $EmbeddingModel
        }
        if ($schemaJson.fieldSchema -and -not $schemaJson.models.completion) {
            $schemaJson.models | Add-Member -NotePropertyName "completion" -NotePropertyValue $CompletionModel
        }
    }
    $body = $schemaJson | ConvertTo-Json -Depth 10 -Compress

    # PUT to create/replace the analyzer
    $url = "$CuEndpoint/contentunderstanding/analyzers/$($analyzerId)?api-version=$ApiVersion"
    try {
        $response = Invoke-WebRequest -Uri $url -Method PUT -Body $body `
            -ContentType "application/json" `
            -Headers @{ "Authorization" = "Bearer $BearerToken" } `
            -UseBasicParsing

        $statusCode = $response.StatusCode
        Write-Host "[OK]   HTTP $statusCode" -ForegroundColor Green

        # Extract Operation-Location for polling
        $operationLocation = $null
        if ($response.Headers.ContainsKey("Operation-Location")) {
            $operationLocation = $response.Headers["Operation-Location"] | Select-Object -First 1
        }

        $operationId = $null
        if ($operationLocation) {
            # Operation-Location format: …/analyzers/{id}/operations/{opId}?api-version=…
            if ($operationLocation -match '/operations/([^?]+)') {
                $operationId = $Matches[1]
            }
        }

        if ($operationId) {
            Write-Host "[INFO] Polling operation '$operationId'..." -ForegroundColor Cyan
            $pollUrl = "$CuEndpoint/contentunderstanding/analyzers/$analyzerId/operations/$($operationId)?api-version=$ApiVersion"
            $maxAttempts = 30
            $attempt = 0
            $opStatus = "running"

            while ($attempt -lt $maxAttempts) {
                $attempt++
                Start-Sleep -Seconds 2
                $pollResp = Invoke-WebRequest -Uri $pollUrl -Method GET `
                    -Headers @{ "Authorization" = "Bearer $BearerToken" } `
                    -UseBasicParsing
                $pollBody = $pollResp.Content | ConvertFrom-Json
                $opStatus = $pollBody.status

                if ($opStatus -eq "succeeded" -or $opStatus -eq "failed" -or $opStatus -eq "canceled") {
                    break
                }
                Write-Host "       ... status: $opStatus (attempt $attempt/$maxAttempts)" -ForegroundColor DarkGray
            }

            if ($opStatus -eq "succeeded") {
                Write-Host "[OK]   Analyzer '$analyzerId' provisioned successfully" -ForegroundColor Green
            } else {
                Write-Host "[WARN] Analyzer '$analyzerId' finished with status: $opStatus" -ForegroundColor Yellow
            }
        } else {
            # No operation header – likely completed synchronously
            $opStatus = "succeeded"
            Write-Host "[OK]   Analyzer '$analyzerId' created (synchronous)" -ForegroundColor Green
        }

        # Parse the actual analyzerId and baseAnalyzerId from the API response
        $apiAnalyzerId = $analyzerId
        $apiBaseAnalyzerId = ""
        if ($response.Content) {
            try {
                $respObj = $response.Content | ConvertFrom-Json
                if ($respObj.analyzerId) { $apiAnalyzerId = $respObj.analyzerId }
                if ($respObj.baseAnalyzerId) { $apiBaseAnalyzerId = $respObj.baseAnalyzerId }
            } catch {}
        }

        $results += [PSCustomObject]@{
            FileName       = $analyzerId
            AnalyzerId     = $apiAnalyzerId
            BaseAnalyzerId = $apiBaseAnalyzerId
            Status         = $opStatus
            HttpCode       = $statusCode
        }

    } catch {
        $errMsg = $_.Exception.Message
        $errStatus = ""
        $errBody  = $_.ErrorDetails.Message
        if ($_.Exception.Response) {
            $errStatus = [int]$_.Exception.Response.StatusCode
        }
        if ($errStatus -eq 409) {
            Write-Host "[OK]   Analyzer '$analyzerId' already exists (HTTP 409)" -ForegroundColor Green
            $results += [PSCustomObject]@{
                FileName       = $analyzerId
                AnalyzerId     = $analyzerId
                BaseAnalyzerId = if ($existingIds.ContainsKey($analyzerId)) { $existingIds[$analyzerId].baseAnalyzerId } else { "" }
                Status         = "kept"
                HttpCode       = 409
            }
        } else {
            Write-Host "[ERROR] Failed to create analyzer '$analyzerId': $errMsg" -ForegroundColor Red
            if ($errBody) {
                Write-Host "[ERROR] Response: $errBody" -ForegroundColor Red
            }
            $results += [PSCustomObject]@{
                FileName       = $analyzerId
                AnalyzerId     = $analyzerId
                BaseAnalyzerId = ""
                Status         = "error"
                HttpCode       = $errStatus
            }
        }
    }
}

# =============================================================================
# SUMMARY
# =============================================================================
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Summary" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
$results | Format-Table -AutoSize -Property FileName, AnalyzerId, Status, HttpCode

$ready  = ($results | Where-Object { $_.Status -eq "succeeded" -or $_.Status -eq "kept" }).Count
$failed = ($results | Where-Object { $_.Status -eq "error" }).Count
Write-Host "[INFO] $ready/$($results.Count) analyzers ready." -ForegroundColor $(if ($failed -eq 0) { "Green" } else { "Yellow" })

if ($failed -gt 0) {
    Write-Host "[WARN] $failed analyzer(s) did not succeed – review errors above." -ForegroundColor Yellow
}

# =============================================================================
# STORE MERGED ANALYZER LIST IN KEY VAULT
# =============================================================================
# Helper: derive type from baseAnalyzerId (e.g. "prebuilt-document" -> "document")
function Get-AnalyzerType([string]$baseId) {
    if ($baseId -match 'prebuilt-(.+)') { return $Matches[1] }
    return $baseId
}

$analyzerList = @()

# Add existing analyzers not covered by any schema file
foreach ($id in $existingIds.Keys) {
    $a = $existingIds[$id]
    $analyzerList += [PSCustomObject]@{ id = $a.analyzerId; type = (Get-AnalyzerType $a.baseAnalyzerId) }
}

# Add all ready results (created or kept)
$readyAnalyzers = $results | Where-Object { $_.Status -eq "succeeded" -or $_.Status -eq "kept" }
foreach ($r in $readyAnalyzers) {
    # Avoid duplicates (already added from existingIds)
    if ($analyzerList | Where-Object { $_.id -eq $r.AnalyzerId }) { continue }
    $analyzerList += [PSCustomObject]@{ id = $r.AnalyzerId; type = (Get-AnalyzerType $r.BaseAnalyzerId) }
}

if ($analyzerList.Count -gt 0) {
    $secretValue = ($analyzerList | ConvertTo-Json -Depth 5 -Compress)
    # Ensure it's always a JSON array even for a single item
    if ($analyzerList.Count -eq 1) { $secretValue = "[$secretValue]" }
    Write-Host "[INFO] Storing ContentUnderstandingAnalyzers in Key Vault..." -ForegroundColor Cyan
    Write-Host "       $secretValue" -ForegroundColor DarkGray
    $kvResult = Invoke-AzCliSilent -Arguments @('keyvault','secret','set','--vault-name',$KeyVaultName,'--name','ContentUnderstandingAnalyzers','--value',$secretValue,'--output','none')
    if ($kvResult.ExitCode -ne 0) {
        Write-Host "[ERROR] Failed to store secret: $($kvResult.Error)" -ForegroundColor Red
        exit 1
    }
    Write-Host "[OK]   Secret 'ContentUnderstandingAnalyzers' saved to $KeyVaultName" -ForegroundColor Green
}
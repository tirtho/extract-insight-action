$ErrorActionPreference = 'Stop'

& {
    $scriptPath = Join-Path $PSScriptRoot '..\3.deploy-agents.ps1'
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $scriptPath, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        throw ($parseErrors | Out-String)
    }

    $catalogFunction = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'New-ToolCatalogEntry'
    }, $true)
    $toolLoop = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.ForEachStatementAst] -and
            $node.Variable.VariablePath.UserPath -eq 'tool' -and
            $node.Body.Extent.Text.Contains('$configuredTools.Add')
    }, $true)
    if ($null -eq $catalogFunction -or $null -eq $toolLoop) {
        throw 'Could not locate the deployment tool-binding code.'
    }
    Invoke-Expression $catalogFunction.Extent.Text
    $bindingBlock = [scriptblock]::Create($toolLoop.Extent.Text)

    function Read-Host {
        param($Prompt)
        return $answers.Dequeue()
    }

    $existingConnections = @(
        [pscustomobject]@{
            Name = 'company'; Reference = 'company'; ResourceId = '/connections/company'
            Category = 'MCP'; Target = 'https://company.example/mcp'
        }
        [pscustomobject]@{
            Name = 'sales'; Reference = 'sales'; ResourceId = '/connections/sales'
            Category = 'MCP'; Target = 'https://sales.example/mcp'
        }
        [pscustomobject]@{
            Name = 'missing-url'; Reference = 'missing-url'; ResourceId = '/connections/missing-url'
            Category = 'MCP'; Target = ''
        }
    )
    $scenarios = @(
        @{ Name = 'Bind an unbound tool'; Reference = ''; ServerUrl = ''; Choice = '1'; ExpectedReference = 'company'; ExpectedUrl = 'https://company.example/mcp' }
        @{ Name = 'Switch connections'; Reference = 'company'; ServerUrl = 'https://old.example/mcp'; Choice = '2'; ExpectedReference = 'sales'; ExpectedUrl = 'https://sales.example/mcp' }
        @{ Name = 'Keep and normalize an existing binding'; Reference = '/connections/company'; ServerUrl = ''; Choice = '0'; ExpectedReference = 'company'; ExpectedUrl = 'https://company.example/mcp' }
        @{ Name = 'Keep an existing agent URL when the target is absent'; Reference = 'missing-url'; ServerUrl = 'https://agent.example/mcp'; Choice = ''; ExpectedReference = 'missing-url'; ExpectedUrl = 'https://agent.example/mcp' }
        @{ Name = 'Leave a tool unbound'; Reference = ''; ServerUrl = ''; Choice = ''; ExpectedReference = ''; ExpectedUrl = '' }
        @{ Name = 'Do not reuse the old URL when switching to an incomplete connection'; Reference = 'company'; ServerUrl = 'https://company.example/mcp'; Choice = '3'; ExpectedReference = 'missing-url'; ExpectedUrl = '' }
    )

    foreach ($scenario in $scenarios) {
        $worker = [pscustomobject]@{
            tools = @([pscustomobject]@{
                name = 'search'
                description = 'Search documents'
                toolBinding = [pscustomobject]@{
                    reference = $scenario.Reference
                    serverUrl = $scenario.ServerUrl
                }
            })
        }
        $configuredTools = [System.Collections.Generic.List[object]]::new()
        $answers = [System.Collections.Generic.Queue[string]]::new()
        foreach ($answer in @('', '', $scenario.Choice)) {
            $answers.Enqueue($answer)
        }
        . $bindingBlock
        $result = $configuredTools[0].toolBinding
        if ($configuredTools.Count -ne 1 -or
            $result.reference -ne $scenario.ExpectedReference -or
            $result.serverUrl -ne $scenario.ExpectedUrl -or
            $answers.Count -ne 0) {
            throw "FAIL: $($scenario.Name)"
        }
        Write-Output "PASS: $($scenario.Name)"
    }

    $credentialFunction = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Invoke-JavaWithAzureCliCredential'
    }, $true)
    if ($null -eq $credentialFunction) {
        throw 'Could not locate the deployment credential wrapper.'
    }
    Invoke-Expression $credentialFunction.Extent.Text

    function Test-JavaInvocation {
        param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments)
        if ($env:AZURE_TOKEN_CREDENTIALS -ne 'AzureCliCredential') {
            throw 'Java did not receive the Azure CLI credential selector.'
        }
        if (($Arguments -join '|') -ne '-cp|test.jar|Main|instructions with spaces') {
            throw 'Java arguments changed.'
        }
        if ($throwOnInvocation) {
            throw 'Simulated Java invocation error'
        }
        $script:LASTEXITCODE = $expectedExitCode
    }

    $previousTokenCredentials = $env:AZURE_TOKEN_CREDENTIALS
    $previousGlobalExitCode = $global:LASTEXITCODE
    $previousScriptExitCode = $script:LASTEXITCODE
    try {
        foreach ($credentialScenario in @(
            @{ Name = 'Restore an unset credential selector'; Previous = $null; ExitCode = 0; Throws = $false }
            @{ Name = 'Restore an existing selector'; Previous = 'ManagedIdentityCredential'; ExitCode = 0; Throws = $false }
            @{ Name = 'Preserve a nonzero Java exit code'; Previous = 'ManagedIdentityCredential'; ExitCode = 7; Throws = $false }
            @{ Name = 'Restore the selector after an invocation error'; Previous = 'ManagedIdentityCredential'; ExitCode = 0; Throws = $true }
        )) {
            $env:AZURE_TOKEN_CREDENTIALS = $credentialScenario.Previous
            $expectedExitCode = $credentialScenario.ExitCode
            $throwOnInvocation = $credentialScenario.Throws
            $caughtInvocationError = $false
            try {
                Invoke-JavaWithAzureCliCredential -JavaPath 'Test-JavaInvocation' `
                    -JavaArguments @('-cp', 'test.jar', 'Main', 'instructions with spaces')
            } catch {
                if (-not $throwOnInvocation -or $_.Exception.Message -ne 'Simulated Java invocation error') {
                    throw
                }
                $caughtInvocationError = $true
            }
            if ($env:AZURE_TOKEN_CREDENTIALS -ne $credentialScenario.Previous -or
                $caughtInvocationError -ne $throwOnInvocation -or
                (-not $throwOnInvocation -and $script:LASTEXITCODE -ne $expectedExitCode)) {
                throw "FAIL: $($credentialScenario.Name)"
            }
            Write-Output "PASS: $($credentialScenario.Name)"
        }
    } finally {
        $env:AZURE_TOKEN_CREDENTIALS = $previousTokenCredentials
        $global:LASTEXITCODE = $previousGlobalExitCode
        $script:LASTEXITCODE = $previousScriptExitCode
    }
}
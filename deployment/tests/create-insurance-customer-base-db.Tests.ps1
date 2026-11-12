$ErrorActionPreference = 'Stop'

& {
    $scriptPath = Join-Path $PSScriptRoot '../fabric/create-insurance-customer-base-db.ps1'
    $parseErrors = $null
    $tokens = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw ($parseErrors | Out-String) }

    $workspaceId = '11111111-2222-3333-4444-555555555555'
    $connectionId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
    $sqlIdentityId = '22222222-3333-4444-5555-666666666666'
    $principalId = '33333333-4444-5555-6666-777777777777'
    $applicationId = '44444444-5555-6666-7777-888888888888'
    $cliCalls = [System.Collections.Generic.List[string]]::new()
    $fabricCalls = [System.Collections.Generic.List[object]]::new()
    $sqlCalls = [System.Collections.Generic.List[object]]::new()
    $state = @{ Existing = $false; SchemaFailure = $false; WrongConnection = $false; Running = $false; CliFailure = $false; MissingRole = $false; WrongMirror = $false; AsyncIdentity = $false; Paged = $false }
    $state.WorkspaceSelection = [System.Collections.Generic.Queue[string]]::new()
    $state.NoWorkspaces = $false
    $state.SelectedWorkspaceId = $workspaceId
    $state.ProviderRegistered = $false
    $state.RegistrationFailure = $false
    $state.NamedIdentities = @()
    $state.IdentityDisplayName = 'Customer workspace'

    function Read-Host {
        param($Prompt)
        if (-not $state.WorkspaceSelection.Count) { throw 'Unexpected workspace selection prompt' }
        $state.WorkspaceSelection.Dequeue()
    }

    function az {
        $arguments = @($args)
        $command = $arguments -join ' '
        $cliCalls.Add($command)
        $global:LASTEXITCODE = 0
        if ($state.CliFailure) { $global:LASTEXITCODE = 1; return }
        $server = @{ name = 'sql-eia-dev-1'; identity = @{ principalId = $sqlIdentityId } }
        $db = @{ name = 'InsuranceCustomerBase'; sku = @{ tier = 'Standard'; capacity = 100 } }
        $result = switch -Regex ($command) {
            '^account show ' { @{ id = 'subscription'; tenantId = 'tenant'; user = @{ type = 'user' } }; break }
            '^account get-access-token ' { @{ accessToken = 'mock-token' }; break }
            '^ad signed-in-user show ' { @{ id = 'admin'; userPrincipalName = 'admin@example.com' }; break }
            '^ad sp show ' { @{ displayName = $state.IdentityDisplayName; id = $principalId; appId = $applicationId }; break }
            '^ad sp list ' {
                if ($command -notlike '*--display-name Customer workspace --all*') { throw 'Incorrect workspace name lookup' }
                ,@($state.NamedIdentities); break
            }
            '^group show ' { @{ location = 'centralus' }; break }
            '^provider show ' { @{ registrationState = $(if ($state.ProviderRegistered) { 'Registered' } else { 'NotRegistered' }) }; break }
            '^provider register ' {
                if ($command -notmatch '--namespace Microsoft.Sql --subscription subscription --wait') { throw 'Incorrect provider registration arguments' }
                if ($state.RegistrationFailure) { $global:LASTEXITCODE = 1; return }
                $state.ProviderRegistered = $true
                @{}; break
            }
            '^sql server list ' { if ($state.Existing) { ,@($server) } else { ,@() }; break }
            '^sql server create ' { $server; break }
            '^sql server ad-admin list ' { ,@(@{ login = 'unchanged-admin' }); break }
            '^sql db list ' { if ($state.Existing) { ,@($db) } else { ,@() }; break }
            '^sql db create ' { $db; break }
            '^sql server firewall-rule (create|delete) ' { @{}; break }
            default { throw "Unexpected Azure CLI call: $command" }
        }
        ConvertTo-Json -InputObject $result -Depth 10 -Compress
    }

    function Invoke-Sqlcmd {
        param($ServerInstance, $Database, $AccessToken, $Encrypt, $AbortOnError, $ConnectionTimeout, $QueryTimeout, $InputFile, $Query, $ErrorAction)
        $sqlCalls.Add(@{ Database = $Database; InputFile = $InputFile; Query = $Query; Encrypt = $Encrypt })
        if ($state.PublicNetworkDenied) { throw 'Connection was denied because Deny Public Network Access is set to Yes.' }
        if ($state.ClientInitializationFailure) {
            throw [System.TypeInitializationException]::new('Microsoft.Data.SqlClient.TdsParser',
                [System.DllNotFoundException]::new('Microsoft.Data.SqlClient.SNI.dll'))
        }
        if ($InputFile -and $state.SchemaFailure) { throw 'Simulated schema failure' }
        if ($Encrypt -ne 'Mandatory' -or -not $AbortOnError -or $AccessToken -ne 'mock-token') { throw 'Unsafe SQL parameters' }
        if ($Query -like '*CREATE LOGIN*' -and ($Query -notlike '*EXEC(N''CREATE LOGIN*' -or
            $Query -notlike "*CONVERT(uniqueidentifier, '$applicationId')*" -or
            $Query -notlike "*WITH OBJECT_ID = ''$principalId''*")) { throw 'Login batch or application SID validation is incorrect' }
        $expectedLogin = "$($state.IdentityDisplayName)-$workspaceId"
        $expectedIdentifier = '[' + $expectedLogin.Replace(']', ']]') + ']'
        $expectedLiteral = $expectedLogin.Replace("'", "''")
        if ($Query -like '*CREATE LOGIN*' -and
            (-not $Query.Contains("EXEC(N'CREATE LOGIN " + $expectedIdentifier.Replace("'", "''") + ' FROM EXTERNAL PROVIDER') -or
             -not $Query.Contains("name = N'$expectedLiteral'"))) { throw 'SQL login must preserve and escape the original Entra display name prefix' }
        if ($Query -like '*CREATE USER*' -and
            (-not $Query.Contains("CREATE USER $expectedIdentifier FOR LOGIN $expectedIdentifier;") -or
             -not $Query.Contains("name = N'$expectedLiteral'") -or
             -not $Query.Contains("TO $expectedIdentifier;"))) { throw 'SQL user must use the same escaped login alias' }
    }

    function Invoke-WebRequest {
        param($Uri, $Method, $Headers, $ContentType, $TimeoutSec, $MaximumRetryCount, $RetryIntervalSec, $Body)
        $payload = if ($Body) { $Body | ConvertFrom-Json } else { $null }
        $fabricCalls.Add(@{ Uri = $Uri; Method = $Method; Body = $payload })
        if ($Headers.Authorization -ne 'Bearer mock-token') { throw 'Wrong Fabric authentication' }
        $connection = @{
            id = $connectionId; displayName = "InsuranceCustomerBase-dev-1-$workspaceId"
            connectionDetails = @{ type = 'SQL'; path = 'sql-eia-dev-1.database.windows.net;InsuranceCustomerBase' }
            credentialDetails = @{ credentialType = 'WorkspaceIdentity' }
        }
        if ($state.WrongConnection) { $connection.connectionDetails.path = 'other.database.windows.net;Other' }
        $result = switch -Regex ($Uri) {
            '/workspaces$' {
                if ($state.NoWorkspaces) { @{ value = @() } }
                else {
                    @{ value = @(@{ id = '99999999-2222-3333-4444-555555555555'; displayName = 'Zulu' }); continuationUri = 'https://api.fabric.microsoft.com/v1/workspaces?page=2' }
                }
                break
            }
            '/workspaces\?page=2$' { @{ value = @(@{ id = $state.SelectedWorkspaceId; displayName = 'Alpha' }) }; break }
            '/roleAssignments$' {
                if ($Method -eq 'POST') {
                    if ($payload.role -ne 'Contributor' -or $payload.principal.id -ne $sqlIdentityId) { throw 'Incorrect workspace role grant' }
                    @{ id = 'role' }
                } elseif ($state.MissingRole) { @{ value = @() } }
                else { @{ value = @(@{ principal = @{ id = $sqlIdentityId }; role = 'Contributor' }) } }
                break
            }
            '/connections\?page=2$' { @{ value = @($connection) }; break }
            '/connections$' {
                if ($Method -eq 'POST') {
                    if ($payload.displayName -ne "InsuranceCustomerBase-dev-1-$workspaceId" -or
                        $payload.connectionDetails.parameters.value -notcontains 'InsuranceCustomerBase') { throw 'Incorrect connection target or name' }
                    if ($payload.credentialDetails.credentials.credentialType -ne 'WorkspaceIdentity' -or
                        $payload.credentialDetails.connectionEncryption -ne 'Encrypted') { throw 'Unsafe connection' }
                    if ($payload.credentialDetails.skipTestConnection -ne $false) {
                        throw 'SQL ShareableCloud connections must not skip the connection test'
                    }
                    $connection
                } elseif ($state.Paged) { @{ value = @(); continuationUri = 'https://api.fabric.microsoft.com/v1/connections?page=2' } }
                elseif ($state.Existing) { @{ value = @($connection) } } else { @{ value = @() } }
                break
            }
            '/connections/[a-f0-9-]+$' { $connection; break }
            '/getDefinition$' {
                $definition = @{ properties = @{ source = @{ type = 'AzureSqlDatabase'; typeProperties = @{ connection = $connectionId } } } } | ConvertTo-Json -Depth 10
                if ($state.WrongMirror) { $definition = $definition.Replace($connectionId, 'ffffffff-ffff-ffff-ffff-ffffffffffff') }
                @{ definition = @{ parts = @(@{ path = 'mirroring.json'; payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($definition)) }) } }
                break
            }
            '/mirroredDatabases$' {
                if ($Method -eq 'POST') {
                    if ($payload.displayName -ne 'InsuranceCustomerBase-dev-1') { throw 'Incorrect mirror name' }
                    $definition = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload.definition.parts[0].payload)) | ConvertFrom-Json
                    if ($definition.properties.source.type -ne 'AzureSqlDatabase' -or
                        $definition.properties.source.typeProperties.connection -ne $connectionId -or
                        $definition.properties.target.typeProperties.defaultSchema -ne 'dbo') { throw 'Invalid mirror definition' }
                    @{ id = 'mirror'; displayName = 'InsuranceCustomerBase-dev-1' }
                } elseif ($state.Existing) { @{ value = @(@{ id = 'mirror'; displayName = 'InsuranceCustomerBase-dev-1' }) } }
                else { @{ value = @() } }
                break
            }
            '/getMirroringStatus$' { @{ status = $(if ($state.Running) { 'Running' } else { 'Initialized' }) }; break }
            '/startMirroring$' { $state.Running = $true; $null; break }
            '/mirroredDatabases/mirror$' { @{ properties = @{ oneLakeTablesPath = 'onelake-path'; sqlEndpointProperties = @{ connectionString = 'analytics-endpoint' } } }; break }
            '/provisionIdentity$' {
                if ($state.IdentityProvisionError) {
                    $failure = [System.Management.Automation.ErrorRecord]::new(
                        [System.Exception]::new('Identity provisioning failed'), 'FabricError',
                        [System.Management.Automation.ErrorCategory]::InvalidOperation, $Uri)
                    $failure.ErrorDetails = [System.Management.Automation.ErrorDetails]::new(
                        (@{ errorCode = $state.IdentityProvisionError } | ConvertTo-Json -Compress))
                    throw $failure
                }
                return @{ StatusCode = 202; Headers = @{ Location = @('https://api.fabric.microsoft.com/v1/operations/identity') }; Content = '' }
            }
            '/operations/identity$' { @{ status = 'Succeeded' }; break }
            '/operations/identity/result$' { $state.AsyncIdentity = $false; @{ servicePrincipalId = $principalId }; break }
            '/workspaces/[a-f0-9-]+$' {
                if ($state.MissingIdentityResponses -gt 0) {
                    $state.MissingIdentityResponses--
                    @{ capacityId = 'capacity'; displayName = 'Customer workspace' }
                } elseif ($state.AsyncIdentity) { @{ capacityId = 'capacity'; displayName = 'Customer workspace' } }
                else { @{ capacityId = 'capacity'; workspaceIdentity = @{ servicePrincipalId = $principalId; applicationId = $applicationId } } }
                break
            }
            default { throw "Unexpected Fabric call: $Method $Uri" }
        }
        @{ StatusCode = 200; Headers = @{}; Content = $(if ($null -ne $result) { ConvertTo-Json -InputObject $result -Depth 20 -Compress } else { '' }) }
    }

    $scriptAst = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
    foreach ($helperName in @('Invoke-AzureCli', 'Invoke-Fabric')) {
        $helper = $scriptAst.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $helperName }, $false)
        . ([scriptblock]::Create($helper.Extent.Text))
    }
    foreach ($allowedPath in @('connections', '/v1/connections', 'https://API.FABRIC.MICROSOFT.COM/v1/connections')) {
        $null = Invoke-Fabric $allowedPath
    }
    $cliCalls.Clear(); $fabricCalls.Clear()
    foreach ($rejectedPath in @(
        'https://untrusted.example/v1/connections?secret=hidden',
        'https://api.fabric.microsoft.com.untrusted.example/v1/connections',
        'http://api.fabric.microsoft.com/v1/connections',
        'https://api.fabric.microsoft.com:8443/v1/connections',
        'https://hidden@api.fabric.microsoft.com/v1/connections',
        'https://api.fabric.microsoft.com/other/connections',
        '//untrusted.example/v1/connections'
    )) {
        try { $null = Invoke-Fabric $rejectedPath; throw 'Expected URL rejection' }
        catch {
            if ($_ -notmatch 'Unexpected Fabric request URL for GET:' -or $_ -match 'hidden') { throw }
        }
    }
    if ($cliCalls.Count -or $fabricCalls.Count) { throw 'Rejected URL accessed credentials or network' }
    Write-Output 'PASS: Fabric URLs are normalized and untrusted targets rejected without credentials or query disclosure'

    $null = & $scriptPath -WorkspaceId $workspaceId -WhatIf
    $null = & $scriptPath -WhatIf
    if ($cliCalls.Count -or $fabricCalls.Count -or $sqlCalls.Count) { throw 'WhatIf invoked a remote service' }
    Write-Output 'PASS: WhatIf does not access cloud services'

    $result = & $scriptPath -WorkspaceId $workspaceId -ClientIpAddress '192.0.2.1'
    if ($result.MirroringStatus -ne 'Running' -or $result.Database -ne 'InsuranceCustomerBase' -or
        -not ($cliCalls | Where-Object { $_ -match '^sql server create .*--enable-ad-only-auth' }) -or
        -not ($cliCalls | Where-Object { $_ -match '^sql db create .*--service-objective S3' }) -or
        -not ($cliCalls | Where-Object { $_ -match '^sql server firewall-rule delete ' }) -or
        -not ($sqlCalls | Where-Object { $_.InputFile -like '*InsuranceCustomerBaseDB.sql' })) { throw 'Provisioning flow failed' }
    Write-Output 'PASS: New database, authoritative schema, passwordless connection, mirror, and firewall cleanup'
    $registrationIndex = $cliCalls.FindIndex([Predicate[string]]{ param($command) $command -match '^provider register ' })
    $sqlIndex = $cliCalls.FindIndex([Predicate[string]]{ param($command) $command -match '^sql ' })
    if (-not $state.ProviderRegistered -or $registrationIndex -lt 0 -or $registrationIndex -ge $sqlIndex) { throw 'Provider was not registered before SQL provisioning' }
    Write-Output 'PASS: Microsoft.Sql registration waits before SQL provisioning'

    $state.Existing = $true
    $cliCalls.Clear(); $fabricCalls.Clear(); $sqlCalls.Clear()
    $result = & $scriptPath -WorkspaceId $workspaceId
    if ($result.MirroringStatus -ne 'Running' -or
        ($cliCalls | Where-Object { $_ -match '^provider register ' }) -or
        ($cliCalls | Where-Object { $_ -match '^sql (server|db) create ' }) -or
        ($fabricCalls | Where-Object { $_.Method -eq 'POST' -and $_.Uri -match '/(connections|mirroredDatabases|startMirroring)$' })) { throw 'Rerun recreated resources' }
    Write-Output 'PASS: Rerun reuses existing resources and does not restart a running mirror'

    $state.IdentityDisplayName = "Insurer's [workspace]"
    $null = & $scriptPath -WorkspaceId $workspaceId
    Write-Output 'PASS: Login alias begins with the Entra name and safely escapes apostrophes and brackets in all SQL contexts'
    foreach ($invalidName in @('', ('X' * 92))) {
        $state.IdentityDisplayName = $invalidName
        $sqlCalls.Clear()
        try { $null = & $scriptPath -WorkspaceId $workspaceId; throw 'Expected SQL alias validation failure' }
        catch { if ($_ -notmatch 'no Entra display name|exceeds the SQL login limit') { throw } }
        if ($sqlCalls | Where-Object { $_.Query -like '*CREATE LOGIN*' -or $_.Query -like '*CREATE USER*' }) {
            throw 'Invalid SQL alias reached principal creation'
        }
    }
    $state.IdentityDisplayName = 'Customer workspace'
    Write-Output 'PASS: Missing and overlength Entra login names stop before principal creation'

    $state.ProviderRegistered = $false
    $state.RegistrationFailure = $true
    $cliCalls.Clear(); $sqlCalls.Clear()
    try { $null = & $scriptPath -WorkspaceId $workspaceId; throw 'Expected registration failure' }
    catch { if ($_ -notmatch 'Azure CLI failed: provider register') { throw } }
    if ($sqlCalls.Count -or ($cliCalls | Where-Object { $_ -match '^sql ' })) { throw 'Registration failure continued to SQL provisioning' }
    $state.RegistrationFailure = $false
    $state.ProviderRegistered = $true
    Write-Output 'PASS: Registration failure stops before SQL provisioning'

    $state.SchemaFailure = $true
    $cliCalls.Clear(); $fabricCalls.Clear()
    try { $null = & $scriptPath -WorkspaceId $workspaceId -ClientIpAddress '192.0.2.1'; throw 'Expected schema failure' }
    catch { if ($_ -notmatch 'Simulated schema failure') { throw } }
    if (-not ($cliCalls | Where-Object { $_ -match '^sql server firewall-rule delete ' }) -or
        ($fabricCalls | Where-Object { $_.Uri -match '/startMirroring$' })) { throw 'Schema failure did not clean up or stop deployment' }
    Write-Output 'PASS: Schema failure stops deployment and removes temporary firewall access'
    $state.SchemaFailure = $false

    $state.WrongConnection = $true
    try { $null = & $scriptPath -WorkspaceId $workspaceId -FabricConnectionId $connectionId; throw 'Expected connection mismatch' }
    catch { if ($_ -notmatch 'does not target') { throw } }
    Write-Output 'PASS: Mismatched Fabric connection is rejected'
    $state.WrongConnection = $false

    $state.WrongMirror = $true
    try { $null = & $scriptPath -WorkspaceId $workspaceId; throw 'Expected mirror mismatch' }
    catch { if ($_ -notmatch 'different source') { throw } }
    Write-Output 'PASS: Existing mirror with a different source is never overwritten'
    $state.WrongMirror = $false

    $state.MissingRole = $true
    $fabricCalls.Clear()
    try { $null = & $scriptPath -WorkspaceId $workspaceId; throw 'Expected permission handoff' }
    catch { if ($_ -notmatch 'Read and Write') { throw } }
    if ($fabricCalls | Where-Object { $_.Method -eq 'POST' -and $_.Uri -match '/(roleAssignments|startMirroring)$' }) { throw 'Expanded workspace access without opt-in' }
    Write-Output 'PASS: Item-level permission handoff does not silently expand workspace access'
    $null = & $scriptPath -WorkspaceId $workspaceId -SqlIdentityItemWriteGranted
    $null = & $scriptPath -WorkspaceId $workspaceId -GrantSqlIdentityWorkspaceContributor
    if (-not ($fabricCalls | Where-Object { $_.Method -eq 'POST' -and $_.Uri -match '/roleAssignments$' })) { throw 'Opt-in role grant was not applied' }
    Write-Output 'PASS: Explicit item-level confirmation and workspace role opt-in are supported'
    $state.MissingRole = $false

    $state.AsyncIdentity = $true
    $state.Paged = $true
    $null = & $scriptPath -WorkspaceId $workspaceId
    if ($state.AsyncIdentity -or -not ($fabricCalls | Where-Object { $_.Uri -match '/connections\?page=2$' })) { throw 'Async identity provisioning or pagination failed' }
    Write-Output 'PASS: Fabric asynchronous identity provisioning and connection pagination'

    $state.IdentityProvisionError = 'WorkspaceIdentityAlreadyExists'
    $state.MissingIdentityResponses = 1
    $fabricCalls.Clear()
    $result = & $scriptPath -WorkspaceId $workspaceId
    if ($result.MirroringStatus -ne 'Running' -or
        @($fabricCalls | Where-Object { $_.Uri -match '/provisionIdentity$' }).Count -ne 1) { throw 'Existing workspace identity was not recovered' }
    Write-Output 'PASS: Already-provisioned workspace identity is refreshed and reused'

    $state.MissingIdentityResponses = 2
    $sqlCalls.Clear()
    try { $null = & $scriptPath -WorkspaceId $workspaceId; throw 'Expected unavailable identity failure' }
    catch { if ($_ -notmatch 'rerun with -WorkspaceIdentityObjectId') { throw } }
    if ($sqlCalls.Count) { throw 'Unavailable identity continued to SQL setup' }
    Write-Output 'PASS: Missing identity details stop setup after an already-exists response'

    foreach ($errorCode in @('InsufficientPrivileges', 'UnknownError')) {
        $state.IdentityProvisionError = $errorCode
        $state.MissingIdentityResponses = 1
        try { $null = & $scriptPath -WorkspaceId $workspaceId; throw 'Expected identity provisioning failure' }
        catch { if ($_.ErrorDetails.Message -notmatch $errorCode) { throw } }
    }
    $state.IdentityProvisionError = $null
    Write-Output 'PASS: Other identity provisioning errors are not suppressed'

    $state.MissingIdentityResponses = 1
    $fabricCalls.Clear()
    $null = & $scriptPath -WorkspaceId $workspaceId -WorkspaceIdentityObjectId $principalId
    if ($fabricCalls | Where-Object { $_.Uri -match '/provisionIdentity$' }) { throw 'Explicit identity unnecessarily provisioned an identity' }
    Write-Output 'PASS: Explicit workspace identity resolves its application ID through Entra when Fabric omits identity metadata'

    try { $null = & $scriptPath -WorkspaceId $workspaceId -WorkspaceIdentityObjectId $sqlIdentityId; throw 'Expected invalid identity failure' }
    catch { if ($_ -notmatch 'did not resolve to a valid Entra service principal') { throw } }
    Write-Output 'PASS: Explicit workspace identity must resolve to the requested service principal'

    $state.NamedIdentities = @(
        @{ displayName = 'Customer workspace'; id = $principalId; appId = $applicationId; accountEnabled = $true },
        @{ displayName = 'Customer workspace old'; id = $sqlIdentityId; accountEnabled = $true }
    )
    $state.MissingIdentityResponses = 1
    $fabricCalls.Clear(); $cliCalls.Clear()
    $null = & $scriptPath -WorkspaceId $workspaceId
    if (($fabricCalls | Where-Object { $_.Uri -match '/provisionIdentity$' }) -or
        -not ($cliCalls | Where-Object { $_ -like 'ad sp show --id *' })) { throw 'Name lookup failed to reuse and validate the identity' }
    Write-Output 'PASS: Exact workspace name resolves an existing identity without provisioning'

    $state.NamedIdentities[1].displayName = 'Customer workspace'
    $state.MissingIdentityResponses = 1
    $sqlCalls.Clear()
    try { $null = & $scriptPath -WorkspaceId $workspaceId; throw 'Expected ambiguous identity failure' }
    catch { if ($_ -notmatch 'Multiple Entra service principals') { throw } }
    if ($sqlCalls.Count) { throw 'Ambiguous name continued to SQL setup' }
    Write-Output 'PASS: Duplicate identity names require an explicit object ID'

    $state.MissingIdentityResponses = 1
    $cliCalls.Clear()
    $null = & $scriptPath -WorkspaceId $workspaceId -WorkspaceIdentityObjectId $principalId
    if ($cliCalls | Where-Object { $_ -like 'ad sp list *' }) { throw 'Explicit identity did not bypass name lookup' }
    Write-Output 'PASS: Explicit object ID takes precedence over duplicate names'

    foreach ($invalidId in @('not-a-guid', [string][guid]::Empty)) {
        $state.NamedIdentities = @(@{ displayName = 'Customer workspace'; id = $invalidId; accountEnabled = $true })
        $state.MissingIdentityResponses = 1
        $sqlCalls.Clear()
        try { $null = & $scriptPath -WorkspaceId $workspaceId; throw 'Expected invalid identity ID failure' }
        catch { if ($_ -notmatch 'named workspace identity has an invalid object ID') { throw } }
        if ($sqlCalls.Count) { throw 'Invalid named identity continued to SQL setup' }
    }
    Write-Output 'PASS: Named identity object IDs must be valid nonempty GUIDs'

    $state.NamedIdentities = @(@{ displayName = 'Customer workspace'; id = $principalId; accountEnabled = $false })
    $state.MissingIdentityResponses = 1
    try { $null = & $scriptPath -WorkspaceId $workspaceId; throw 'Expected disabled identity failure' }
    catch { if ($_ -notmatch 'disabled or its enabled state is unavailable') { throw } }
    $state.NamedIdentities = @()
    Write-Output 'PASS: Disabled named identities are not reused'

    $state.ClientInitializationFailure = $true
    $sqlCalls.Clear()
    try { $null = & $scriptPath -WorkspaceId $workspaceId; throw 'Expected SQL client initialization failure' }
    catch { if ($_ -notmatch 'Local SQL client initialization failed.*Restart PowerShell') { throw } }
    if ($sqlCalls.Count -ne 1) { throw 'SQL client initialization failure was retried' }
    $state.ClientInitializationFailure = $false
    if ($IsWindows -and [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -eq
        [System.Runtime.InteropServices.Architecture]::Arm64) {
        $managedNetworking = $false
        if (-not [AppContext]::TryGetSwitch('Switch.Microsoft.Data.SqlClient.UseManagedNetworkingOnWindows', [ref]$managedNetworking) -or
            -not $managedNetworking) { throw 'ARM64 SQL managed networking was not enabled' }
    }
    Write-Output 'PASS: SQL client initialization failures stop immediately and ARM64 uses managed networking'

    $state.PublicNetworkDenied = $true
    $sqlCalls.Clear(); $cliCalls.Clear()
    try { $null = & $scriptPath -WorkspaceId $workspaceId; throw 'Expected SQL public network denial' }
    catch { if ($_ -notmatch 'denies public network access.*private endpoint.*do not enable public access') { throw } }
    if ($sqlCalls.Count -ne 1) { throw 'Public network denial was retried' }
    if ($cliCalls | Where-Object { $_ -match '--enable-public-network|--public-network-access' }) { throw 'Public access policy was changed automatically' }
    $state.PublicNetworkDenied = $false
    Write-Output 'PASS: Public network denial stops immediately without enabling public access'

    $fabricCalls.Clear()
    foreach ($answer in @('invalid', '0', '3', '1')) { $state.WorkspaceSelection.Enqueue($answer) }
    $result = & $scriptPath
    if ($result.WorkspaceId -ne $workspaceId -or $state.WorkspaceSelection.Count -or
        -not ($fabricCalls | Where-Object { $_.Uri -match '/workspaces\?page=2$' })) { throw 'Workspace selection or pagination failed' }
    Write-Output 'PASS: Workspace selection handles pagination, sorting, and invalid input'

    $cliCalls.Clear(); $fabricCalls.Clear(); $sqlCalls.Clear()
    $state.WorkspaceSelection.Enqueue('Q')
    $null = & $scriptPath
    if ($sqlCalls.Count -or ($fabricCalls | Where-Object Method -NE 'GET') -or
        ($cliCalls | Where-Object { $_ -match '^(sql |provider register )' })) { throw 'Cancellation changed resources' }
    $state.NoWorkspaces = $true
    try { $null = & $scriptPath; throw 'Expected no workspaces failure' }
    catch { if ($_ -notmatch 'No accessible Fabric workspaces') { throw } }
    $state.NoWorkspaces = $false
    Write-Output 'PASS: Cancellation and empty workspace lists stop before provisioning'

    $state.CliFailure = $true
    try { $null = & $scriptPath -WorkspaceId $workspaceId; throw 'Expected Azure CLI failure' }
    catch { if ($_ -notmatch 'Azure CLI failed') { throw } }
    Write-Output 'PASS: Native command failure stops provisioning'
}
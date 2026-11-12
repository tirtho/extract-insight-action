#Requires -Version 7.0
<#
.SYNOPSIS
Creates InsuranceCustomerBase in Azure SQL and mirrors it into Fabric.
.DESCRIPTION
Uses the current Azure CLI user and subscription. Requires the SqlServer module.
Omit WorkspaceId to select from accessible Fabric workspaces in the current tenant.
Existing tables are preserved; the schema file is not a migration engine.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidatePattern('^[a-z][a-z0-9-]{0,19}$')]
    [string]$Environment = 'dev',
    [ValidatePattern('^[0-9]{1,10}$')]
    [string]$Suffix = '1',
    [guid]$WorkspaceId = [guid]::Empty,
    [ValidatePattern('^[a-z0-9][a-z0-9-]{0,61}[a-z0-9]$')]
    [string]$SqlServerName,
    [Nullable[guid]]$FabricConnectionId,
    [guid]$WorkspaceIdentityObjectId = [guid]::Empty,
    [string]$ClientIpAddress,
    [switch]$AllowAzureServices,
    [switch]$GrantSqlIdentityWorkspaceContributor,
    [switch]$SqlIdentityItemWriteGranted
)

$ErrorActionPreference = 'Stop'
$resourceGroupName = "rg-eia-$Environment-$Suffix"
if (-not $SqlServerName) { $SqlServerName = "sql-eia-$Environment-$Suffix" }
$databaseName = 'InsuranceCustomerBase'
$schemaPath = Join-Path $PSScriptRoot 'sql/InsuranceCustomerBaseDB.sql'
$mirrorName = "$databaseName-$Environment-$Suffix"

function Invoke-AzureCli {
    param([Parameter(ValueFromRemainingArguments)][string[]]$Arguments)
    $result = & az @Arguments --only-show-errors --output json
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI failed: $($Arguments[0..1] -join ' ')." }
    if ($result) { ($result -join "`n") | ConvertFrom-Json }
}

function Invoke-CustomerSql {
    param([string]$Database = $databaseName, [string]$Query, [string]$InputFile)
    $token = Invoke-AzureCli @('account', 'get-access-token', '--resource', 'https://database.windows.net/')
    $sqlParameters = @{
        ServerInstance = "$SqlServerName.database.windows.net"
        Database = $Database
        AccessToken = $token.accessToken
        Encrypt = 'Mandatory'
        AbortOnError = $true
        ErrorAction = 'Stop'
        ConnectionTimeout = 15
        QueryTimeout = 300
    }
    if ($InputFile) { $sqlParameters.InputFile = $InputFile }
    else { $sqlParameters.Query = $Query }
    Invoke-Sqlcmd @sqlParameters
}

function Invoke-Fabric {
    param([string]$Path, [string]$Method = 'GET', [object]$Body)
    $uri = $null
    if (-not [uri]::TryCreate([uri]'https://api.fabric.microsoft.com/v1/', $Path, [ref]$uri)) {
        throw 'Fabric returned an invalid request URL.'
    }
    if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'api.fabric.microsoft.com' -or
        $uri.Port -ne 443 -or $uri.UserInfo -or
        -not $uri.AbsolutePath.StartsWith('/v1/', [StringComparison]::Ordinal)) {
        $safeTarget = '{0}://{1}:{2}{3}' -f $uri.Scheme, $uri.Host, $uri.Port, $uri.AbsolutePath
        throw "Unexpected Fabric request URL for ${Method}: $safeTarget (query omitted). Expected https://api.fabric.microsoft.com/v1/."
    }
    $token = Invoke-AzureCli @('account', 'get-access-token', '--resource', 'https://api.fabric.microsoft.com')
    $parameters = @{
        Uri = $uri; Method = $Method
        Headers = @{ Authorization = "Bearer $($token.accessToken)" }
        ContentType = 'application/json'; TimeoutSec = 120
        MaximumRetryCount = 4; RetryIntervalSec = 5
    }
    if ($null -ne $Body) { $parameters.Body = $Body | ConvertTo-Json -Depth 30 -Compress }
    $response = Invoke-WebRequest @parameters
    if ([int]$response.StatusCode -eq 202) {
        $operationUri = [string]($response.Headers.Location | Select-Object -First 1)
        if (-not $operationUri) { throw 'Fabric returned 202 without an operation Location.' }
        for ($attempt = 0; $attempt -lt 60; $attempt++) {
            $operation = Invoke-Fabric $operationUri
            if ($operation.status -eq 'Succeeded') { return Invoke-Fabric "$($operationUri.TrimEnd('/'))/result" }
            if ($operation.status -in @('Failed', 'Cancelled')) { throw "Fabric operation failed: $($operation | ConvertTo-Json -Depth 10 -Compress)" }
            Start-Sleep -Seconds 5
        }
        throw "Timed out waiting for Fabric operation: $operationUri"
    }
    if ($response.Content) { $response.Content | ConvertFrom-Json }
}

function Get-FabricCollection {
    param([string]$Path)
    do {
        $page = Invoke-Fabric $Path
        $page.value
        $Path = $page.continuationUri
    } while ($Path)
}

function Assert-CustomerConnection {
    param([object]$Connection)
    if ($Connection.connectionDetails.type -ne 'SQL' -or
        $Connection.connectionDetails.path -ine "$SqlServerName.database.windows.net;$databaseName") {
        throw 'Fabric connection does not target this InsuranceCustomerBase Azure SQL database.'
    }
}

if (-not (Test-Path -LiteralPath $schemaPath -PathType Leaf)) { throw "Schema not found: $schemaPath" }
if ($PSBoundParameters.ContainsKey('WorkspaceId') -and $WorkspaceId -eq [guid]::Empty) { throw 'WorkspaceId must not be empty.' }
if ($ClientIpAddress) {
    $parsedIp = $null
    if (-not [System.Net.IPAddress]::TryParse($ClientIpAddress, [ref]$parsedIp) -or
        $parsedIp.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork -or
        $ClientIpAddress -eq '0.0.0.0') { throw 'ClientIpAddress must be a nonzero IPv4 address.' }
}
if ($WhatIfPreference) {
    $workspaceTarget = if ($WorkspaceId -ne [guid]::Empty) { "$WorkspaceId" } else { '<select workspace at runtime>' }
    $null = $PSCmdlet.ShouldProcess("$resourceGroupName/$SqlServerName/$databaseName -> Fabric $workspaceTarget/$mirrorName", 'Provision Azure SQL, apply schema, and configure mirroring')
    return
}
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Install Azure CLI and sign in with az login first.' }
if ($IsWindows -and [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -eq
    [System.Runtime.InteropServices.Architecture]::Arm64) {
    [AppContext]::SetSwitch('Switch.Microsoft.Data.SqlClient.UseManagedNetworkingOnWindows', $true)
    Write-Warning 'Windows ARM64: using SqlClient managed networking to avoid native SNI dependencies. Microsoft documents this switch for testing/debugging only; use x64 PowerShell with native SqlClient dependencies for production provisioning.'
}
if (-not (Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue)) { throw 'Install the current SqlServer PowerShell module first.' }
if (-not (Get-Command Invoke-Sqlcmd).Parameters.ContainsKey('Encrypt')) { throw 'Update the SqlServer module to version 22 or later.' }

$account = Invoke-AzureCli @('account', 'show')
if ($account.user.type -ne 'user') { throw 'Sign in to Azure CLI as the administrator user, not a service principal.' }
if ($WorkspaceId -eq [guid]::Empty) {
    $workspaces = @(Get-FabricCollection 'workspaces' | Sort-Object displayName, id)
    if (-not $workspaces.Count) { throw 'No accessible Fabric workspaces were found in the signed-in tenant.' }
    Write-Host "Accessible Fabric workspaces in tenant $($account.tenantId):"
    for ($index = 0; $index -lt $workspaces.Count; $index++) {
        Write-Host ("{0}. {1} [{2}]" -f ($index + 1), $workspaces[$index].displayName, $workspaces[$index].id)
    }
    do {
        $selection = Read-Host 'Select a workspace number (or Q to cancel)'
        if ($selection -eq 'q') { Write-Host 'Workspace selection cancelled. No resources were changed.'; return }
        $selectionNumber = 0
        $validSelection = [int]::TryParse($selection, [ref]$selectionNumber) -and
            $selectionNumber -ge 1 -and $selectionNumber -le $workspaces.Count
        if (-not $validSelection) { Write-Warning "Enter a number from 1 to $($workspaces.Count), or Q to cancel." }
    } until ($validSelection)
    $WorkspaceId = [guid]$workspaces[$selectionNumber - 1].id
    Write-Host "Selected workspace: $($workspaces[$selectionNumber - 1].displayName) [$WorkspaceId]"
}
if (-not $PSCmdlet.ShouldProcess("$resourceGroupName/$SqlServerName/$databaseName -> Fabric $WorkspaceId/$mirrorName", 'Provision Azure SQL, apply schema, and configure mirroring')) { return }
$admin = Invoke-AzureCli @('ad', 'signed-in-user', 'show')
$resourceGroup = Invoke-AzureCli @('group', 'show', '--name', $resourceGroupName)
$workspacePath = "workspaces/$WorkspaceId"
$workspace = Invoke-Fabric $workspacePath
if (-not $workspace.capacityId) { throw 'Assign the workspace to an active Fabric capacity before running this script.' }
$roles = @(Get-FabricCollection "$workspacePath/roleAssignments")
$sqlProvider = Invoke-AzureCli @('provider', 'show', '--namespace', 'Microsoft.Sql', '--subscription', $account.id)
if ($sqlProvider.registrationState -ne 'Registered') {
    Write-Host "Registering Microsoft.Sql in subscription $($account.id); this can take several minutes."
    $null = Invoke-AzureCli @('provider', 'register', '--namespace', 'Microsoft.Sql', '--subscription', $account.id, '--wait')
    $sqlProvider = Invoke-AzureCli @('provider', 'show', '--namespace', 'Microsoft.Sql', '--subscription', $account.id)
    if ($sqlProvider.registrationState -ne 'Registered') { throw 'Microsoft.Sql registration did not complete. Check subscription provider-registration permissions and rerun.' }
}
$servers = @(Invoke-AzureCli @('sql', 'server', 'list', '--resource-group', $resourceGroupName))
$server = $servers | Where-Object name -EQ $SqlServerName | Select-Object -First 1
if (-not $server) {
    Write-Host "Creating Entra-only SQL server $SqlServerName in $($resourceGroup.location)."
    $server = Invoke-AzureCli @('sql', 'server', 'create', '--resource-group', $resourceGroupName,
        '--name', $SqlServerName, '--location', $resourceGroup.location, '--assign-identity',
        '--enable-ad-only-auth', '--external-admin-principal-type', 'User',
        '--external-admin-name', $admin.userPrincipalName, '--external-admin-sid', $admin.id,
        '--minimal-tls-version', '1.2')
} else {
    $administrators = @(Invoke-AzureCli @('sql', 'server', 'ad-admin', 'list', '--resource-group', $resourceGroupName, '--server', $SqlServerName))
    if (-not $administrators) { throw 'The existing SQL server needs an Entra administrator; configure it explicitly before rerunning.' }
    if ($server.primaryUserAssignedIdentityId) { throw 'An existing user-assigned primary identity is configured; this script requires a system-assigned primary identity.' }
    if (-not $server.identity.principalId) {
        $server = Invoke-AzureCli @('sql', 'server', 'update', '--resource-group', $resourceGroupName, '--name', $SqlServerName, '--assign-identity')
    }
}
$sqlIdentityId = $server.identity.principalId
if (-not $sqlIdentityId) { throw 'SQL server system-assigned identity was not returned.' }
$identityRole = $roles | Where-Object { $_.principal.id -eq $sqlIdentityId -and $_.role -in @('Admin', 'Member', 'Contributor') }
if (-not $identityRole -and $GrantSqlIdentityWorkspaceContributor) {
    Write-Warning 'Granting the SQL server identity Contributor access to the entire Fabric workspace.'
    $null = Invoke-Fabric "$workspacePath/roleAssignments" 'POST' @{
        principal = @{ id = $sqlIdentityId; type = 'ServicePrincipal' }; role = 'Contributor'
    }
}

if (-not $FabricConnectionId) {
    if ($WorkspaceIdentityObjectId -eq [guid]::Empty -and
        (-not $workspace.workspaceIdentity.servicePrincipalId -or -not $workspace.workspaceIdentity.applicationId) -and
        -not [string]::IsNullOrWhiteSpace($workspace.displayName)) {
        $namedIdentities = @(Invoke-AzureCli @('ad', 'sp', 'list', '--display-name', $workspace.displayName, '--all') |
            Where-Object { $_.displayName -ceq $workspace.displayName })
        if ($namedIdentities.Count -gt 1) {
            throw "Multiple Entra service principals match workspace name '$($workspace.displayName)'. Verify the current workspace identity and rerun with -WorkspaceIdentityObjectId <object-id>."
        }
        if ($namedIdentities.Count -eq 1) {
            if ($namedIdentities[0].accountEnabled -ne $true) {
                throw 'The Entra identity matching the workspace name is disabled or its enabled state is unavailable. Check Workspace settings > Workspace identity before rerunning.'
            }
            if (-not [guid]::TryParse([string]$namedIdentities[0].id, [ref]$WorkspaceIdentityObjectId) -or
                $WorkspaceIdentityObjectId -eq [guid]::Empty) {
                throw 'The named workspace identity has an invalid object ID.'
            }
            Write-Host "Using Entra workspace identity '$($workspace.displayName)' [$WorkspaceIdentityObjectId]."
        }
    }
    if ($WorkspaceIdentityObjectId -ne [guid]::Empty) {
        $identity = Invoke-AzureCli @('ad', 'sp', 'show', '--id', "$WorkspaceIdentityObjectId")
        $identityApplicationId = [guid]::Empty
        if ($identity.id -ne "$WorkspaceIdentityObjectId" -or
            -not [guid]::TryParse([string]$identity.appId, [ref]$identityApplicationId) -or
            $identityApplicationId -eq [guid]::Empty) {
            throw 'The supplied WorkspaceIdentityObjectId did not resolve to a valid Entra service principal.'
        }
        if ($workspace.workspaceIdentity.servicePrincipalId -and
            $workspace.workspaceIdentity.servicePrincipalId -ne "$WorkspaceIdentityObjectId") {
            throw 'WorkspaceIdentityObjectId does not match the identity returned by Fabric.'
        }
        $workspace | Add-Member -NotePropertyName workspaceIdentity -NotePropertyValue @{
            servicePrincipalId = "$WorkspaceIdentityObjectId"; applicationId = "$identityApplicationId"
        } -Force
    }
    if (-not $workspace.workspaceIdentity.servicePrincipalId) {
        try {
            $null = Invoke-Fabric "$workspacePath/provisionIdentity" 'POST'
        } catch {
            $fabricError = try { $_.ErrorDetails.Message | ConvertFrom-Json } catch { $null }
            if ($fabricError.errorCode -ne 'WorkspaceIdentityAlreadyExists') { throw }
            Write-Host 'Fabric workspace identity already exists; refreshing workspace details.'
        }
        $workspace = Invoke-Fabric $workspacePath
    }
    if (-not $workspace.workspaceIdentity.servicePrincipalId -or -not $workspace.workspaceIdentity.applicationId) {
        throw 'Fabric did not return workspace identity details. In Fabric, open Workspace settings > Workspace identity and obtain the service principal object ID, then rerun with -WorkspaceIdentityObjectId <object-id>. Do not use the workspace ID or application/client ID.'
    }
}
$databases = @(Invoke-AzureCli @('sql', 'db', 'list', '--resource-group', $resourceGroupName, '--server', $SqlServerName))
$database = $databases | Where-Object name -EQ $databaseName | Select-Object -First 1
if (-not $database) {
    Write-Host 'Creating InsuranceCustomerBase (Standard S3, 100 DTUs; billable).'
    $database = Invoke-AzureCli @('sql', 'db', 'create', '--resource-group', $resourceGroupName,
        '--server', $SqlServerName, '--name', $databaseName, '--edition', 'Standard', '--service-objective', 'S3')
} elseif ($database.sku.tier -in @('Basic', 'Free', 'Standard') -and [int]$database.sku.capacity -lt 100) {
    throw 'Existing InsuranceCustomerBase tier does not support Fabric mirroring. Upgrade explicitly to S3 or a supported vCore tier.'
}

$temporaryRuleName = $null
try {
    if ($AllowAzureServices) {
        Write-Warning 'AllowAzureServices permits connections from ALL Azure tenants, not just this tenant. SQL authentication remains required.'
        $null = Invoke-AzureCli @('sql', 'server', 'firewall-rule', 'create', '--resource-group', $resourceGroupName,
            '--server', $SqlServerName, '--name', 'AllowAllWindowsAzureIps', '--start-ip-address', '0.0.0.0', '--end-ip-address', '0.0.0.0')
    }
    if ($ClientIpAddress) {
        $temporaryRuleName = "CustomerBaseSetup-$([guid]::NewGuid().ToString('N'))"
        $null = Invoke-AzureCli @('sql', 'server', 'firewall-rule', 'create', '--resource-group', $resourceGroupName,
            '--server', $SqlServerName, '--name', $temporaryRuleName, '--start-ip-address', $ClientIpAddress, '--end-ip-address', $ClientIpAddress)
    }
    Write-Host "Applying $schemaPath using the signed-in Entra administrator."
    for ($attempt = 0; $attempt -lt 12; $attempt++) {
        try {
            $null = Invoke-CustomerSql -Query 'SELECT 1 AS Ready;'
            break
        } catch {
            $sqlException = $_.Exception
            while ($null -ne $sqlException) {
                if ($sqlException.Number -eq 47073 -or
                    $sqlException.Message -match 'Deny Public Network Access|public network access.*disabled') {
                    throw [System.InvalidOperationException]::new(
                        "Azure SQL server '$SqlServerName' denies public network access. Run from a network with access to its private endpoint and private DNS, or explicitly enable selected-network public access in the server Networking settings and allow your client IPv4 address. -ClientIpAddress and -AllowAzureServices only add firewall rules; they do not enable public access. The script will not change this policy automatically.", $_.Exception)
                }
                if ($sqlException -is [System.TypeInitializationException] -or
                    $sqlException -is [System.DllNotFoundException] -or
                    $sqlException -is [System.BadImageFormatException]) {
                    throw [System.InvalidOperationException]::new(
                        'Local SQL client initialization failed. Restart PowerShell before rerunning so the ARM64 managed-networking setting takes effect. If it persists, repair the SqlServer module and its dependencies.', $_.Exception)
                }
                $sqlException = $sqlException.InnerException
            }
            if ($attempt -eq 11) { throw }
            Write-Host 'Waiting for SQL authentication and network access to become available...'
            Start-Sleep -Seconds 5
        }
    }
    Invoke-CustomerSql -InputFile $schemaPath

    $connectionName = "$mirrorName-$WorkspaceId"
    if ($FabricConnectionId) {
        $connection = Invoke-Fabric "connections/$FabricConnectionId"
        Assert-CustomerConnection $connection
    } else {
        $workspacePrincipalId = [guid]$workspace.workspaceIdentity.servicePrincipalId
        $workspaceApplicationId = [guid]$workspace.workspaceIdentity.applicationId
        if ($workspaceApplicationId -eq [guid]::Empty) { throw 'Fabric workspace identity application ID is missing.' }
        $loginIdentity = Invoke-AzureCli @('ad', 'sp', 'show', '--id', "$workspacePrincipalId")
        if ($loginIdentity.id -ne "$workspacePrincipalId" -or $loginIdentity.appId -ne "$workspaceApplicationId" -or
            [string]::IsNullOrWhiteSpace($loginIdentity.displayName)) {
            throw 'The SQL login identity does not match the Fabric workspace identity or has no Entra display name.'
        }
        $loginName = "$($loginIdentity.displayName)-$WorkspaceId"
        if ($loginName.Length -gt 128) {
            throw 'The Entra display name plus workspace GUID exceeds the SQL login limit of 128 characters. Shorten the Entra display name before rerunning.'
        }
        $loginIdentifier = '[' + $loginName.Replace(']', ']]') + ']'
        $loginLiteral = $loginName.Replace("'", "''")
        $createLoginLiteral = "CREATE LOGIN $loginIdentifier FROM EXTERNAL PROVIDER WITH OBJECT_ID = '$workspacePrincipalId';".Replace("'", "''")
        Invoke-CustomerSql -Database 'master' -Query @"
IF EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'$loginLiteral'
    AND (type <> 'E' OR SUBSTRING(sid, 1, 16) <> CONVERT(varbinary(16), CONVERT(uniqueidentifier, '$workspaceApplicationId'))))
    THROW 50000, 'Existing SQL login belongs to a different principal.', 1;
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'$loginLiteral')
    EXEC(N'$createLoginLiteral');
"@
        Invoke-CustomerSql -Query @"
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$loginLiteral'
    AND (type <> 'E' OR SUBSTRING(sid, 1, 16) <> CONVERT(varbinary(16), CONVERT(uniqueidentifier, '$workspaceApplicationId'))))
    THROW 50000, 'Existing SQL user belongs to a different principal.', 1;
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$loginLiteral')
    CREATE USER $loginIdentifier FOR LOGIN $loginIdentifier;
GRANT SELECT, ALTER ANY EXTERNAL MIRROR, VIEW DATABASE PERFORMANCE STATE, VIEW DATABASE SECURITY STATE TO $loginIdentifier;
"@
        $connections = @(Get-FabricCollection 'connections' | Where-Object displayName -EQ $connectionName)
        if ($connections.Count -gt 1) { throw "Multiple Fabric connections named $connectionName." }
        if ($connections.Count -eq 1) {
            $connection = $connections[0]
            Assert-CustomerConnection $connection
            if ($connection.credentialDetails.credentialType -ne 'WorkspaceIdentity') { throw 'Existing connection does not use workspace identity.' }
        } else {
            $connection = Invoke-Fabric 'connections' 'POST' @{
                displayName = $connectionName; connectivityType = 'ShareableCloud'; privacyLevel = 'Organizational'
                connectionDetails = @{
                    type = 'SQL'; creationMethod = 'SQL'
                    parameters = @(
                        @{ dataType = 'Text'; name = 'server'; value = "$SqlServerName.database.windows.net" }
                        @{ dataType = 'Text'; name = 'database'; value = $databaseName }
                    )
                }
                credentialDetails = @{
                    credentials = @{ credentialType = 'WorkspaceIdentity' }
                    connectionEncryption = 'Encrypted'; singleSignOnType = 'None'; skipTestConnection = $false
                }
            }
        }
        $FabricConnectionId = [guid]$connection.id
    }

    $mirrors = @(Get-FabricCollection "$workspacePath/mirroredDatabases" | Where-Object displayName -EQ $mirrorName)
    if ($mirrors.Count -gt 1) { throw "Multiple Fabric mirrors named $mirrorName." }
    if ($mirrors.Count -eq 1) {
        $mirror = $mirrors[0]
        $definition = Invoke-Fabric "$workspacePath/mirroredDatabases/$($mirror.id)/getDefinition" 'POST'
        $part = $definition.definition.parts | Where-Object path -EQ 'mirroring.json' | Select-Object -First 1
        $existing = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($part.payload)) | ConvertFrom-Json
        if ($existing.properties.source.type -ne 'AzureSqlDatabase' -or
            $existing.properties.source.typeProperties.connection -ne [string]$FabricConnectionId) {
            throw 'Existing mirrored database points to a different source. It will not be overwritten.'
        }
    } else {
        Write-Warning 'All source tables will be mirrored, including Customer password hash/salt fields. Source SQL security is not copied to Fabric.'
        $definition = @{
            properties = @{
                source = @{ type = 'AzureSqlDatabase'; typeProperties = @{ connection = [string]$FabricConnectionId } }
                target = @{ type = 'MountedRelationalDatabase'; typeProperties = @{ defaultSchema = 'dbo'; format = 'Delta' } }
            }
        } | ConvertTo-Json -Depth 10 -Compress
        $mirror = Invoke-Fabric "$workspacePath/mirroredDatabases" 'POST' @{
            displayName = $mirrorName; description = "$databaseName from $SqlServerName (environment $Environment, suffix $Suffix)"
            definition = @{ parts = @(@{
                path = 'mirroring.json'; payloadType = 'InlineBase64'
                payload = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($definition))
            }) }
        }
    }
    $mirrorPath = "$workspacePath/mirroredDatabases/$($mirror.id)"
    if (-not $identityRole -and -not $GrantSqlIdentityWorkspaceContributor -and -not $SqlIdentityItemWriteGranted) {
        throw "Mirror $($mirror.id) is ready. Grant SQL identity $sqlIdentityId Read and Write on this item in Fabric, then rerun with -SqlIdentityItemWriteGranted, or opt in to -GrantSqlIdentityWorkspaceContributor."
    }
    $status = Invoke-Fabric "$mirrorPath/getMirroringStatus" 'POST'
    for ($attempt = 0; $status.status -eq 'Initializing' -and $attempt -lt 60; $attempt++) {
        Start-Sleep -Seconds 5
        $status = Invoke-Fabric "$mirrorPath/getMirroringStatus" 'POST'
    }
    if ($status.status -in @('Initialized', 'Stopped')) {
        $null = Invoke-Fabric "$mirrorPath/startMirroring" 'POST'
    } elseif ($status.status -notin @('Running', 'Starting')) {
        throw "Mirror cannot be started in state '$($status.status)'."
    }
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        $status = Invoke-Fabric "$mirrorPath/getMirroringStatus" 'POST'
        if ($status.status -eq 'Running') { break }
        if ($status.status -notin @('Starting', 'Initialized')) { throw "Unexpected mirroring status: $($status.status)" }
        Start-Sleep -Seconds 5
    }
    if ($status.status -ne 'Running') { throw 'Timed out waiting for mirroring to run. Check Monitor replication in Fabric.' }
    $mirrorDetails = Invoke-Fabric $mirrorPath
    [pscustomobject]@{
        SubscriptionId = $account.id; TenantId = $account.tenantId
        ResourceGroup = $resourceGroupName; SqlServer = "$SqlServerName.database.windows.net"; Database = $databaseName
        WorkspaceId = $WorkspaceId; MirroredDatabaseId = $mirror.id; MirroringStatus = $status.status
        OneLakeTablesPath = $mirrorDetails.properties.oneLakeTablesPath
        SqlAnalyticsEndpoint = $mirrorDetails.properties.sqlEndpointProperties.connectionString
    }
} finally {
    if ($temporaryRuleName) {
        try {
            $null = Invoke-AzureCli @('sql', 'server', 'firewall-rule', 'delete', '--resource-group', $resourceGroupName,
                '--server', $SqlServerName, '--name', $temporaryRuleName)
        } catch { Write-Warning "Could not remove temporary firewall rule '$temporaryRuleName': $_" }
    }
}
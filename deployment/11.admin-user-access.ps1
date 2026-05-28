#Requires -Version 5.1
<#
.SYNOPSIS
	Creates/ensures an Entra ID security group and adds internal tenant users to it.

.DESCRIPTION
	- Prompts for a group name (default: eia-portal-users)
	- Creates the group if it does not exist
	- Supports a simple GlobalAdmin guidance mode for manual PIM activation
	- Verifies operator has required Entra role to create users
	- Prompts for user names (loop)
	- Derives user principal name as <username>@<operator-domain>
	- Checks if user exists before any create operation
	- If user does not exist, prompts for password and creates user in tenant
	- Adds users to access group (MFA enforced via Conditional Access policy)
	- Adds user to group

	This is intended to support web-portal access group setup without changing
	mailbox polling behavior.

.USAGE
	.\11.admin-user-access.ps1 -GlobalAdmin
	.\11.admin-user-access.ps1 -Suffix 1
#>

param(
	[Parameter(HelpMessage="Suffix used during infrastructure deployment (e.g. 1)")]
	[string]$Suffix,

	[switch]$GlobalAdmin
)

$ErrorActionPreference = "Stop"

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

function Ensure-AzLogin {
	$acctState = Invoke-AzCliSilent -Arguments @('account','show','--query','state','-o','tsv')
	if ($acctState.ExitCode -ne 0 -or $acctState.Output -ne 'Enabled') {
		Write-Host "[ERROR] Not logged in to Azure CLI. Run 'az login' first." -ForegroundColor Red
		exit 1
	}
}

function Get-CurrentDirectoryRoleNames {
	$rolesResp = Invoke-AzCliSilent -Arguments @(
		'rest',
		'--method','GET',
		'--uri','https://graph.microsoft.com/v1.0/me/memberOf/microsoft.graph.directoryRole?$select=displayName',
		'-o','json'
	)

	if ($rolesResp.ExitCode -ne 0 -or -not $rolesResp.Output -or $rolesResp.Output -eq 'null') {
		return $null
	}

	try {
		$parsed = $rolesResp.Output | ConvertFrom-Json
		if ($parsed -and $parsed.value) {
			return @($parsed.value | ForEach-Object { $_.displayName })
		}
	} catch {
		return $null
	}

	return @()
}

function Ensure-CanCreateUsers {
	param([string]$Identity)

	$roleNames = Get-CurrentDirectoryRoleNames
	if ($null -eq $roleNames) {
		Write-Host "[WARNING] Could not verify Entra directory roles for '$Identity'. Continuing, but user creation may fail if privileges are insufficient." -ForegroundColor Yellow
		return
	}

	$acceptedRoles = @('Global Administrator', 'User Administrator', 'Privileged Role Administrator')
	$hasCreatePrivilege = $false
	foreach ($role in $roleNames) {
		if ($acceptedRoles -contains $role) {
			$hasCreatePrivilege = $true
			break
		}
	}

	if (-not $hasCreatePrivilege) {
		$currentRoles = if ($roleNames.Count -gt 0) { $roleNames -join ', ' } else { '(none)' }
		Write-Host "[ERROR] Account '$Identity' does not have permission to create Entra users." -ForegroundColor Red
		Write-Host "[ERROR] Current roles: $currentRoles" -ForegroundColor Red
		Write-Host "[ERROR] Required role: User Administrator (or Global Administrator / Privileged Role Administrator)." -ForegroundColor Red
		Write-Host "[INFO] If your tenant uses PIM, activate one of these roles in Entra portal, then run 'az logout' and 'az login --tenant <tenantId>' and retry." -ForegroundColor Cyan
		exit 1
	}

	Write-Host "[OK] Role pre-check passed for user creation." -ForegroundColor Green
}

function Warn-IfCannotManageDirectoryRoles {
	param([string]$Identity)

	$roleNames = Get-CurrentDirectoryRoleNames
	if ($null -eq $roleNames) {
		Write-Host "[WARNING] Could not verify Entra directory roles for '$Identity'." -ForegroundColor Yellow
		Write-Host "[INFO] Directory custom role assignment may fail without Privileged Role Administrator or Global Administrator." -ForegroundColor Cyan
		return
	}

	$acceptedRoles = @('Global Administrator', 'Privileged Role Administrator')
	$hasManagePrivilege = ($roleNames | Where-Object { $acceptedRoles -contains $_ }).Count -gt 0
	if (-not $hasManagePrivilege) {
		$currentRoles = if ($roleNames.Count -gt 0) { $roleNames -join ', ' } else { '(none)' }
		Write-Host "[WARNING] Account '$Identity' may not manage directory custom roles." -ForegroundColor Yellow
		Write-Host "[INFO] Current roles: $currentRoles" -ForegroundColor Cyan
		Write-Host "[INFO] Required role for directory role assignment: Privileged Role Administrator or Global Administrator." -ForegroundColor Cyan
	}
}
function Load-EnvConfig {
	$configFile = Join-Path $PSScriptRoot "env.config"
	if (-not (Test-Path $configFile)) {
		return
	}

	Get-Content $configFile | ForEach-Object {
		$line = $_.Trim()
		if ($line -and -not $line.StartsWith('#') -and $line -match '^([^=]+)=(.*)$') {
			$name  = $Matches[1].Trim()
			$value = $Matches[2].Trim().Trim('"')
			Set-Item -Path "env:$name" -Value $value
			[System.Environment]::SetEnvironmentVariable($name, $value, 'Process')
		}
	}
}

function Get-FqdnFromIdentity {
	param([string]$Identity)

	if (-not $Identity) {
		return $null
	}

	$trimmed = $Identity.Trim()
	if ($trimmed -match '@([^@]+)$') {
		return $Matches[1].ToLowerInvariant()
	}

	return $null
}

function To-MailNickname {
	param([string]$GroupName)
	$nick = ($GroupName.ToLower() -replace '[^a-z0-9-]', '-')
	$nick = ($nick -replace '-{2,}', '-')
	$nick = $nick.Trim('-')
	if (-not $nick) { $nick = 'group' }
	return $nick
}

function Get-OrCreateGroup {
	param([string]$GroupName)

	$found = Invoke-AzCliSilent -Arguments @('ad','group','list','--display-name',$GroupName,'--query','[0].{id:id,displayName:displayName}','-o','json')
	if ($found.ExitCode -eq 0 -and $found.Output -and $found.Output -ne 'null') {
		$group = $found.Output | ConvertFrom-Json
		if ($group -and $group.id) {
			Write-Host "[OK] Group already exists: $($group.displayName) ($($group.id))" -ForegroundColor Green
			return $group
		}
	}

	$mailNickname = To-MailNickname -GroupName $GroupName
	Write-Host "[INFO] Creating group '$GroupName'..." -ForegroundColor Cyan
	$created = Invoke-AzCliSilent -Arguments @(
		'ad','group','create',
		'--display-name',$GroupName,
		'--mail-nickname',$mailNickname,
		'--query','{id:id,displayName:displayName}',
		'-o','json'
	)
	if ($created.ExitCode -ne 0) {
		Write-Host "[ERROR] Failed to create group '$GroupName'." -ForegroundColor Red
		if ($created.Error) { Write-Host "  $($created.Error)" -ForegroundColor Red }
		exit 1
	}

	$group = $created.Output | ConvertFrom-Json
	Write-Host "[SUCCESS] Created group: $($group.displayName) ($($group.id))" -ForegroundColor Green
	return $group
}

function Resolve-UserByUpn {
	param([string]$UserPrincipalName)

	$user = Invoke-AzCliSilent -Arguments @('ad','user','show','--id',$UserPrincipalName,'--query','{id:id,mail:mail,userPrincipalName:userPrincipalName,userType:userType}','-o','json')
	if ($user.ExitCode -eq 0 -and $user.Output -and $user.Output -ne 'null') {
		return ($user.Output | ConvertFrom-Json)
	}
	return $null
}

function Create-User {
	param(
		[string]$Username,
		[string]$Email,
		[string]$Password
	)

	$created = Invoke-AzCliSilent -Arguments @(
		'ad','user','create',
		'--display-name',$Username,
		'--user-principal-name',$Email,
		'--mail-nickname',$Username,
		'--password',$Password,
		'--force-change-password-next-sign-in','true',
		'--query','{id:id,mail:mail,userPrincipalName:userPrincipalName,userType:userType}',
		'-o','json'
	)

	if ($created.ExitCode -ne 0 -or -not $created.Output -or $created.Output -eq 'null') {
		Write-Host "[ERROR] Failed to create user '$Email'." -ForegroundColor Red
		if ($created.Error) { Write-Host "  $($created.Error)" -ForegroundColor Red }
		return $null
	}

	Write-Host "[SUCCESS] Created user '$Email'." -ForegroundColor Green
	return ($created.Output | ConvertFrom-Json)
}

function New-TemporaryPassword {
	param([int]$Length = 16)

	$upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
	$lower = 'abcdefghijkmnpqrstuvwxyz'
	$digit = '23456789'
	$special = '!@#$%*-_+=' 
	$all = ($upper + $lower + $digit + $special).ToCharArray()

	# Guarantee complexity by seeding one char from each required class.
	$chars = @(
		($upper.ToCharArray() | Get-Random)
		($lower.ToCharArray() | Get-Random)
		($digit.ToCharArray() | Get-Random)
		($special.ToCharArray() | Get-Random)
	)

	for ($i = $chars.Count; $i -lt $Length; $i++) {
		$chars += ($all | Get-Random)
	}

	$shuffled = $chars | Get-Random -Count $chars.Count
	return -join $shuffled
}

function Show-NewUserInstructions {
	param(
		[string]$Email,
		[string]$TemporaryPassword,
		[string]$LoginUrl
	)

	Write-Host "" 
	Write-Host "------------------------------------------------------------" -ForegroundColor Cyan
	Write-Host "  New User Instructions" -ForegroundColor Cyan
	Write-Host "------------------------------------------------------------" -ForegroundColor Cyan
	Write-Host "1. Username: $Email" -ForegroundColor White
	Write-Host "2. Temporary password: $TemporaryPassword" -ForegroundColor White
	Write-Host "3. Login URL: $LoginUrl" -ForegroundColor White
	Write-Host "4. At first login, change the temporary password when prompted." -ForegroundColor White
	Write-Host "5. After password change, follow the Microsoft prompts to set up Microsoft Authenticator." -ForegroundColor White
	Write-Host "6. Install Microsoft Authenticator on the phone, scan the QR code, and approve the test prompt." -ForegroundColor White
	Write-Host "7. After setup completes, continue into the web app." -ForegroundColor White
	Write-Host "------------------------------------------------------------" -ForegroundColor Cyan
	Write-Host ""
}

function Add-UserToGroup {
	param(
		[string]$GroupId,
		[string]$UserId,
		[string]$Email
	)

	$exists = Invoke-AzCliSilent -Arguments @('ad','group','member','list','--group',$GroupId,'--query',"[?id=='$UserId'] | length(@)",'-o','tsv')
	if ($exists.ExitCode -eq 0 -and $exists.Output -eq '1') {
		Write-Host "[OK] '$Email' is already a member of the group." -ForegroundColor Gray
		return 'already-member'
	}

	$add = Invoke-AzCliSilent -Arguments @('ad','group','member','add','--group',$GroupId,'--member-id',$UserId)
	if ($add.ExitCode -ne 0) {
		Write-Host "[ERROR] Failed to add '$Email' to group." -ForegroundColor Red
		if ($add.Error) { Write-Host "  $($add.Error)" -ForegroundColor Red }
		return 'failed'
	}

	Write-Host "[SUCCESS] Added '$Email' to group." -ForegroundColor Green
	return 'added'
}

function Get-CustomDirectoryRoleDefinitionId {
	param([string]$RoleName)

	$escapedRoleName = $RoleName.Replace("'", "''")
	$filter = [uri]::EscapeDataString("displayName eq '$escapedRoleName'")
	$list = Invoke-AzCliSilent -Arguments @(
		'rest','--method','GET',
		'--uri',"https://graph.microsoft.com/v1.0/roleManagement/directory/roleDefinitions?`$filter=$filter",
		'-o','json'
	)

	if ($list.ExitCode -ne 0 -or -not $list.Output -or $list.Output -eq 'null') {
		return $null
	}

	try {
		$parsed = $list.Output | ConvertFrom-Json
		if ($parsed -and $parsed.value -and $parsed.value.Count -gt 0) {
			return $parsed.value[0].id
		}
	} catch {
		return $null
	}

	return $null
}

function Ensure-DirectoryRoleAssignment {
	param(
		[string]$RoleDefinitionId,
		[string]$PrincipalId,
		[string]$Email
	)

	$filter = [uri]::EscapeDataString("principalId eq '$PrincipalId' and roleDefinitionId eq '$RoleDefinitionId' and directoryScopeId eq '/'")
	$existing = Invoke-AzCliSilent -Arguments @(
		'rest','--method','GET',
		'--uri',"https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments?`$filter=$filter",
		'-o','json'
	)

	if ($existing.ExitCode -eq 0 -and $existing.Output -and $existing.Output -ne 'null') {
		try {
			$parsed = $existing.Output | ConvertFrom-Json
			if ($parsed.value -and $parsed.value.Count -gt 0) {
				Write-Host "[OK] Directory role already assigned to '$Email'." -ForegroundColor Gray
				return 'already-assigned'
			}
		} catch {
		}
	}

	$body = @{
		principalId = $PrincipalId
		roleDefinitionId = $RoleDefinitionId
		directoryScopeId = '/'
	} | ConvertTo-Json -Compress

	$tmpBodyPath = Join-Path $env:TEMP ("eia-role-assignment-" + [guid]::NewGuid().ToString('N') + ".json")
	$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
	[System.IO.File]::WriteAllText($tmpBodyPath, $body, $utf8NoBom)

	try {
		$assign = Invoke-AzCliSilent -Arguments @(
			'rest','--method','POST',
			'--uri','https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments',
			'--headers','Content-Type=application/json',
			'--body',"@$tmpBodyPath",
			'-o','json'
		)
	} finally {
		Remove-Item $tmpBodyPath -ErrorAction SilentlyContinue
	}

	if ($assign.ExitCode -ne 0) {
		Write-Host "[WARNING] Failed to assign directory role to '$Email'." -ForegroundColor Yellow
		if ($assign.Error) { Write-Host "  $($assign.Error)" -ForegroundColor Yellow }
		if ($assign.Error -match 'Authorization_RequestDenied|Insufficient privileges') {
			Write-Host "  [INFO] Assigning directory roles requires Entra role: Privileged Role Administrator or Global Administrator." -ForegroundColor Cyan
			Write-Host "  [INFO] Re-login with an admin account (or activate via PIM) and retry role assignment." -ForegroundColor Cyan
		}
		return 'failed'
	}

	Write-Host "[SUCCESS] Assigned directory role to '$Email'." -ForegroundColor Green
	return 'assigned'
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Entra Portal User Access Setup" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

if ($GlobalAdmin -and $Suffix) {
	Write-Host "[ERROR] Use either -GlobalAdmin OR -Suffix <n>, not both." -ForegroundColor Red
	Write-Host "[INFO] Examples:" -ForegroundColor Cyan
	Write-Host "  .\11.admin-user-access.ps1 -GlobalAdmin" -ForegroundColor White
	Write-Host "  .\11.admin-user-access.ps1 -Suffix 1" -ForegroundColor White
	exit 1
}

if (-not $GlobalAdmin -and (-not $Suffix -or -not $Suffix.Trim())) {
	Write-Host "[ERROR] Missing required argument." -ForegroundColor Red
	Write-Host "[INFO] Use one of:" -ForegroundColor Cyan
	Write-Host "  .\11.admin-user-access.ps1 -GlobalAdmin" -ForegroundColor White
	Write-Host "  .\11.admin-user-access.ps1 -Suffix 1" -ForegroundColor White
	exit 1
}

Load-EnvConfig

if ($Suffix) {
	$Suffix = $Suffix.Trim()
}

Ensure-AzLogin

$tenantId = (Invoke-AzCliSilent -Arguments @('account','show','--query','tenantId','-o','tsv')).Output
$signedInUser = (Invoke-AzCliSilent -Arguments @('ad','signed-in-user','show','--query','userPrincipalName','-o','tsv')).Output
$accountUser = (Invoke-AzCliSilent -Arguments @('account','show','--query','user.name','-o','tsv')).Output
$identityForChecks = if ($signedInUser) { $signedInUser } else { $accountUser }

if ($GlobalAdmin) {
	Write-Host "[INFO] Manual step required: activate Global Administrator in Entra portal (PIM) for 4 hours." -ForegroundColor Cyan
	Write-Host "[INFO] After activation, wait about 3-5 minutes for propagation, then run:" -ForegroundColor Cyan
	Write-Host "  az logout" -ForegroundColor White
	Write-Host "  az login --tenant $tenantId" -ForegroundColor White
	Write-Host "  .\11.admin-user-access.ps1 -Suffix 1" -ForegroundColor White
	exit 0
}

Ensure-CanCreateUsers -Identity $identityForChecks
Warn-IfCannotManageDirectoryRoles -Identity $identityForChecks

Write-Host "[INFO] Tenant: $tenantId" -ForegroundColor Cyan
if ($signedInUser) {
	Write-Host "[INFO] Signed in as: $signedInUser" -ForegroundColor Cyan
}
Write-Host "[INFO] Deployment suffix: $Suffix" -ForegroundColor Cyan

$ProjectName = if ($env:PROJECT_NAME) { $env:PROJECT_NAME } else { 'eia' }
$Environment = if ($env:ENVIRONMENT) { $env:ENVIRONMENT } else { 'dev' }
$webAppName = if ($env:WEB_APP_NAME) { $env:WEB_APP_NAME } else { "app-$ProjectName-$Environment-$Suffix" }
$loginUrl = "https://$webAppName.azurewebsites.net"
Write-Host "[INFO] Web app login URL: $loginUrl" -ForegroundColor Cyan

$operatorIdentity = if ($signedInUser) { $signedInUser } else { $accountUser }
$operatorFqdn = Get-FqdnFromIdentity -Identity $operatorIdentity
if (-not $operatorFqdn -and $env:USERDNSDOMAIN) {
	$operatorFqdn = $env:USERDNSDOMAIN.Trim().ToLowerInvariant()
}
if (-not $operatorFqdn) {
	Write-Host "[ERROR] Could not determine operator domain from signed-in user. Ensure Azure CLI is logged in with a user account (UPN with domain)." -ForegroundColor Red
	exit 1
}
Write-Host "[INFO] Derived operator domain for user addresses: $operatorFqdn" -ForegroundColor Cyan

$defaultGroupName = 'eia-portal-users'
$groupNameInput = Read-Host "Enter Entra security group name [default: $defaultGroupName]"
$groupName = if ($groupNameInput) { $groupNameInput.Trim() } else { $defaultGroupName }
if (-not $groupName) { $groupName = $defaultGroupName }

$group = Get-OrCreateGroup -GroupName $groupName

Write-Host ""
Write-Host "Enter usernames to add (one per prompt, without domain)." -ForegroundColor White
Write-Host "User principal name format: <username>@$operatorFqdn" -ForegroundColor White
Write-Host "After each user, choose whether to continue with more users." -ForegroundColor White
Write-Host ""

$processed = 0
$added = 0
$alreadyMember = 0
$created = 0
$failed = 0
$roleAssigned = 0
$roleAlreadyAssigned = 0
$roleFailed = 0

$defaultProfileEditorRoleName = 'EIAUserProfileEditor'
$profileEditorRoleInput = Read-Host "Enter Entra custom role name for user profile updates [default: $defaultProfileEditorRoleName]"
$profileEditorRoleName = if ($profileEditorRoleInput -and $profileEditorRoleInput.Trim()) { $profileEditorRoleInput.Trim() } else { $defaultProfileEditorRoleName }
$profileEditorRoleId = Get-CustomDirectoryRoleDefinitionId -RoleName $profileEditorRoleName
if ($profileEditorRoleId) {
	Write-Host "[INFO] Directory role '$profileEditorRoleName' will be assigned to onboarded users." -ForegroundColor Cyan
} else {
	Write-Host "[WARNING] Directory role '$profileEditorRoleName' was not found. Run .\4.operation-dev.ps1 and select step 4 first." -ForegroundColor Yellow
}

while ($true) {
	$username = Read-Host "New user username"
	if (-not $username -or -not $username.Trim()) {
		Write-Host "[INFO] No username entered. Ending user onboarding loop." -ForegroundColor Cyan
		break
	}
	$username = $username.Trim().ToLowerInvariant()
	if ($username.Contains('@')) {
		$username = $username.Split('@')[0]
		Write-Host "[WARNING] Domain part was ignored. Using username '$username'." -ForegroundColor Yellow
	}

	$email = "$username@$operatorFqdn"
	$processed++

	Write-Host "[INFO] Checking if '$email' exists..." -ForegroundColor Cyan

	$user = Resolve-UserByUpn -UserPrincipalName $email
	if (-not $user) {
		$autoInput = Read-Host "Auto-generate temporary password for '$email'? [Y/n]"
		$useAuto = (-not $autoInput -or -not $autoInput.Trim() -or @('y','yes') -contains $autoInput.Trim().ToLowerInvariant())

		if ($useAuto) {
			$password = New-TemporaryPassword
			Write-Host "[INFO] Temporary password for '$email': $password" -ForegroundColor Yellow
		} else {
			$password = Read-Host "Enter temporary password for '$email' (visible)"
			if (-not $password -or -not $password.Trim()) {
				Write-Host "[ERROR] Password is required to create '$email'." -ForegroundColor Red
				$failed++
				continue
			}
			$password = $password.Trim()
		}

		$user = Create-User -Username $username -Email $email -Password $password
		$temporaryPasswordToShare = $password
		$password = $null

		if (-not $user -or -not $user.id) {
			$failed++
			continue
		}

		$created++
		Show-NewUserInstructions -Email $email -TemporaryPassword $temporaryPasswordToShare -LoginUrl $loginUrl
		$temporaryPasswordToShare = $null
	}

	if (-not $user -or -not $user.id) {
		Write-Host "[ERROR] Could not resolve user object for '$email'." -ForegroundColor Red
		$failed++
		continue
	}

	$result = Add-UserToGroup -GroupId $group.id -UserId $user.id -Email $email
	switch ($result) {
		'added' { $added++ }
		'already-member' { $alreadyMember++ }
		default { $failed++ }
	}

	if ($profileEditorRoleId) {
		$roleResult = Ensure-DirectoryRoleAssignment -RoleDefinitionId $profileEditorRoleId -PrincipalId $user.id -Email $email
		switch ($roleResult) {
			'assigned' { $roleAssigned++ }
			'already-assigned' { $roleAlreadyAssigned++ }
			default { $roleFailed++ }
		}
	}

	$moreUsersInput = Read-Host "Create more users? [Y/n]"
	if ($moreUsersInput -and $moreUsersInput.Trim()) {
		$normalized = $moreUsersInput.Trim().ToLowerInvariant()
		if (@('n', 'no', 'q', 'quit') -contains $normalized) {
			Write-Host "[INFO] Ending user onboarding loop by user choice." -ForegroundColor Cyan
			break
		}
		elseif (-not (@('y', 'yes') -contains $normalized)) {
			Write-Host "[WARNING] Unrecognized response '$moreUsersInput'. Continuing with next user." -ForegroundColor Yellow
		}
	}
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Summary" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "Group             : $($group.displayName)" -ForegroundColor White
Write-Host "Group Id          : $($group.id)" -ForegroundColor White
Write-Host "Processed users   : $processed" -ForegroundColor White
Write-Host "Added             : $added" -ForegroundColor Green
Write-Host "Already members   : $alreadyMember" -ForegroundColor Gray
Write-Host "Created           : $created" -ForegroundColor Yellow
Write-Host "Role assigned     : $roleAssigned" -ForegroundColor Green
Write-Host "Role already set  : $roleAlreadyAssigned" -ForegroundColor Gray
Write-Host "Role failed       : $roleFailed" -ForegroundColor Yellow
Write-Host "Failed            : $failed" -ForegroundColor Red
Write-Host ""
Write-Host "[INFO] Next step: assign this group to the web app enterprise application and enforce MFA via Conditional Access." -ForegroundColor Cyan

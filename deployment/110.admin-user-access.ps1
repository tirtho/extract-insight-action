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
	- Stores each user's job title in a Key Vault JSON secret keyed by email address

	This is intended to support web-portal access group setup without changing
	mailbox polling behavior.

.USAGE
	.\110.admin-user-access.ps1 -GlobalAdmin
	.\110.admin-user-access.ps1 -Suffix 1
	.\110.admin-user-access.ps1 -Environment dev -Suffix 1
#>

param(
	[Parameter(HelpMessage="Environment (default: dev, example: dev)")]
	[string]$Environment,

	[Parameter(HelpMessage="Suffix used during infrastructure deployment (e.g. 1)")]
	[string]$Suffix,

	[switch]$GlobalAdmin
)

$ErrorActionPreference = "Stop"

$LocationInput = Read-Host "Enter location [default: centralus, example: centralus]"
$Location = if ([string]::IsNullOrWhiteSpace($LocationInput)) { "centralus" } else { $LocationInput.Trim().ToLowerInvariant() }

$ProjectName = 'eia'

if (-not $GlobalAdmin) {
	if ([string]::IsNullOrWhiteSpace($Environment)) {
		$EnvironmentInput = Read-Host "Enter environment [default: dev, example: dev]"
		$Environment = if ([string]::IsNullOrWhiteSpace($EnvironmentInput)) { "dev" } else { $EnvironmentInput.Trim().ToLowerInvariant() }
	} else {
		$Environment = $Environment.Trim().ToLowerInvariant()
	}
} elseif ([string]::IsNullOrWhiteSpace($Environment)) {
	$Environment = 'dev'
} else {
	$Environment = $Environment.Trim().ToLowerInvariant()
}

if (-not $GlobalAdmin) {
	if ([string]::IsNullOrWhiteSpace($Suffix)) {
		$SuffixInput = Read-Host "Enter suffix [default: 1, example: 1]"
		$Suffix = if ([string]::IsNullOrWhiteSpace($SuffixInput)) { "1" } else { $SuffixInput.Trim() }
	} else {
		$Suffix = $Suffix.Trim()
	}
}

if (-not $GlobalAdmin) {
	Write-Host "[INFO] Deployment key: $ProjectName-$Environment-$Suffix (location: $Location)" -ForegroundColor Cyan
}

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

function Confirm-AzLogin {
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

function Confirm-CanCreateUsers {
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

function Resolve-KeyVaultUrl {
	param([string]$KeyVaultName)

	$explicit = $env:AZURE_KEY_VAULT_URL
	if ($explicit -and -not [string]::IsNullOrWhiteSpace($explicit)) {
		return $explicit.TrimEnd('/')
	}

	if ($KeyVaultName) {
		return "https://$KeyVaultName.vault.azure.net"
	}

	return $null
}

function ConvertTo-PlainText {
	param([SecureString]$SecureValue)

	if ($null -eq $SecureValue) {
		return $null
	}

	$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
	try {
		return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
	} finally {
		[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
	}
}

function Get-UserProfileSecretName {
	$configured = $env:USER_PROFILE_SECRET_NAME
	if ($configured -and -not [string]::IsNullOrWhiteSpace($configured)) {
		return $configured.Trim()
	}

	return 'UserProfiles'
}

function ConvertTo-ProfileEmail {
	param([string]$Email)

	if (-not $Email) {
		return $null
	}

	$normalized = $Email.Trim()
	if ([string]::IsNullOrWhiteSpace($normalized)) {
		return $null
	}

	return $normalized.ToLowerInvariant()
}

function Read-UserProfileJobTitles {
	param(
		[string]$KeyVaultName,
		[string]$SecretName
	)

	$profiles = @{}
	$result = Invoke-AzCliSilent -Arguments @('keyvault','secret','show','--vault-name',$KeyVaultName,'--name',$SecretName,'--query','value','-o','tsv')
	if ($result.ExitCode -ne 0 -or -not $result.Output -or [string]::IsNullOrWhiteSpace($result.Output)) {
		return $profiles
	}

	try {
		$root = $result.Output | ConvertFrom-Json
	} catch {
		Write-Host "[WARNING] Key Vault secret '$SecretName' does not contain valid JSON. It will be replaced when you save a title." -ForegroundColor Yellow
		return $profiles
	}

	if (-not $root) {
		return $profiles
	}

	foreach ($property in $root.PSObject.Properties) {
		$emailKey = ConvertTo-ProfileEmail -Email $property.Name
		if (-not $emailKey) {
			continue
		}

		$titleValue = $null
		if ($property.Value -is [string]) {
			$titleValue = $property.Value.Trim()
		} elseif ($property.Value -and $property.Value.PSObject.Properties['JobTitle']) {
			$titleValue = [string]$property.Value.JobTitle
			if ($titleValue) {
				$titleValue = $titleValue.Trim()
			}
		}

		if ($titleValue -and -not [string]::IsNullOrWhiteSpace($titleValue)) {
			$profiles[$emailKey] = $titleValue
		}
	}

	return $profiles
}

function Write-UserProfileJobTitles {
	param(
		[string]$KeyVaultName,
		[string]$SecretName,
		[hashtable]$Profiles
	)

	$payload = [ordered]@{}
	foreach ($entry in ($Profiles.GetEnumerator() | Sort-Object Key)) {
		$payload[$entry.Key] = [ordered]@{ JobTitle = $entry.Value }
	}

	$json = $payload | ConvertTo-Json -Compress -Depth 6
	$result = Invoke-AzCliSilent -Arguments @('keyvault','secret','set','--vault-name',$KeyVaultName,'--name',$SecretName,'--value',$json,'--output','none')
	if ($result.ExitCode -ne 0) {
		throw "Failed to store user profile data in Key Vault '$KeyVaultName'."
	}
}

function Get-UserProfileJobTitle {
	param(
		[string]$KeyVaultName,
		[string]$SecretName,
		[string]$Email
	)

	$emailKey = ConvertTo-ProfileEmail -Email $Email
	if (-not $emailKey) {
		return $null
	}

	$profiles = Read-UserProfileJobTitles -KeyVaultName $KeyVaultName -SecretName $SecretName
	if ($profiles.ContainsKey($emailKey)) {
		return $profiles[$emailKey]
	}

	return $null
}

function Set-UserProfileJobTitle {
	param(
		[string]$KeyVaultName,
		[string]$SecretName,
		[string]$Email,
		[string]$JobTitle
	)

	$emailKey = ConvertTo-ProfileEmail -Email $Email
	if (-not $emailKey) {
		throw "An email address is required to store a user profile title."
	}

	$profiles = Read-UserProfileJobTitles -KeyVaultName $KeyVaultName -SecretName $SecretName
	$normalizedTitle = if ($JobTitle) { $JobTitle.Trim() } else { '' }

	if ([string]::IsNullOrWhiteSpace($normalizedTitle)) {
		if ($profiles.ContainsKey($emailKey)) {
			$profiles.Remove($emailKey) | Out-Null
		}
	} else {
		$profiles[$emailKey] = $normalizedTitle
	}

	Write-UserProfileJobTitles -KeyVaultName $KeyVaultName -SecretName $SecretName -Profiles $profiles
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

function ConvertTo-MailNickname {
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

	$mailNickname = ConvertTo-MailNickname -GroupName $GroupName
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

function New-EntraUser {
	param(
		[string]$Username,
		[string]$Email,
		[SecureString]$Password
	)

	$passwordPlain = ConvertTo-PlainText -SecureValue $Password
	if ([string]::IsNullOrWhiteSpace($passwordPlain)) {
		Write-Host "[ERROR] Password is required to create '$Email'." -ForegroundColor Red
		return $null
	}

	$created = Invoke-AzCliSilent -Arguments @(
		'ad','user','create',
		'--display-name',$Username,
		'--user-principal-name',$Email,
		'--mail-nickname',$Username,
		'--password',$passwordPlain,
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
	$passwordPlain = $null
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
		[SecureString]$TemporaryPassword,
		[string]$LoginUrl
	)

	$temporaryPasswordPlain = ConvertTo-PlainText -SecureValue $TemporaryPassword

	Write-Host "" 
	Write-Host "------------------------------------------------------------" -ForegroundColor Cyan
	Write-Host "  New User Instructions" -ForegroundColor Cyan
	Write-Host "------------------------------------------------------------" -ForegroundColor Cyan
	Write-Host "1. Username: $Email" -ForegroundColor White
	Write-Host "2. Temporary password: $temporaryPasswordPlain" -ForegroundColor White
	Write-Host "3. Login URL: $LoginUrl" -ForegroundColor White
	Write-Host "4. At first login, change the temporary password when prompted." -ForegroundColor White
	Write-Host "5. After password change, follow the Microsoft prompts to set up Microsoft Authenticator." -ForegroundColor White
	Write-Host "6. Install Microsoft Authenticator on the phone, scan the QR code, and approve the test prompt." -ForegroundColor White
	Write-Host "7. After setup completes, continue into the web app." -ForegroundColor White
	Write-Host "------------------------------------------------------------" -ForegroundColor Cyan
	Write-Host ""
	$temporaryPasswordPlain = $null
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



Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Entra Portal User Access Setup" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

if ($GlobalAdmin -and $Suffix) {
	Write-Host "[ERROR] Use either -GlobalAdmin OR -Suffix <n>, not both." -ForegroundColor Red
	Write-Host "[INFO] Examples:" -ForegroundColor Cyan
	Write-Host "  .\110.admin-user-access.ps1 -GlobalAdmin" -ForegroundColor White
	Write-Host "  .\110.admin-user-access.ps1 -Suffix 1" -ForegroundColor White
	exit 1
}

if (-not $GlobalAdmin -and (-not $Suffix -or -not $Suffix.Trim())) {
	Write-Host "[ERROR] Missing required argument." -ForegroundColor Red
	Write-Host "[INFO] Use one of:" -ForegroundColor Cyan
	Write-Host "  .\110.admin-user-access.ps1 -GlobalAdmin" -ForegroundColor White
	Write-Host "  .\110.admin-user-access.ps1 -Suffix 1" -ForegroundColor White
	exit 1
}

Confirm-AzLogin

$tenantId = (Invoke-AzCliSilent -Arguments @('account','show','--query','tenantId','-o','tsv')).Output
$signedInUser = (Invoke-AzCliSilent -Arguments @('ad','signed-in-user','show','--query','userPrincipalName','-o','tsv')).Output
$accountUser = (Invoke-AzCliSilent -Arguments @('account','show','--query','user.name','-o','tsv')).Output
$identityForChecks = if ($signedInUser) { $signedInUser } else { $accountUser }

if ($GlobalAdmin) {
	Write-Host "[INFO] Manual step required: activate Global Administrator in Entra portal (PIM) for 4 hours." -ForegroundColor Cyan
	Write-Host "[INFO] After activation, wait about 3-5 minutes for propagation, then run:" -ForegroundColor Cyan
	Write-Host "  az logout" -ForegroundColor White
	Write-Host "  az login --tenant $tenantId" -ForegroundColor White
	Write-Host "  .\110.admin-user-access.ps1 -Suffix 1" -ForegroundColor White
	exit 0
}

Confirm-CanCreateUsers -Identity $identityForChecks

Write-Host "[INFO] Tenant: $tenantId" -ForegroundColor Cyan
if ($signedInUser) {
	Write-Host "[INFO] Signed in as: $signedInUser" -ForegroundColor Cyan
}
Write-Host "[INFO] Deployment suffix: $Suffix" -ForegroundColor Cyan

$KeyVaultName = "kv-$ProjectName-$Environment-$Suffix"
$KeyVaultUrl = Resolve-KeyVaultUrl -KeyVaultName $KeyVaultName
$UserProfileSecretName = Get-UserProfileSecretName
$KeyVaultUrl = $KeyVaultUrl.TrimEnd('/')
$webAppName = "app-$ProjectName-$Environment-$Suffix"
$loginUrl = "https://$webAppName.azurewebsites.net"
Write-Host "[INFO] Web app login URL: $loginUrl" -ForegroundColor Cyan
Write-Host "[INFO] Key Vault URL: $KeyVaultUrl" -ForegroundColor Cyan
Write-Host "[INFO] User job titles will be stored in Key Vault '$KeyVaultName' secret '$UserProfileSecretName'." -ForegroundColor Cyan

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
$profileUpdated = 0

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
			$passwordPlain = New-TemporaryPassword
			Write-Host "[INFO] Temporary password for '$email': $passwordPlain" -ForegroundColor Yellow
		} else {
			$passwordPlain = Read-Host "Enter temporary password for '$email' (visible)"
			if (-not $passwordPlain -or -not $passwordPlain.Trim()) {
				Write-Host "[ERROR] Password is required to create '$email'." -ForegroundColor Red
				$failed++
				continue
			}
			$passwordPlain = $passwordPlain.Trim()
		}

		$passwordSecure = ConvertTo-SecureString -String $passwordPlain -AsPlainText -Force

		$user = New-EntraUser -Username $username -Email $email -Password $passwordSecure
		$temporaryPasswordToShare = $passwordSecure
		$passwordSecure = $null
		$passwordPlain = $null

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

	$currentJobTitle = Get-UserProfileJobTitle -KeyVaultName $KeyVaultName -SecretName $UserProfileSecretName -Email $email
	if ($currentJobTitle) {
		$jobTitlePrompt = "Enter job title for '$email' [default: $currentJobTitle]"
	} else {
		$jobTitlePrompt = "Enter job title for '$email' [required]"
	}
	$jobTitleInput = Read-Host $jobTitlePrompt
	if ([string]::IsNullOrWhiteSpace($jobTitleInput)) {
		if ($currentJobTitle) {
			$jobTitle = $currentJobTitle
		} else {
			Write-Host "[ERROR] Job title is required for '$email'." -ForegroundColor Red
			$failed++
			continue
		}
	} else {
		$jobTitle = $jobTitleInput.Trim()
	}

	$result = Add-UserToGroup -GroupId $group.id -UserId $user.id -Email $email
	switch ($result) {
		'added' { $added++ }
		'already-member' { $alreadyMember++ }
		default { $failed++ }
	}

	try {
		Set-UserProfileJobTitle -KeyVaultName $KeyVaultName -SecretName $UserProfileSecretName -Email $email -JobTitle $jobTitle
		$profileUpdated++
		Write-Host "[SUCCESS] Stored job title for '$email' in Key Vault." -ForegroundColor Green
	} catch {
		Write-Host "[ERROR] Failed to store job title for '$email' in Key Vault." -ForegroundColor Red
		Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
		$failed++
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
Write-Host "Profile titles set : $profileUpdated" -ForegroundColor Green
Write-Host "Failed            : $failed" -ForegroundColor Red
Write-Host ""
Write-Host "[INFO] Next step: assign this group to the web app enterprise application and enforce MFA via Conditional Access." -ForegroundColor Cyan


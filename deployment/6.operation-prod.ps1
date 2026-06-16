#Requires -Version 5.1
<#
.SYNOPSIS
    Hardens the EIA Azure infrastructure for production.
.DESCRIPTION
    Locks the platform down to private networking:

      1. Creates a single VNet with three subnets (private endpoints,
         App Service integration, Function integration).
      2. Creates the minimum set of Private DNS zones + Private Endpoints so
         every component (Function Apps, Web App, Foundry Agents) can reach the
         backing services over the VNet only.
      3. Adds regional VNet integration to the Web App and all Function Apps,
         routes all their outbound traffic through the VNet, and disables public
         inbound access on the Function Apps (they stay reachable only over the
         VNet; outbound still works so they can poll the M365 mailbox via Graph).
      4. Disables public network access on Key Vault, Cosmos DB, AI Foundry and
         Content Understanding (Service Bus only if Premium). Storage is set to
         deny-by-default with a resource-instance rule that trusts only the
         Content Understanding account, so CU (a PaaS outside the VNet) can
         still read attachment blobs by URL via its managed identity.
      5. Optionally (prompted) punches a temporary hole for the operator's
         laptop public IP + grants the signed-in user data-plane RBAC, so the
         hardened resources can be reached for testing. Answer "no" and the
         script removes that access and fully locks the resources down.
      6. Refreshes the Key Vault references in the Web App / Function App
         settings so the platform re-resolves them over the private endpoint.

    Idempotent - every step checks current state and skips work that is already
    in the desired configuration. Run after deploy-infrastructure.ps1.

    NOTE: The Web App keeps its public inbound endpoint (it serves the UI to
    end users); only its OUTBOUND path is moved onto the VNet so it can still
    reach the now-private backing services.
.PARAMETER Environment
    Optional. Environment name (default: prod).
.PARAMETER Suffix
    Optional. The same suffix used when running deploy-infrastructure.ps1.
.PARAMETER SkipSteps
    Optional. Skip selected hardening steps using numbers or aliases.
      1/Vnet, 2/Dns, 3/PrivateEndpoints, 4/VnetIntegration, 5/LockPublic,
      6/TestAccess, 7/KVRefresh
.PARAMETER Rollback
    Optional switch. Reverses ALL hardening and returns the platform to its
    pre-hardening state: re-enables public network access on Storage, Cosmos DB,
    Key Vault, AI Foundry, Content Understanding (and Service Bus if Premium),
    re-enables Function App public inbound, removes Web App / Function App VNet
    integration, deletes every private endpoint, private DNS zone + VNet link,
    and finally deletes the VNet and its subnets. Prompts for confirmation.
    Ignores -SkipSteps. RBAC role assignments are left untouched.
.USAGE
    .\6.operation-prod.ps1 -Suffix 999
    .\6.operation-prod.ps1 -Environment prod -Suffix 999
    .\6.operation-prod.ps1 -Suffix 999 -SkipSteps 6
    .\6.operation-prod.ps1 -Suffix 999 -Rollback
#>
param(
    [Parameter(HelpMessage="Environment (default: prod, example: prod)")]
    [string]$Environment,

    [Parameter(HelpMessage="Suffix used during infrastructure deployment (default: 1, example: 1)")]
    [string]$Suffix,

    [ValidateSet('1','2','3','4','5','6','7','Vnet','Dns','PrivateEndpoints','VnetIntegration','LockPublic','TestAccess','KVRefresh')]
    [string[]]$SkipSteps = @(),

    [Parameter(HelpMessage="Undo all hardening: delete VNet/subnets/private endpoints/DNS zones, restore public network access, and remove VNet integration.")]
    [switch]$Rollback
)

$ErrorActionPreference = "Stop"

$LocationInput = Read-Host "Enter location [default: centralus, example: centralus]"
$Location = if ([string]::IsNullOrWhiteSpace($LocationInput)) { "centralus" } else { $LocationInput.Trim().ToLowerInvariant() }

if ([string]::IsNullOrWhiteSpace($Environment)) {
    $EnvironmentInput = Read-Host "Enter environment [default: prod, example: prod]"
    $Environment = if ([string]::IsNullOrWhiteSpace($EnvironmentInput)) { "prod" } else { $EnvironmentInput.Trim().ToLowerInvariant() }
} else {
    $Environment = $Environment.Trim().ToLowerInvariant()
}

if ([string]::IsNullOrWhiteSpace($Suffix)) {
    $SuffixInput = Read-Host "Enter suffix [default: 1, example: 1]"
    $Suffix = if ([string]::IsNullOrWhiteSpace($SuffixInput)) { "1" } else { $SuffixInput.Trim() }
} else {
    $Suffix = $Suffix.Trim()
}

$ProjectNameForLog = if ($env:PROJECT_NAME) { $env:PROJECT_NAME } else { "eia" }
Write-Host "[INFO] Deployment key: $ProjectNameForLog-$Environment-$Suffix (location: $Location)" -ForegroundColor Cyan

# =============================================================================
# HELPER FUNCTIONS
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

# Returns the trimmed stdout of an az query, or '' on failure.
function Get-AzValue {
    param([string[]]$Arguments)
    $r = Invoke-AzCliSilent -Arguments $Arguments
    if ($r.ExitCode -eq 0) { return $r.Output }
    return ''
}

# Creates a private endpoint with retry + backoff. Cognitive Services accounts
# (AI Foundry, Content Understanding) intermittently return transient errors
# (InvalidResponseFromPrivateLinkService, RequestConflict "provisioning state is
# not terminal") when PEs are created against them back-to-back. A failed
# attempt can also leave the PE in a 'Failed' state, so we delete any non-
# 'Succeeded' remnant before each (re)try. Returns $true on success.
function New-PrivateEndpointWithRetry {
    param(
        [Parameter(Mandatory=$true)][hashtable]$Pe,
        [Parameter(Mandatory=$true)][string]$ResourceGroup,
        [Parameter(Mandatory=$true)][string]$VnetName,
        [Parameter(Mandatory=$true)][string]$SubnetName,
        [Parameter(Mandatory=$true)][string]$Location,
        [int]$MaxAttempts = 5,
        [int]$DelaySeconds = 20
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        # Inspect current state; a 'Succeeded' PE is done, anything else (most
        # importantly 'Failed') is deleted so the retry starts from a clean slate.
        $state = Get-AzValue @('network','private-endpoint','show','--name',$Pe.Name,'--resource-group',$ResourceGroup,'--query','provisioningState','-o','tsv')
        if ($state -eq 'Succeeded') {
            return $true
        } elseif ($state) {
            Write-Host "    [INFO] Removing '$($Pe.Name)' (state=$state) before retry" -ForegroundColor DarkYellow
            Invoke-AzCliSilent -Arguments @('network','private-endpoint','delete','--name',$Pe.Name,'--resource-group',$ResourceGroup,'--output','none') | Out-Null
        }

        $createPe = Invoke-AzCliSilent -Arguments @('network','private-endpoint','create','--name',$Pe.Name,
            '--resource-group',$ResourceGroup,'--vnet-name',$VnetName,'--subnet',$SubnetName,
            '--private-connection-resource-id',$Pe.ResourceId,'--group-id',$Pe.GroupId,
            '--connection-name',"$($Pe.Name)-conn",'--location',$Location,'--output','none')

        if ($createPe.ExitCode -eq 0) {
            return $true
        }

        if ($attempt -lt $MaxAttempts) {
            Write-Host "    [WARN] Create of '$($Pe.Name)' failed (attempt $attempt/$MaxAttempts); retrying in ${DelaySeconds}s" -ForegroundColor Yellow
            if ($createPe.Error) { Write-Host "      $($createPe.Error)" -ForegroundColor DarkGray }
            Start-Sleep -Seconds $DelaySeconds
        } else {
            Write-Host "  [ERROR] Failed to create '$($Pe.Name)' after $MaxAttempts attempts" -ForegroundColor Red
            if ($createPe.Error) { Write-Host "    $($createPe.Error)" -ForegroundColor Red }
        }
    }
    return $false
}

# Waits until every private endpoint reports a provisioned + approved connection,
# and the Key Vault private DNS zone has a resolvable A-record. This gates the
# Key Vault reference refresh so the platform resolves over the private path
# instead of failing against the now-disabled public endpoint.
function Wait-PrivateEndpointsReady {
    param(
        [Parameter(Mandatory=$true)][System.Collections.Generic.List[hashtable]]$Endpoints,
        [string]$ResourceGroup,
        [string]$KeyVaultZone = 'privatelink.vaultcore.azure.net',
        [int]$MaxAttempts = 20,
        [int]$DelaySeconds = 15
    )

    $peNames = @($Endpoints | Where-Object { $_.ResourceId } | ForEach-Object { $_.Name })
    if ($peNames.Count -eq 0) {
        Write-Host "  [INFO] No private endpoints to wait for." -ForegroundColor Cyan
        return $true
    }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $pending = [System.Collections.Generic.List[string]]::new()

        foreach ($name in $peNames) {
            # Provisioning state of the private endpoint itself.
            $provState = Get-AzValue @('network','private-endpoint','show','--name',$name,'--resource-group',$ResourceGroup,'--query','provisioningState','-o','tsv')
            # Connection approval status (auto-approved for same-tenant resources).
            $connState = Get-AzValue @('network','private-endpoint','show','--name',$name,'--resource-group',$ResourceGroup,
                '--query','privateLinkServiceConnections[0].privateLinkServiceConnectionState.status','-o','tsv')

            if ($provState -ne 'Succeeded' -or $connState -ne 'Approved') {
                $pending.Add("$name (provisioning=$provState, connection=$connState)")
            }
        }

        # Confirm the Key Vault private endpoint has a DNS A-record in the zone
        # (the record the platform must resolve when refreshing KV references).
        $kvRecord = Get-AzValue @('network','private-dns','record-set','a','list','--zone-name',$KeyVaultZone,'--resource-group',$ResourceGroup,'--query','[0].aRecords[0].ipv4Address','-o','tsv')
        if (-not $kvRecord) {
            $pending.Add("Key Vault DNS A-record not yet populated in $KeyVaultZone")
        }

        if ($pending.Count -eq 0) {
            Write-Host "  [OK] All private endpoints provisioned, approved, and DNS-resolvable" -ForegroundColor Green
            return $true
        }

        Write-Host "  [INFO] Waiting for private endpoints to be ready (attempt $attempt/$MaxAttempts)" -ForegroundColor Cyan
        foreach ($p in $pending) { Write-Host "    - $p" -ForegroundColor Yellow }

        if ($attempt -lt $MaxAttempts) {
            Start-Sleep -Seconds $DelaySeconds
        }
    }

    Write-Host "  [WARNING] Private endpoints not fully ready after $MaxAttempts attempts; proceeding anyway." -ForegroundColor Yellow
    return $false
}

# Forces the App Service / Functions platform to re-resolve Key Vault references
# in its app settings. Needed after Key Vault public access is disabled so the
# platform re-reads secrets over the private endpoint. Retries until resolved.
function Invoke-ConfigReferenceRefresh {
    param(
        [Parameter(Mandatory=$true)][string]$ResourceId,
        [Parameter(Mandatory=$true)][string]$DisplayName,
        [int]$MaxAttempts = 6,
        [int]$DelaySeconds = 10
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $refresh = Invoke-AzCliSilent -Arguments @(
            'rest','--method','POST',
            '--uri',"https://management.azure.com$ResourceId/config/configreferences/appsettings/refresh?api-version=2022-03-01",
            '-o','json'
        )

        if ($refresh.ExitCode -ne 0) {
            Write-Host "  [WARNING] Key Vault reference refresh failed for $DisplayName (attempt $attempt/$MaxAttempts)" -ForegroundColor Yellow
            if ($refresh.Error) { Write-Host "    $($refresh.Error)" -ForegroundColor Yellow }
        } else {
            $unresolved = @()
            try {
                $payload = $refresh.Output | ConvertFrom-Json
                if ($payload.value) {
                    $unresolved = @($payload.value | Where-Object { $_.properties.status -ne 'Resolved' })
                }
            } catch {
                $unresolved = @()
            }

            if ($unresolved.Count -eq 0) {
                Write-Host "  [SUCCESS] Key Vault references refreshed for $DisplayName" -ForegroundColor Green
                return $true
            }

            Write-Host "  [INFO] $DisplayName still has unresolved Key Vault references (attempt $attempt/$MaxAttempts)" -ForegroundColor Cyan
            foreach ($item in $unresolved) {
                Write-Host "    - $($item.name): $($item.properties.status)" -ForegroundColor Yellow
            }
        }

        if ($attempt -lt $MaxAttempts) {
            Start-Sleep -Seconds $DelaySeconds
        }
    }

    Write-Host "  [WARNING] Key Vault references not fully resolved for $DisplayName after $MaxAttempts attempts" -ForegroundColor Yellow
    return $false
}

# =============================================================================
# CONFIGURATION (must match deploy-infrastructure.ps1)
# =============================================================================
$ProjectName        = if ($env:PROJECT_NAME) { $env:PROJECT_NAME } else { "eia" }
$ProjClean          = $ProjectName -replace '-',''
$ResourceGroupName  = "rg-$ProjectName-$Environment-$Suffix"
$StorageAccountName = "st$ProjClean$Environment$Suffix"
$CosmosDbAccountName = "cosmos-$ProjectName-$Environment-$Suffix"
$ContentUnderstandingName = "cu-$ProjectName-$Environment-$Suffix"
$AiFoundryName       = "oai-$ProjectName-$Environment-$Suffix"
$KeyVaultName        = "kv-$ProjectName-$Environment-$Suffix"
$ServiceBusNamespace = "sb-$ProjectName-$Environment-$Suffix"
$FuncMailboxName      = "func-mailbox-$ProjectName-$Environment-$Suffix"
$FuncQueueDbName      = "func-queuedb-$ProjectName-$Environment-$Suffix"
$FuncCuQueueDbName    = "func-cuqueuedb-$ProjectName-$Environment-$Suffix"
$WebAppName           = "app-$ProjectName-$Environment-$Suffix"

# --- Networking layout (single VNet, three subnets) ---
$VnetName            = "vnet-$ProjectName-$Environment-$Suffix"
$VnetAddressSpace    = "10.0.0.0/16"
$SubnetPe            = "snet-privateendpoints"
$SubnetPeCidr        = "10.0.1.0/24"
$SubnetAppService    = "snet-appservice"
$SubnetAppServiceCidr = "10.0.2.0/24"
$SubnetFunctions     = "snet-functions"
$SubnetFunctionsCidr = "10.0.3.0/24"

$FunctionApps = @($FuncMailboxName, $FuncQueueDbName, $FuncCuQueueDbName)

$skipStep1 = (@('1','Vnet')             | Where-Object { $SkipSteps -contains $_ }).Count -gt 0
$skipStep2 = (@('2','Dns')              | Where-Object { $SkipSteps -contains $_ }).Count -gt 0
$skipStep3 = (@('3','PrivateEndpoints') | Where-Object { $SkipSteps -contains $_ }).Count -gt 0
$skipStep4 = (@('4','VnetIntegration')  | Where-Object { $SkipSteps -contains $_ }).Count -gt 0
$skipStep5 = (@('5','LockPublic')       | Where-Object { $SkipSteps -contains $_ }).Count -gt 0
$skipStep6 = (@('6','TestAccess')       | Where-Object { $SkipSteps -contains $_ }).Count -gt 0
$skipStep7 = (@('7','KVRefresh')        | Where-Object { $SkipSteps -contains $_ }).Count -gt 0

$changes = 0

# =============================================================================
# BANNER
# =============================================================================
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Production Hardening: $ProjectName ($Environment)"          -ForegroundColor Cyan
Write-Host "  Resource Group: $ResourceGroupName"                         -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# =============================================================================
# PREREQUISITES
# =============================================================================
Write-Host "[INFO] Checking prerequisites..." -ForegroundColor Cyan

$acctResult = Invoke-AzCliSilent -Arguments @('account','show','--query','state','-o','tsv')
if ($acctResult.ExitCode -ne 0 -or $acctResult.Output -ne "Enabled") {
    Write-Host "[ERROR] Not logged in to Azure CLI. Run 'az login' first." -ForegroundColor Red
    exit 1
}

$userResult = Invoke-AzCliSilent -Arguments @('ad','signed-in-user','show','--query','id','-o','tsv')
$CurrentUserId = $userResult.Output
if (-not $CurrentUserId) {
    Write-Host "[ERROR] Could not determine current user." -ForegroundColor Red
    if ($userResult.Error -match "Continuous access evaluation|InteractionRequired") {
        Write-Host "[ERROR] Azure CLI token expired (CAE challenge). Run:" -ForegroundColor Red
        Write-Host "  az account clear; az login" -ForegroundColor Yellow
    } else {
        Write-Host "[ERROR] Run 'az login' first." -ForegroundColor Red
        if ($userResult.Error) { Write-Host "  $($userResult.Error)" -ForegroundColor Red }
    }
    exit 1
}
$CurrentUserName = (Invoke-AzCliSilent -Arguments @('ad','signed-in-user','show','--query','userPrincipalName','-o','tsv')).Output
Write-Host "[OK] Logged in as: $CurrentUserName ($CurrentUserId)" -ForegroundColor Green

# Verify the backing resources exist (created by deploy-infrastructure.ps1)
$StorageAccountId = Get-AzValue @('storage','account','show','--name',$StorageAccountName,'--resource-group',$ResourceGroupName,'--query','id','-o','tsv')
$CosmosDbAccountId = Get-AzValue @('cosmosdb','show','--name',$CosmosDbAccountName,'--resource-group',$ResourceGroupName,'--query','id','-o','tsv')
$KeyVaultId       = Get-AzValue @('keyvault','show','--name',$KeyVaultName,'--resource-group',$ResourceGroupName,'--query','id','-o','tsv')
$ContentUnderstandingId = Get-AzValue @('cognitiveservices','account','show','--name',$ContentUnderstandingName,'--resource-group',$ResourceGroupName,'--query','id','-o','tsv')
$AiFoundryId      = Get-AzValue @('cognitiveservices','account','show','--name',$AiFoundryName,'--resource-group',$ResourceGroupName,'--query','id','-o','tsv')
$ServiceBusId     = Get-AzValue @('servicebus','namespace','show','--name',$ServiceBusNamespace,'--resource-group',$ResourceGroupName,'--query','id','-o','tsv')
$TenantId         = Get-AzValue @('account','show','--query','tenantId','-o','tsv')

foreach ($pair in @(
    @{ Name = $StorageAccountName;        Id = $StorageAccountId },
    @{ Name = $CosmosDbAccountName;       Id = $CosmosDbAccountId },
    @{ Name = $KeyVaultName;              Id = $KeyVaultId })) {
    if (-not $pair.Id) {
        Write-Host "[ERROR] Required resource '$($pair.Name)' not found in '$ResourceGroupName'." -ForegroundColor Red
        Write-Host "  Run 1.deploy-infrastructure.ps1 -Suffix $Suffix first." -ForegroundColor Yellow
        exit 1
    }
}
Write-Host "[OK] Core resources verified" -ForegroundColor Green

# Service Bus Premium is required for private endpoints / public-access lockdown.
$ServiceBusSku = ''
if ($ServiceBusId) {
    $ServiceBusSku = Get-AzValue @('servicebus','namespace','show','--name',$ServiceBusNamespace,'--resource-group',$ResourceGroupName,'--query','sku.name','-o','tsv')
}
$ServiceBusSupportsPrivate = ($ServiceBusSku -eq 'Premium')
if ($ServiceBusId -and -not $ServiceBusSupportsPrivate) {
    Write-Host "[WARNING] Service Bus '$ServiceBusNamespace' is SKU '$ServiceBusSku'." -ForegroundColor Yellow
    Write-Host "          Private endpoints and public-access lockdown require the Premium SKU." -ForegroundColor Yellow
    Write-Host "          Service Bus hardening will be SKIPPED; it stays RBAC/SAS-secured on its public endpoint." -ForegroundColor Yellow
    Write-Host "          To fully harden it, upgrade first:" -ForegroundColor Yellow
    Write-Host "            az servicebus namespace update -n $ServiceBusNamespace -g $ResourceGroupName --sku Premium" -ForegroundColor DarkGray
}

# =============================================================================
# ROLLBACK: Undo all hardening (delete VNet/PEs/DNS, restore public access)
# =============================================================================
# Reverses the hardening in the opposite order it was applied: first re-open the
# public endpoints and detach VNet integration (so nothing depends on the VNet),
# then delete the private endpoints, DNS zones/links, and finally the VNet.
# RBAC role assignments are intentionally left in place (they are harmless and
# may have been granted outside this script).
if ($Rollback) {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Yellow
    Write-Host "  ROLLBACK: Undo production hardening for $ResourceGroupName" -ForegroundColor Yellow
    Write-Host "============================================================" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "This will DELETE the VNet '$VnetName', all its subnets, every" -ForegroundColor Yellow
    Write-Host "private endpoint and private DNS zone, and RE-ENABLE public" -ForegroundColor Yellow
    Write-Host "network access on Storage, Cosmos DB, Key Vault, AI Foundry," -ForegroundColor Yellow
    Write-Host "Content Understanding and (if Premium) Service Bus." -ForegroundColor Yellow
    Write-Host ""

    $confirm = (Read-Host "Type 'rollback' to proceed (anything else cancels)").Trim().ToLowerInvariant()
    if ($confirm -ne 'rollback') {
        Write-Host "[INFO] Rollback cancelled. No changes made." -ForegroundColor Cyan
        exit 0
    }

    # Deterministic names of everything hardening created (mirrors Steps 1-3).
    $rbPeNames = [System.Collections.Generic.List[string]]::new()
    $rbPeNames.Add("pe-blob-$Environment-$Suffix")
    $rbPeNames.Add("pe-queue-$Environment-$Suffix")
    $rbPeNames.Add("pe-table-$Environment-$Suffix")
    $rbPeNames.Add("pe-cosmos-$Environment-$Suffix")
    $rbPeNames.Add("pe-kv-$Environment-$Suffix")
    if ($AiFoundryId)          { $rbPeNames.Add("pe-foundry-$Environment-$Suffix") }
    if ($ContentUnderstandingId) { $rbPeNames.Add("pe-cu-$Environment-$Suffix") }
    if ($ServiceBusId -and $ServiceBusSupportsPrivate) { $rbPeNames.Add("pe-sb-$Environment-$Suffix") }

    $rbDnsZones = [System.Collections.Generic.List[string]]::new()
    foreach ($z in @('privatelink.blob.core.windows.net','privatelink.queue.core.windows.net',
        'privatelink.table.core.windows.net','privatelink.documents.azure.com',
        'privatelink.vaultcore.azure.net','privatelink.cognitiveservices.azure.com',
        'privatelink.openai.azure.com','privatelink.services.ai.azure.com')) { $rbDnsZones.Add($z) }
    if ($ServiceBusId -and $ServiceBusSupportsPrivate) { $rbDnsZones.Add('privatelink.servicebus.windows.net') }

    # --- R1: Re-enable public network access on backing resources ------------
    Write-Host ""
    Write-Host ">>> Rollback 1: Re-enable Public Network Access" -ForegroundColor White

    # Storage: drop the Content Understanding resource-instance rule, then open.
    if ($ContentUnderstandingId -and $TenantId) {
        Invoke-AzCliSilent -Arguments @('storage','account','network-rule','remove','--account-name',$StorageAccountName,'--resource-group',$ResourceGroupName,
            '--resource-id',$ContentUnderstandingId,'--tenant-id',$TenantId,'--output','none') | Out-Null
    }
    Invoke-AzCliSilent -Arguments @('storage','account','update','--name',$StorageAccountName,'--resource-group',$ResourceGroupName,
        '--public-network-access','Enabled','--default-action','Allow','--output','none') | Out-Null
    Write-Host "  [SUCCESS] Storage '$StorageAccountName' public access restored (default Allow)" -ForegroundColor Green

    Invoke-AzCliSilent -Arguments @('cosmosdb','update','--name',$CosmosDbAccountName,'--resource-group',$ResourceGroupName,
        '--public-network-access','Enabled','--ip-range-filter','','--output','none') | Out-Null
    Write-Host "  [SUCCESS] Cosmos DB '$CosmosDbAccountName' public access restored" -ForegroundColor Green

    Invoke-AzCliSilent -Arguments @('keyvault','update','--name',$KeyVaultName,'--resource-group',$ResourceGroupName,
        '--public-network-access','Enabled','--default-action','Allow','--output','none') | Out-Null
    Write-Host "  [SUCCESS] Key Vault '$KeyVaultName' public access restored (default Allow)" -ForegroundColor Green

    if ($AiFoundryId) {
        Invoke-AzCliSilent -Arguments @('resource','update','--ids',$AiFoundryId,'--set','properties.publicNetworkAccess=Enabled','properties.networkAcls.defaultAction=Allow','--output','none') | Out-Null
        Write-Host "  [SUCCESS] AI Foundry '$AiFoundryName' public access restored" -ForegroundColor Green
    }
    if ($ContentUnderstandingId) {
        Invoke-AzCliSilent -Arguments @('resource','update','--ids',$ContentUnderstandingId,'--set','properties.publicNetworkAccess=Enabled','properties.networkAcls.defaultAction=Allow','--output','none') | Out-Null
        Write-Host "  [SUCCESS] Content Understanding '$ContentUnderstandingName' public access restored" -ForegroundColor Green
    }
    if ($ServiceBusId -and $ServiceBusSupportsPrivate) {
        Invoke-AzCliSilent -Arguments @('servicebus','namespace','update','--name',$ServiceBusNamespace,'--resource-group',$ResourceGroupName,'--public-network-access','Enabled','--output','none') | Out-Null
        Write-Host "  [SUCCESS] Service Bus '$ServiceBusNamespace' public access restored" -ForegroundColor Green
    }

    # --- R2: Restore Function inbound + remove VNet integration ---------------
    Write-Host ""
    Write-Host ">>> Rollback 2: Restore App Inbound + Remove VNet Integration" -ForegroundColor White

    foreach ($fa in $FunctionApps) {
        $faExists = Get-AzValue @('functionapp','show','--name',$fa,'--resource-group',$ResourceGroupName,'--query','name','-o','tsv')
        if (-not $faExists) { continue }
        Invoke-AzCliSilent -Arguments @('functionapp','update','--name',$fa,'--resource-group',$ResourceGroupName,'--set','publicNetworkAccess=Enabled','--output','none') | Out-Null
        Invoke-AzCliSilent -Arguments @('functionapp','config','set','--name',$fa,'--resource-group',$ResourceGroupName,'--vnet-route-all-enabled','false','--output','none') | Out-Null
        Invoke-AzCliSilent -Arguments @('functionapp','vnet-integration','remove','--name',$fa,'--resource-group',$ResourceGroupName,'--output','none') | Out-Null
        Write-Host "  [SUCCESS] Function App '$fa' public inbound restored, VNet integration removed" -ForegroundColor Green
    }

    $webAppExists = Get-AzValue @('webapp','show','--name',$WebAppName,'--resource-group',$ResourceGroupName,'--query','name','-o','tsv')
    if ($webAppExists) {
        Invoke-AzCliSilent -Arguments @('webapp','config','set','--name',$WebAppName,'--resource-group',$ResourceGroupName,'--vnet-route-all-enabled','false','--output','none') | Out-Null
        Invoke-AzCliSilent -Arguments @('webapp','vnet-integration','remove','--name',$WebAppName,'--resource-group',$ResourceGroupName,'--output','none') | Out-Null
        Write-Host "  [SUCCESS] Web App '$WebAppName' VNet integration removed" -ForegroundColor Green
    }

    # --- R3: Delete private endpoints (also removes their DNS zone groups) ----
    Write-Host ""
    Write-Host ">>> Rollback 3: Delete Private Endpoints" -ForegroundColor White

    # Submit all PE deletes in parallel (--no-wait), then wait for them to clear.
    $rbPendingPe = [System.Collections.Generic.List[string]]::new()
    foreach ($peName in $rbPeNames) {
        $exists = Get-AzValue @('network','private-endpoint','show','--name',$peName,'--resource-group',$ResourceGroupName,'--query','name','-o','tsv')
        if ($exists) {
            Write-Host "  [INFO] Submitting delete of private endpoint '$peName'" -ForegroundColor Cyan
            Invoke-AzCliSilent -Arguments @('network','private-endpoint','delete','--name',$peName,'--resource-group',$ResourceGroupName,'--no-wait','--output','none') | Out-Null
            $rbPendingPe.Add($peName)
        } else {
            Write-Host "  [OK] Private endpoint '$peName' not present" -ForegroundColor Gray
        }
    }
    foreach ($peName in $rbPendingPe) {
        for ($attempt = 1; $attempt -le 30; $attempt++) {
            $still = Get-AzValue @('network','private-endpoint','show','--name',$peName,'--resource-group',$ResourceGroupName,'--query','name','-o','tsv')
            if (-not $still) { break }
            Start-Sleep -Seconds 5
        }
        Write-Host "  [SUCCESS] Deleted private endpoint '$peName'" -ForegroundColor Green
    }

    # --- R4: Delete private DNS VNet links + zones ----------------------------
    Write-Host ""
    Write-Host ">>> Rollback 4: Delete Private DNS Zones + Links" -ForegroundColor White

    $linkName = "link-$VnetName"

    # Determine which zones actually exist, so we only act on those.
    $rbExistingZones = [System.Collections.Generic.List[string]]::new()
    foreach ($zone in $rbDnsZones) {
        $zoneExists = Get-AzValue @('network','private-dns','zone','show','--name',$zone,'--resource-group',$ResourceGroupName,'--query','name','-o','tsv')
        if ($zoneExists) { $rbExistingZones.Add($zone) }
        else { Write-Host "  [OK] DNS zone '$zone' not present" -ForegroundColor Gray }
    }

    # Phase 1: delete all VNet links in parallel (a zone can't be deleted while
    # it still has a link), then wait for them to clear.
    $rbPendingLinks = [System.Collections.Generic.List[string]]::new()
    foreach ($zone in $rbExistingZones) {
        $linkExists = Get-AzValue @('network','private-dns','link','vnet','show','--name',$linkName,'--zone-name',$zone,'--resource-group',$ResourceGroupName,'--query','name','-o','tsv')
        if ($linkExists) {
            Invoke-AzCliSilent -Arguments @('network','private-dns','link','vnet','delete','--name',$linkName,'--zone-name',$zone,'--resource-group',$ResourceGroupName,'--yes','--no-wait','--output','none') | Out-Null
            $rbPendingLinks.Add($zone)
        }
    }
    foreach ($zone in $rbPendingLinks) {
        for ($attempt = 1; $attempt -le 20; $attempt++) {
            $still = Get-AzValue @('network','private-dns','link','vnet','show','--name',$linkName,'--zone-name',$zone,'--resource-group',$ResourceGroupName,'--query','name','-o','tsv')
            if (-not $still) { break }
            Start-Sleep -Seconds 5
        }
    }

    # Phase 2: delete the now-unlinked zones in parallel, then wait.
    foreach ($zone in $rbExistingZones) {
        Invoke-AzCliSilent -Arguments @('network','private-dns','zone','delete','--name',$zone,'--resource-group',$ResourceGroupName,'--yes','--no-wait','--output','none') | Out-Null
    }
    foreach ($zone in $rbExistingZones) {
        for ($attempt = 1; $attempt -le 20; $attempt++) {
            $still = Get-AzValue @('network','private-dns','zone','show','--name',$zone,'--resource-group',$ResourceGroupName,'--query','name','-o','tsv')
            if (-not $still) { break }
            Start-Sleep -Seconds 5
        }
        Write-Host "  [SUCCESS] Deleted DNS zone '$zone' (and VNet link)" -ForegroundColor Green
    }

    # --- R5: Delete the VNet (removes all subnets) ---------------------------
    Write-Host ""
    Write-Host ">>> Rollback 5: Delete Virtual Network" -ForegroundColor White

    $vnetExists = Get-AzValue @('network','vnet','show','--name',$VnetName,'--resource-group',$ResourceGroupName,'--query','name','-o','tsv')
    if ($vnetExists) {
        Invoke-AzCliSilent -Arguments @('network','vnet','delete','--name',$VnetName,'--resource-group',$ResourceGroupName,'--output','none') | Out-Null
        Write-Host "  [SUCCESS] Deleted VNet '$VnetName' and its subnets" -ForegroundColor Green
    } else {
        Write-Host "  [OK] VNet '$VnetName' not present" -ForegroundColor Gray
    }

    Write-Host ""
    Write-Host "[SUCCESS] Rollback complete. Platform restored to pre-hardening state." -ForegroundColor Green
    Write-Host "  NOTE: RBAC role assignments were left untouched." -ForegroundColor Cyan
    Write-Host ""
    exit 0
}

# =============================================================================
# PRE-FLIGHT: Local testing access prompt + background RBAC grant
# =============================================================================
# Step 6 grants the signed-in user a large data-plane RBAC set, which is slow
# (many serial role-assignment calls) but completely independent of the VNet /
# private-endpoint / lockdown steps. So we ask the operator up front and, when
# granting, kick the role assignments off in a background job that runs while
# Steps 1-5 execute. The firewall-hole part still happens in Step 6 (it must
# follow Step 5's lockdown); here we only pre-start the RBAC work.
function Get-TestRoleAssignments {
    param([string]$UserId)
    $list = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($role in @('Storage Blob Data Contributor','Storage Blob Data Reader',
                        'Storage Queue Data Contributor','Storage Table Data Contributor',
                        'Storage Blob Data Owner','Storage Blob Delegator')) {
        $list.Add(@{ Type='arm'; Assignee=$UserId; Role=$role; Scope=$StorageAccountId })
    }
    foreach ($role in @('Key Vault Secrets User','Key Vault Secrets Officer','Key Vault Certificates Officer','Key Vault Crypto Officer')) {
        $list.Add(@{ Type='arm'; Assignee=$UserId; Role=$role; Scope=$KeyVaultId })
    }
    # Cosmos DB ARM (management-plane) roles: manage the account, read keys, etc.
    foreach ($role in @('Cosmos DB Account Reader Role','DocumentDB Account Contributor')) {
        $list.Add(@{ Type='arm'; Assignee=$UserId; Role=$role; Scope=$CosmosDbAccountId })
    }
    # Cosmos DB DATA-plane roles: read/write items in containers. These live in a
    # SEPARATE RBAC system (az cosmosdb sql role assignment) - the ARM roles above
    # do NOT grant data access, so without these the user cannot read/write items.
    $list.Add(@{ Type='cosmos'; Assignee=$UserId; Role='Cosmos DB Built-in Data Reader';      RoleDefinitionId='00000000-0000-0000-0000-000000000001'; AccountName=$CosmosDbAccountName; ResourceGroup=$ResourceGroupName; Scope=$CosmosDbAccountId })
    $list.Add(@{ Type='cosmos'; Assignee=$UserId; Role='Cosmos DB Built-in Data Contributor'; RoleDefinitionId='00000000-0000-0000-0000-000000000002'; AccountName=$CosmosDbAccountName; ResourceGroup=$ResourceGroupName; Scope=$CosmosDbAccountId })
    if ($AiFoundryId) {
        foreach ($role in @('Cognitive Services User','Cognitive Services OpenAI User','Azure AI Developer')) {
            $list.Add(@{ Type='arm'; Assignee=$UserId; Role=$role; Scope=$AiFoundryId })
        }
    }
    if ($ContentUnderstandingId) {
        $list.Add(@{ Type='arm'; Assignee=$UserId; Role='Cognitive Services User'; Scope=$ContentUnderstandingId })
    }
    return $list
}

$grantAccess     = $false
$MyPublicIp      = ''
$roleAssignments = @()
$rbacJob         = $null
if (-not $skipStep6) {
    Write-Host ""
    Write-Host ">>> Local Testing Access (asked up front)" -ForegroundColor White
    Write-Host "  This temporarily allows your laptop's public IP through the firewalls" -ForegroundColor DarkCyan
    Write-Host "  and grants your signed-in user data-plane RBAC. Answer 'no' to remove" -ForegroundColor DarkCyan
    Write-Host "  that access and keep the resources fully private." -ForegroundColor DarkCyan
    Write-Host ""

    do {
        $answer = (Read-Host "Allow local testing access for $CurrentUserName ? (yes/no)").Trim().ToLowerInvariant()
    } while ($answer -notin @('yes','y','no','n'))
    $grantAccess = ($answer -in @('yes','y'))

    try {
        $MyPublicIp = (Invoke-RestMethod -Uri 'https://api.ipify.org?format=text' -TimeoutSec 10).Trim()
    } catch {
        Write-Host "  [WARNING] Could not detect public IP; firewall hole will be skipped." -ForegroundColor Yellow
    }

    $roleAssignments = Get-TestRoleAssignments -UserId $CurrentUserId

    # When granting, start the (independent) RBAC creates in the background so
    # they overlap with Steps 1-5. Falls back to synchronous grant in Step 6 if
    # the ThreadJob cmdlet is unavailable.
    if ($grantAccess -and (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue)) {
        $rbacJob = Start-ThreadJob -ScriptBlock {
            param($assignments)
            $created = 0
            foreach ($a in $assignments) {
                if ($a.Type -eq 'cosmos') {
                    $existing = az cosmosdb sql role assignment list --account-name $a.AccountName --resource-group $a.ResourceGroup --query "[?principalId=='$($a.Assignee)' && contains(roleDefinitionId, '$($a.RoleDefinitionId)')] | [0].id" -o tsv 2>$null
                    if ($existing) {
                        "  [OK] $($a.Role) already assigned"
                    } else {
                        az cosmosdb sql role assignment create --account-name $a.AccountName --resource-group $a.ResourceGroup --role-definition-id $a.RoleDefinitionId --principal-id $a.Assignee --scope $a.Scope --output none 2>$null
                        "  [SUCCESS] Granted $($a.Role)"
                        $created++
                    }
                    continue
                }
                if (-not $a.Scope) { continue }
                $existing = az role assignment list --assignee $a.Assignee --role $a.Role --scope $a.Scope --query '[0].id' -o tsv 2>$null
                if ($existing) {
                    "  [OK] $($a.Role) already assigned"
                } else {
                    az role assignment create --assignee $a.Assignee --role $a.Role --scope $a.Scope --output none 2>$null
                    "  [SUCCESS] Granted $($a.Role)"
                    $created++
                }
            }
            "GRANTED_COUNT=$created"
        } -ArgumentList (,$roleAssignments)
        Write-Host "  [INFO] Granting RBAC in the background while platform steps run..." -ForegroundColor Cyan
    }
}

# =============================================================================
# STEP 1: Virtual Network + Subnets
# =============================================================================
if ($skipStep1) {
    Write-Host ""
    Write-Host ">>> Step 1: Virtual Network + Subnets" -ForegroundColor White
    Write-Host "  [SKIPPED] Step 1 skipped by -SkipSteps" -ForegroundColor Yellow
} else {
    Write-Host ""
    Write-Host ">>> Step 1: Virtual Network + Subnets" -ForegroundColor White

    # VNet
    $existingVnet = Get-AzValue @('network','vnet','show','--name',$VnetName,'--resource-group',$ResourceGroupName,'--query','name','-o','tsv')
    if ($existingVnet) {
        Write-Host "  [OK] VNet '$VnetName' already exists" -ForegroundColor Gray
    } else {
        Write-Host "  [INFO] Creating VNet '$VnetName' ($VnetAddressSpace)" -ForegroundColor Cyan
        Invoke-AzCliSilent -Arguments @('network','vnet','create','--name',$VnetName,'--resource-group',$ResourceGroupName,
            '--location',$Location,'--address-prefixes',$VnetAddressSpace,'--output','none') | Out-Null
        $changes++
    }

    # Subnet: private endpoints (network policies disabled so PEs can be created)
    $existingPe = Get-AzValue @('network','vnet','subnet','show','--name',$SubnetPe,'--vnet-name',$VnetName,'--resource-group',$ResourceGroupName,'--query','name','-o','tsv')
    if ($existingPe) {
        Write-Host "  [OK] Subnet '$SubnetPe' already exists" -ForegroundColor Gray
    } else {
        Write-Host "  [INFO] Creating subnet '$SubnetPe' ($SubnetPeCidr)" -ForegroundColor Cyan
        Invoke-AzCliSilent -Arguments @('network','vnet','subnet','create','--name',$SubnetPe,'--vnet-name',$VnetName,
            '--resource-group',$ResourceGroupName,'--address-prefixes',$SubnetPeCidr,
            '--private-endpoint-network-policies','Disabled','--output','none') | Out-Null
        $changes++
    }

    # Subnet: App Service regional VNet integration (delegated to Microsoft.Web/serverFarms)
    $existingApp = Get-AzValue @('network','vnet','subnet','show','--name',$SubnetAppService,'--vnet-name',$VnetName,'--resource-group',$ResourceGroupName,'--query','name','-o','tsv')
    if ($existingApp) {
        Write-Host "  [OK] Subnet '$SubnetAppService' already exists" -ForegroundColor Gray
    } else {
        Write-Host "  [INFO] Creating subnet '$SubnetAppService' ($SubnetAppServiceCidr, delegated Microsoft.Web/serverFarms)" -ForegroundColor Cyan
        Invoke-AzCliSilent -Arguments @('network','vnet','subnet','create','--name',$SubnetAppService,'--vnet-name',$VnetName,
            '--resource-group',$ResourceGroupName,'--address-prefixes',$SubnetAppServiceCidr,
            '--delegations','Microsoft.Web/serverFarms','--output','none') | Out-Null
        $changes++
    }

    # Subnet: Flex Consumption Functions VNet integration (delegated to Microsoft.App/environments)
    $existingFunc = Get-AzValue @('network','vnet','subnet','show','--name',$SubnetFunctions,'--vnet-name',$VnetName,'--resource-group',$ResourceGroupName,'--query','name','-o','tsv')
    if ($existingFunc) {
        Write-Host "  [OK] Subnet '$SubnetFunctions' already exists" -ForegroundColor Gray
    } else {
        Write-Host "  [INFO] Creating subnet '$SubnetFunctions' ($SubnetFunctionsCidr, delegated Microsoft.App/environments)" -ForegroundColor Cyan
        Invoke-AzCliSilent -Arguments @('network','vnet','subnet','create','--name',$SubnetFunctions,'--vnet-name',$VnetName,
            '--resource-group',$ResourceGroupName,'--address-prefixes',$SubnetFunctionsCidr,
            '--delegations','Microsoft.App/environments','--output','none') | Out-Null
        $changes++
    }
}

$PeSubnetId = Get-AzValue @('network','vnet','subnet','show','--name',$SubnetPe,'--vnet-name',$VnetName,'--resource-group',$ResourceGroupName,'--query','id','-o','tsv')

# =============================================================================
# STEP 2: Private DNS Zones + VNet links
# =============================================================================
# Minimum set of zones needed for the private endpoints created in Step 3.
$dnsZones = [System.Collections.Generic.List[string]]::new()
@(
    'privatelink.blob.core.windows.net',
    'privatelink.queue.core.windows.net',
    'privatelink.table.core.windows.net',
    'privatelink.documents.azure.com',
    'privatelink.vaultcore.azure.net',
    'privatelink.cognitiveservices.azure.com',
    'privatelink.openai.azure.com',
    'privatelink.services.ai.azure.com'
) | ForEach-Object { $dnsZones.Add($_) }
if ($ServiceBusSupportsPrivate) { $dnsZones.Add('privatelink.servicebus.windows.net') }

if ($skipStep2) {
    Write-Host ""
    Write-Host ">>> Step 2: Private DNS Zones + VNet links" -ForegroundColor White
    Write-Host "  [SKIPPED] Step 2 skipped by -SkipSteps" -ForegroundColor Yellow
} else {
    Write-Host ""
    Write-Host ">>> Step 2: Private DNS Zones + VNet links" -ForegroundColor White

    $linkName = "link-$VnetName"

    # --- Phase 1: ensure all DNS zones exist (fast control-plane metadata) ----
    foreach ($zone in $dnsZones) {
        $existingZone = Get-AzValue @('network','private-dns','zone','show','--name',$zone,'--resource-group',$ResourceGroupName,'--query','name','-o','tsv')
        if ($existingZone) {
            Write-Host "  [OK] DNS zone '$zone' already exists" -ForegroundColor Gray
        } else {
            Write-Host "  [INFO] Creating DNS zone '$zone'" -ForegroundColor Cyan
            Invoke-AzCliSilent -Arguments @('network','private-dns','zone','create','--name',$zone,'--resource-group',$ResourceGroupName,'--output','none') | Out-Null
            $changes++
        }
    }

    # --- Phase 2: submit all missing VNet links in parallel (--no-wait) --------
    # The links are independent and the slower part of this step, so fire them
    # all at once and wait for them together rather than blocking on each.
    $pendingLinks = [System.Collections.Generic.List[string]]::new()
    foreach ($zone in $dnsZones) {
        $existingLink = Get-AzValue @('network','private-dns','link','vnet','show','--name',$linkName,'--zone-name',$zone,'--resource-group',$ResourceGroupName,'--query','name','-o','tsv')
        if ($existingLink) {
            Write-Host "  [OK] VNet link for '$zone' already exists" -ForegroundColor Gray
        } else {
            Write-Host "  [INFO] Submitting VNet link for '$zone'" -ForegroundColor Cyan
            Invoke-AzCliSilent -Arguments @('network','private-dns','link','vnet','create','--name',$linkName,'--zone-name',$zone,
                '--resource-group',$ResourceGroupName,'--virtual-network',$VnetName,'--registration-enabled','false','--no-wait','--output','none') | Out-Null
            $pendingLinks.Add($zone)
        }
    }

    # --- Phase 3: wait for the submitted links to reach a terminal state -------
    foreach ($zone in $pendingLinks) {
        $linkOk = $false
        for ($attempt = 1; $attempt -le 20; $attempt++) {
            $state = Get-AzValue @('network','private-dns','link','vnet','show','--name',$linkName,'--zone-name',$zone,'--resource-group',$ResourceGroupName,'--query','provisioningState','-o','tsv')
            if ($state -eq 'Succeeded') { $linkOk = $true; break }
            if ($state -eq 'Failed' -or -not $state) { break }
            Start-Sleep -Seconds 5
        }
        if ($linkOk) {
            Write-Host "  [SUCCESS] VNet link for '$zone' created" -ForegroundColor Green
            $changes++
        } else {
            Write-Host "  [ERROR] VNet link for '$zone' did not provision" -ForegroundColor Red
        }
    }
}

# =============================================================================
# STEP 3: Private Endpoints (+ DNS zone groups)
# =============================================================================
# Each entry: Name, ResourceId, GroupId (sub-resource), Zones (private DNS zones).
$peDefs = [System.Collections.Generic.List[hashtable]]::new()
$peDefs.Add(@{ Name="pe-blob-$Environment-$Suffix";  ResourceId=$StorageAccountId; GroupId='blob';  Zones=@('privatelink.blob.core.windows.net') })
$peDefs.Add(@{ Name="pe-queue-$Environment-$Suffix"; ResourceId=$StorageAccountId; GroupId='queue'; Zones=@('privatelink.queue.core.windows.net') })
$peDefs.Add(@{ Name="pe-table-$Environment-$Suffix"; ResourceId=$StorageAccountId; GroupId='table'; Zones=@('privatelink.table.core.windows.net') })
$peDefs.Add(@{ Name="pe-cosmos-$Environment-$Suffix"; ResourceId=$CosmosDbAccountId; GroupId='Sql'; Zones=@('privatelink.documents.azure.com') })
$peDefs.Add(@{ Name="pe-kv-$Environment-$Suffix";    ResourceId=$KeyVaultId;       GroupId='vault'; Zones=@('privatelink.vaultcore.azure.net') })
if ($AiFoundryId) {
    $peDefs.Add(@{ Name="pe-foundry-$Environment-$Suffix"; ResourceId=$AiFoundryId; GroupId='account';
        Zones=@('privatelink.cognitiveservices.azure.com','privatelink.openai.azure.com','privatelink.services.ai.azure.com') })
}
if ($ContentUnderstandingId) {
    $peDefs.Add(@{ Name="pe-cu-$Environment-$Suffix"; ResourceId=$ContentUnderstandingId; GroupId='account';
        Zones=@('privatelink.cognitiveservices.azure.com','privatelink.openai.azure.com') })
}
if ($ServiceBusId -and $ServiceBusSupportsPrivate) {
    $peDefs.Add(@{ Name="pe-sb-$Environment-$Suffix"; ResourceId=$ServiceBusId; GroupId='namespace'; Zones=@('privatelink.servicebus.windows.net') })
}

if ($skipStep3) {
    Write-Host ""
    Write-Host ">>> Step 3: Private Endpoints" -ForegroundColor White
    Write-Host "  [SKIPPED] Step 3 skipped by -SkipSteps" -ForegroundColor Yellow
} elseif (-not $PeSubnetId) {
    Write-Host ""
    Write-Host ">>> Step 3: Private Endpoints" -ForegroundColor White
    Write-Host "  [ERROR] Private-endpoint subnet not found. Run Step 1 first." -ForegroundColor Red
} else {
    Write-Host ""
    Write-Host ">>> Step 3: Private Endpoints" -ForegroundColor White

    # --- Phase 1: submit all missing PE creates in parallel (--no-wait) -------
    # The private endpoints are independent, so we fire every create at once and
    # let Azure provision them concurrently instead of blocking on each. Any that
    # fail transiently (common on Cognitive Services accounts) are recreated
    # serially with backoff in Phase 2.
    $pendingPe = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($pe in $peDefs) {
        if (-not $pe.ResourceId) { continue }

        # Treat only a 'Succeeded' PE as already-present; a 'Failed' remnant from a
        # prior transient error is deleted and resubmitted rather than skipped.
        $peState = Get-AzValue @('network','private-endpoint','show','--name',$pe.Name,'--resource-group',$ResourceGroupName,'--query','provisioningState','-o','tsv')
        if ($peState -eq 'Succeeded') {
            Write-Host "  [OK] Private endpoint '$($pe.Name)' already exists" -ForegroundColor Gray
            continue
        }
        if ($peState) {
            Write-Host "    [INFO] Removing '$($pe.Name)' (state=$peState) before resubmit" -ForegroundColor DarkYellow
            Invoke-AzCliSilent -Arguments @('network','private-endpoint','delete','--name',$pe.Name,'--resource-group',$ResourceGroupName,'--output','none') | Out-Null
        }

        Write-Host "  [INFO] Submitting private endpoint '$($pe.Name)' (group: $($pe.GroupId))" -ForegroundColor Cyan
        Invoke-AzCliSilent -Arguments @('network','private-endpoint','create','--name',$pe.Name,
            '--resource-group',$ResourceGroupName,'--vnet-name',$VnetName,'--subnet',$SubnetPe,
            '--private-connection-resource-id',$pe.ResourceId,'--group-id',$pe.GroupId,
            '--connection-name',"$($pe.Name)-conn",'--location',$Location,'--no-wait','--output','none') | Out-Null
        $pendingPe.Add($pe)
    }

    # --- Phase 2: wait for the submitted PEs to reach a terminal state --------
    # Because all creates were submitted up front, the total wait is roughly the
    # slowest single PE rather than the sum of all of them.
    foreach ($pe in $pendingPe) {
        $ok = $false
        for ($attempt = 1; $attempt -le 30; $attempt++) {
            $state = Get-AzValue @('network','private-endpoint','show','--name',$pe.Name,'--resource-group',$ResourceGroupName,'--query','provisioningState','-o','tsv')
            if ($state -eq 'Succeeded') { $ok = $true; break }
            if ($state -eq 'Failed' -or -not $state) {
                # Transient failure (common on Cognitive Services): recreate serially.
                Write-Host "  [WARN] '$($pe.Name)' state='$state'; recreating with retry" -ForegroundColor Yellow
                $ok = New-PrivateEndpointWithRetry -Pe $pe -ResourceGroup $ResourceGroupName -VnetName $VnetName -SubnetName $SubnetPe -Location $Location
                break
            }
            Start-Sleep -Seconds 10
        }
        if ($ok) {
            Write-Host "  [SUCCESS] Private endpoint '$($pe.Name)' provisioned" -ForegroundColor Green
            $changes++
        } else {
            Write-Host "  [ERROR] Private endpoint '$($pe.Name)' did not provision" -ForegroundColor Red
        }
    }

    # --- Phase 3: DNS zone groups for every provisioned PE (idempotent) -------
    foreach ($pe in $peDefs) {
        if (-not $pe.ResourceId) { continue }

        $peState = Get-AzValue @('network','private-endpoint','show','--name',$pe.Name,'--resource-group',$ResourceGroupName,'--query','provisioningState','-o','tsv')
        if ($peState -ne 'Succeeded') {
            Write-Host "  [SKIP] DNS zone group for '$($pe.Name)' (PE not provisioned)" -ForegroundColor Yellow
            continue
        }

        # DNS zone group (idempotent): one group per PE, one config entry per zone.
        $groupName = "$($pe.Name)-zg"
        $existingZg = Get-AzValue @('network','private-endpoint','dns-zone-group','list','--endpoint-name',$pe.Name,'--resource-group',$ResourceGroupName,'--query','[0].name','-o','tsv')
        if ($existingZg) {
            Write-Host "  [OK] DNS zone group for '$($pe.Name)' already exists" -ForegroundColor Gray
        } else {
            $firstZone = $pe.Zones[0]
            Invoke-AzCliSilent -Arguments @('network','private-endpoint','dns-zone-group','create',
                '--name',$groupName,'--endpoint-name',$pe.Name,'--resource-group',$ResourceGroupName,
                '--private-dns-zone',$firstZone,'--zone-name',($firstZone -replace '\.','-'),'--output','none') | Out-Null
            for ($i = 1; $i -lt $pe.Zones.Count; $i++) {
                $z = $pe.Zones[$i]
                Invoke-AzCliSilent -Arguments @('network','private-endpoint','dns-zone-group','add',
                    '--name',$groupName,'--endpoint-name',$pe.Name,'--resource-group',$ResourceGroupName,
                    '--private-dns-zone',$z,'--zone-name',($z -replace '\.','-'),'--output','none') | Out-Null
            }
            Write-Host "  [SUCCESS] DNS zone group for '$($pe.Name)' created" -ForegroundColor Green
            $changes++
        }
    }
}

# =============================================================================
# STEP 4: VNet Integration (Web App + Function Apps) + Functions inbound lockdown
# =============================================================================
if ($skipStep4) {
    Write-Host ""
    Write-Host ">>> Step 4: VNet Integration + Functions Lockdown" -ForegroundColor White
    Write-Host "  [SKIPPED] Step 4 skipped by -SkipSteps" -ForegroundColor Yellow
} else {
    Write-Host ""
    Write-Host ">>> Step 4: VNet Integration + Functions Lockdown" -ForegroundColor White

    $AppSubnetId  = Get-AzValue @('network','vnet','subnet','show','--name',$SubnetAppService,'--vnet-name',$VnetName,'--resource-group',$ResourceGroupName,'--query','id','-o','tsv')
    $FuncSubnetId = Get-AzValue @('network','vnet','subnet','show','--name',$SubnetFunctions,'--vnet-name',$VnetName,'--resource-group',$ResourceGroupName,'--query','id','-o','tsv')

    # --- Web App: outbound VNet integration only (keep public inbound for the UI) ---
    $webAppExists = Get-AzValue @('webapp','show','--name',$WebAppName,'--resource-group',$ResourceGroupName,'--query','name','-o','tsv')
    if (-not $webAppExists) {
        Write-Host "  [WARNING] Web App '$WebAppName' not found. Skipping." -ForegroundColor Yellow
    } elseif (-not $AppSubnetId) {
        Write-Host "  [WARNING] App Service subnet not found. Skipping Web App integration." -ForegroundColor Yellow
    } else {
        $currentWebSubnet = Get-AzValue @('webapp','show','--name',$WebAppName,'--resource-group',$ResourceGroupName,'--query','virtualNetworkSubnetId','-o','tsv')
        if ($currentWebSubnet -eq $AppSubnetId) {
            Write-Host "  [OK] Web App '$WebAppName' already VNet-integrated" -ForegroundColor Gray
        } else {
            Write-Host "  [INFO] Adding VNet integration to Web App '$WebAppName'" -ForegroundColor Cyan
            Invoke-AzCliSilent -Arguments @('webapp','vnet-integration','add','--name',$WebAppName,'--resource-group',$ResourceGroupName,
                '--vnet',$VnetName,'--subnet',$SubnetAppService,'--output','none') | Out-Null
            $changes++
        }
        # Route all outbound through the VNet so it resolves private endpoints.
        $routeAll = Get-AzValue @('webapp','config','show','--name',$WebAppName,'--resource-group',$ResourceGroupName,'--query','vnetRouteAllEnabled','-o','tsv')
        if ($routeAll -ne 'true') {
            Invoke-AzCliSilent -Arguments @('webapp','config','set','--name',$WebAppName,'--resource-group',$ResourceGroupName,'--vnet-route-all-enabled','true','--output','none') | Out-Null
            Write-Host "  [SUCCESS] Web App outbound routed through VNet" -ForegroundColor Green
            $changes++
        }
    }

    # --- Function Apps: outbound VNet integration + disable public inbound ---
    foreach ($fa in $FunctionApps) {
        $faExists = Get-AzValue @('functionapp','show','--name',$fa,'--resource-group',$ResourceGroupName,'--query','name','-o','tsv')
        if (-not $faExists) {
            Write-Host "  [WARNING] Function App '$fa' not found. Skipping." -ForegroundColor Yellow
            continue
        }
        if (-not $FuncSubnetId) {
            Write-Host "  [WARNING] Functions subnet not found. Skipping Function App integration." -ForegroundColor Yellow
            break
        }

        $currentFaSubnet = Get-AzValue @('functionapp','show','--name',$fa,'--resource-group',$ResourceGroupName,'--query','virtualNetworkSubnetId','-o','tsv')
        if ($currentFaSubnet -eq $FuncSubnetId) {
            Write-Host "  [OK] Function App '$fa' already VNet-integrated" -ForegroundColor Gray
        } else {
            Write-Host "  [INFO] Adding VNet integration to Function App '$fa'" -ForegroundColor Cyan
            Invoke-AzCliSilent -Arguments @('functionapp','vnet-integration','add','--name',$fa,'--resource-group',$ResourceGroupName,
                '--vnet',$VnetName,'--subnet',$SubnetFunctions,'--output','none') | Out-Null
            $changes++
        }

        # Route all outbound through the VNet (reach private endpoints; Graph API
        # still reachable via the subnet's default internet egress).
        $faRouteAll = Get-AzValue @('functionapp','config','show','--name',$fa,'--resource-group',$ResourceGroupName,'--query','vnetRouteAllEnabled','-o','tsv')
        if ($faRouteAll -ne 'true') {
            Invoke-AzCliSilent -Arguments @('functionapp','config','set','--name',$fa,'--resource-group',$ResourceGroupName,'--vnet-route-all-enabled','true','--output','none') | Out-Null
            Write-Host "  [SUCCESS] '$fa' outbound routed through VNet" -ForegroundColor Green
            $changes++
        }

        # Disable public inbound access (triggers are pull-based over the VNet,
        # so no public inbound endpoint is required).
        $faPublic = Get-AzValue @('functionapp','show','--name',$fa,'--resource-group',$ResourceGroupName,'--query','publicNetworkAccess','-o','tsv')
        if ($faPublic -eq 'Disabled') {
            Write-Host "  [OK] '$fa' public inbound already disabled" -ForegroundColor Gray
        } else {
            Invoke-AzCliSilent -Arguments @('functionapp','update','--name',$fa,'--resource-group',$ResourceGroupName,'--set','publicNetworkAccess=Disabled','--output','none') | Out-Null
            Write-Host "  [SUCCESS] '$fa' public inbound disabled" -ForegroundColor Green
            $changes++
        }
    }
}

# =============================================================================
# STEP 5: Disable public network access on backing resources
# =============================================================================
# NOTE: This is intentionally LAST among the platform steps - the private
# endpoints, DNS and VNet integration above must be in place first so the apps
# keep working once the public doors close. Step 6 can re-open a narrow hole.
if ($skipStep5) {
    Write-Host ""
    Write-Host ">>> Step 5: Disable Public Network Access" -ForegroundColor White
    Write-Host "  [SKIPPED] Step 5 skipped by -SkipSteps" -ForegroundColor Yellow
} else {
    Write-Host ""
    Write-Host ">>> Step 5: Disable Public Network Access" -ForegroundColor White

    # Storage
    # NOTE (Option A - trusted services): Content Understanding is a multi-tenant
    # PaaS that lives OUTSIDE this VNet, so it cannot reach Storage over the
    # private endpoint, and a fully Disabled public endpoint would also nullify
    # the trusted-services bypass. Instead we keep the public endpoint Enabled but
    # DENY by default, turn on the AzureServices bypass, and add a
    # resource-instance rule that trusts ONLY the Content Understanding account.
    # CU then reads attachment blobs by URL using its managed identity (already
    # granted Storage Blob Data Reader by 1.deploy-infrastructure.ps1). No public
    # IP can reach the data plane; the apps still use the private endpoints.
    $stDefaultAction = Get-AzValue @('storage','account','show','--name',$StorageAccountName,'--resource-group',$ResourceGroupName,'--query','networkRuleSet.defaultAction','-o','tsv')
    if ($stDefaultAction -eq 'Deny') {
        Write-Host "  [OK] Storage '$StorageAccountName' already locked to Deny (trusted services)" -ForegroundColor Gray
    } else {
        Invoke-AzCliSilent -Arguments @('storage','account','update','--name',$StorageAccountName,'--resource-group',$ResourceGroupName,
            '--public-network-access','Enabled','--default-action','Deny','--bypass','AzureServices','--output','none') | Out-Null
        Write-Host "  [SUCCESS] Storage '$StorageAccountName' locked to Deny (trusted-services bypass on)" -ForegroundColor Green
        $changes++
    }
    # Resource-instance rule: trust the Content Understanding account so it can
    # fetch attachment blobs by URL through Storage's (deny-by-default) endpoint.
    if ($ContentUnderstandingId -and $TenantId) {
        $cuRule = Get-AzValue @('storage','account','show','--name',$StorageAccountName,'--resource-group',$ResourceGroupName,'--query',"networkRuleSet.resourceAccessRules[?resourceId=='$ContentUnderstandingId'] | [0].resourceId",'-o','tsv')
        if ($cuRule) {
            Write-Host "  [OK] Storage already trusts Content Understanding '$ContentUnderstandingName'" -ForegroundColor Gray
        } else {
            Invoke-AzCliSilent -Arguments @('storage','account','network-rule','add','--account-name',$StorageAccountName,'--resource-group',$ResourceGroupName,
                '--resource-id',$ContentUnderstandingId,'--tenant-id',$TenantId,'--output','none') | Out-Null
            Write-Host "  [SUCCESS] Storage now trusts Content Understanding '$ContentUnderstandingName'" -ForegroundColor Green
            $changes++
        }
    } else {
        Write-Host "  [WARN] Skipped Content Understanding resource-instance rule (CU id or tenant id unavailable)" -ForegroundColor Yellow
    }

    # Cosmos DB
    $cosmosPublic = Get-AzValue @('cosmosdb','show','--name',$CosmosDbAccountName,'--resource-group',$ResourceGroupName,'--query','publicNetworkAccess','-o','tsv')
    if ($cosmosPublic -eq 'Disabled') {
        Write-Host "  [OK] Cosmos DB '$CosmosDbAccountName' public access already disabled" -ForegroundColor Gray
    } else {
        Invoke-AzCliSilent -Arguments @('cosmosdb','update','--name',$CosmosDbAccountName,'--resource-group',$ResourceGroupName,'--public-network-access','Disabled','--output','none') | Out-Null
        Write-Host "  [SUCCESS] Cosmos DB '$CosmosDbAccountName' public access disabled" -ForegroundColor Green
        $changes++
    }

    # Key Vault
    $kvPublic = Get-AzValue @('keyvault','show','--name',$KeyVaultName,'--resource-group',$ResourceGroupName,'--query','properties.publicNetworkAccess','-o','tsv')
    if ($kvPublic -eq 'Disabled') {
        Write-Host "  [OK] Key Vault '$KeyVaultName' public access already disabled" -ForegroundColor Gray
    } else {
        Invoke-AzCliSilent -Arguments @('keyvault','update','--name',$KeyVaultName,'--resource-group',$ResourceGroupName,
            '--public-network-access','Disabled','--default-action','Deny','--bypass','AzureServices','--output','none') | Out-Null
        Write-Host "  [SUCCESS] Key Vault '$KeyVaultName' public access disabled" -ForegroundColor Green
        $changes++
    }

    # AI Foundry (Cognitive Services / AIServices)
    if ($AiFoundryId) {
        $foundryPublic = Get-AzValue @('resource','show','--ids',$AiFoundryId,'--query','properties.publicNetworkAccess','-o','tsv')
        if ($foundryPublic -eq 'Disabled') {
            Write-Host "  [OK] AI Foundry '$AiFoundryName' public access already disabled" -ForegroundColor Gray
        } else {
            Invoke-AzCliSilent -Arguments @('resource','update','--ids',$AiFoundryId,'--set','properties.publicNetworkAccess=Disabled','properties.networkAcls.defaultAction=Deny','--output','none') | Out-Null
            Write-Host "  [SUCCESS] AI Foundry '$AiFoundryName' public access disabled" -ForegroundColor Green
            $changes++
        }
    }

    # Content Understanding (Cognitive Services / AIServices)
    if ($ContentUnderstandingId) {
        $cuPublic = Get-AzValue @('resource','show','--ids',$ContentUnderstandingId,'--query','properties.publicNetworkAccess','-o','tsv')
        if ($cuPublic -eq 'Disabled') {
            Write-Host "  [OK] Content Understanding '$ContentUnderstandingName' public access already disabled" -ForegroundColor Gray
        } else {
            Invoke-AzCliSilent -Arguments @('resource','update','--ids',$ContentUnderstandingId,'--set','properties.publicNetworkAccess=Disabled','properties.networkAcls.defaultAction=Deny','--output','none') | Out-Null
            Write-Host "  [SUCCESS] Content Understanding '$ContentUnderstandingName' public access disabled" -ForegroundColor Green
            $changes++
        }
    }

    # Service Bus (Premium only)
    if ($ServiceBusId -and $ServiceBusSupportsPrivate) {
        $sbPublic = Get-AzValue @('servicebus','namespace','show','--name',$ServiceBusNamespace,'--resource-group',$ResourceGroupName,'--query','publicNetworkAccess','-o','tsv')
        if ($sbPublic -eq 'Disabled') {
            Write-Host "  [OK] Service Bus '$ServiceBusNamespace' public access already disabled" -ForegroundColor Gray
        } else {
            Invoke-AzCliSilent -Arguments @('servicebus','namespace','update','--name',$ServiceBusNamespace,'--resource-group',$ResourceGroupName,'--public-network-access','Disabled','--output','none') | Out-Null
            Write-Host "  [SUCCESS] Service Bus '$ServiceBusNamespace' public access disabled" -ForegroundColor Green
            $changes++
        }
    } elseif ($ServiceBusId) {
        Write-Host "  [SKIP] Service Bus '$ServiceBusNamespace' is '$ServiceBusSku' - public lockdown requires Premium" -ForegroundColor Yellow
    }
}

# =============================================================================
# STEP 6: Local testing access - laptop IP firewall hole + collect RBAC grants
# =============================================================================
# The signed-in-user RBAC grant was decided and (when granting) kicked off in
# the background during pre-flight, so it overlapped with Steps 1-5. Here we
# open/close the laptop-IP firewall holes (which must follow Step 5's lockdown)
# and then collect the background RBAC job.
if ($skipStep6) {
    Write-Host ""
    Write-Host ">>> Step 6: Local Testing Access" -ForegroundColor White
    Write-Host "  [SKIPPED] Step 6 skipped by -SkipSteps" -ForegroundColor Yellow
} else {
    Write-Host ""
    Write-Host ">>> Step 6: Local Testing Access (TESTING ONLY)" -ForegroundColor White

    if ($grantAccess) {
        Write-Host "  [INFO] GRANTING local testing access (IP: $MyPublicIp)" -ForegroundColor Cyan

        # Re-enable public endpoints with default-Deny + allow only the laptop IP.
        # Private endpoints remain the path for the apps; this is just for the operator.
        if ($MyPublicIp) {
            Invoke-AzCliSilent -Arguments @('storage','account','update','--name',$StorageAccountName,'--resource-group',$ResourceGroupName,
                '--public-network-access','Enabled','--default-action','Deny','--bypass','AzureServices','--output','none') | Out-Null
            Invoke-AzCliSilent -Arguments @('storage','account','network-rule','add','--account-name',$StorageAccountName,'--resource-group',$ResourceGroupName,'--ip-address',$MyPublicIp,'--output','none') | Out-Null

            Invoke-AzCliSilent -Arguments @('keyvault','update','--name',$KeyVaultName,'--resource-group',$ResourceGroupName,
                '--public-network-access','Enabled','--default-action','Deny','--bypass','AzureServices','--output','none') | Out-Null
            Invoke-AzCliSilent -Arguments @('keyvault','network-rule','add','--name',$KeyVaultName,'--resource-group',$ResourceGroupName,'--ip-address',$MyPublicIp,'--output','none') | Out-Null

            Invoke-AzCliSilent -Arguments @('cosmosdb','update','--name',$CosmosDbAccountName,'--resource-group',$ResourceGroupName,
                '--public-network-access','Enabled','--ip-range-filter',$MyPublicIp,'--output','none') | Out-Null

            Write-Host "  [SUCCESS] Firewall hole opened for $MyPublicIp (Storage, Key Vault, Cosmos DB)" -ForegroundColor Green
            $changes++
        }

        # Collect the RBAC grants kicked off in the background during pre-flight
        # (or run them now if the background job was unavailable).
        if ($rbacJob) {
            Write-Host "  [INFO] Waiting for background RBAC grants to finish..." -ForegroundColor Cyan
            $rbacOutput = Receive-Job -Job $rbacJob -Wait -AutoRemoveJob
            foreach ($line in $rbacOutput) {
                if ($line -match '^GRANTED_COUNT=(\d+)$') {
                    $g = [int]$Matches[1]; if ($g -gt 0) { $changes += $g }
                } elseif ($line -like '*already assigned*') {
                    Write-Host $line -ForegroundColor Gray
                } else {
                    Write-Host $line -ForegroundColor Green
                }
            }
        } else {
            $granted = 0
            foreach ($a in $roleAssignments) {
                if ($a.Type -eq 'cosmos') {
                    $existing = Get-AzValue @('cosmosdb','sql','role','assignment','list','--account-name',$a.AccountName,'--resource-group',$a.ResourceGroup,'--query',"[?principalId=='$($a.Assignee)' && contains(roleDefinitionId, '$($a.RoleDefinitionId)')] | [0].id",'-o','tsv')
                    if ($existing) {
                        Write-Host "  [OK] $($a.Role) already assigned" -ForegroundColor Gray
                    } else {
                        Invoke-AzCliSilent -Arguments @('cosmosdb','sql','role','assignment','create','--account-name',$a.AccountName,'--resource-group',$a.ResourceGroup,'--role-definition-id',$a.RoleDefinitionId,'--principal-id',$a.Assignee,'--scope',$a.Scope,'--output','none') | Out-Null
                        Write-Host "  [SUCCESS] Granted $($a.Role)" -ForegroundColor Green
                        $granted++
                    }
                    continue
                }
                if (-not $a.Scope) { continue }
                $existing = Get-AzValue @('role','assignment','list','--assignee',$a.Assignee,'--role',$a.Role,'--scope',$a.Scope,'--query','[0].id','-o','tsv')
                if ($existing) {
                    Write-Host "  [OK] $($a.Role) already assigned" -ForegroundColor Gray
                } else {
                    Invoke-AzCliSilent -Arguments @('role','assignment','create','--assignee',$a.Assignee,'--role',$a.Role,'--scope',$a.Scope,'--output','none') | Out-Null
                    Write-Host "  [SUCCESS] Granted $($a.Role)" -ForegroundColor Green
                    $granted++
                }
            }
            if ($granted -gt 0) { $changes += $granted }
        }
        Write-Host "  [INFO] RBAC propagation may take up to 5 minutes." -ForegroundColor Cyan
    } else {
        Write-Host "  [INFO] REMOVING local testing access and locking resources down" -ForegroundColor Cyan

        # Remove the laptop IP firewall rules and fully disable public access.
        if ($MyPublicIp) {
            Invoke-AzCliSilent -Arguments @('storage','account','network-rule','remove','--account-name',$StorageAccountName,'--resource-group',$ResourceGroupName,'--ip-address',$MyPublicIp,'--output','none') | Out-Null
            Invoke-AzCliSilent -Arguments @('keyvault','network-rule','remove','--name',$KeyVaultName,'--resource-group',$ResourceGroupName,'--ip-address',$MyPublicIp,'--output','none') | Out-Null
        }
        # Storage stays Enabled+Deny (Option A): the Content Understanding
        # resource-instance rule must keep working, so we only drop the laptop IP
        # and re-assert deny-by-default rather than disabling public access.
        Invoke-AzCliSilent -Arguments @('storage','account','update','--name',$StorageAccountName,'--resource-group',$ResourceGroupName,'--public-network-access','Enabled','--default-action','Deny','--bypass','AzureServices','--output','none') | Out-Null
        Invoke-AzCliSilent -Arguments @('keyvault','update','--name',$KeyVaultName,'--resource-group',$ResourceGroupName,'--public-network-access','Disabled','--output','none') | Out-Null
        Invoke-AzCliSilent -Arguments @('cosmosdb','update','--name',$CosmosDbAccountName,'--resource-group',$ResourceGroupName,'--public-network-access','Disabled','--ip-range-filter','','--output','none') | Out-Null
        Write-Host "  [SUCCESS] Public firewall holes closed (Storage stays deny-by-default for trusted CU; Key Vault, Cosmos DB disabled)" -ForegroundColor Green

        # Remove the signed-in user's data-plane RBAC.
        $removed = 0
        foreach ($a in $roleAssignments) {
            if ($a.Type -eq 'cosmos') {
                $existing = Get-AzValue @('cosmosdb','sql','role','assignment','list','--account-name',$a.AccountName,'--resource-group',$a.ResourceGroup,'--query',"[?principalId=='$($a.Assignee)' && contains(roleDefinitionId, '$($a.RoleDefinitionId)')] | [0].id",'-o','tsv')
                if ($existing) {
                    Invoke-AzCliSilent -Arguments @('cosmosdb','sql','role','assignment','delete','--account-name',$a.AccountName,'--resource-group',$a.ResourceGroup,'--role-assignment-id',$existing,'--yes','--output','none') | Out-Null
                    Write-Host "  [SUCCESS] Removed $($a.Role)" -ForegroundColor Green
                    $removed++
                } else {
                    Write-Host "  [OK] $($a.Role) not assigned" -ForegroundColor Gray
                }
                continue
            }
            if (-not $a.Scope) { continue }
            $existing = Get-AzValue @('role','assignment','list','--assignee',$a.Assignee,'--role',$a.Role,'--scope',$a.Scope,'--query','[0].id','-o','tsv')
            if ($existing) {
                Invoke-AzCliSilent -Arguments @('role','assignment','delete','--assignee',$a.Assignee,'--role',$a.Role,'--scope',$a.Scope,'--output','none') | Out-Null
                Write-Host "  [SUCCESS] Removed $($a.Role)" -ForegroundColor Green
                $removed++
            } else {
                Write-Host "  [OK] $($a.Role) not assigned" -ForegroundColor Gray
            }
        }
        if ($removed -gt 0) { $changes += $removed }
    }
}

# =============================================================================
# STEP 7: Refresh Key Vault App Setting References
# =============================================================================
# After Key Vault public access is disabled, the App Service / Functions
# platform must re-resolve its @Microsoft.KeyVault(...) app settings over the
# private endpoint. This kicks off that refresh and waits until they resolve.
if ($skipStep7) {
    Write-Host ""
    Write-Host ">>> Step 7: Refresh Key Vault App Setting References" -ForegroundColor White
    Write-Host "  [SKIPPED] Step 7 skipped by -SkipSteps" -ForegroundColor Yellow
} else {
    Write-Host ""
    Write-Host ">>> Step 7: Refresh Key Vault App Setting References" -ForegroundColor White

    # Readiness gate: ensure private endpoints are provisioned, approved, and the
    # Key Vault private DNS record exists before triggering the refresh. This
    # avoids resolving KV references over the now-disabled public endpoint.
    if (-not $skipStep3) {
        Wait-PrivateEndpointsReady -Endpoints $peDefs -ResourceGroup $ResourceGroupName | Out-Null
    } else {
        Write-Host "  [INFO] Step 3 was skipped; not waiting on private endpoints." -ForegroundColor Cyan
    }

    $servicesWithKvRefs = @(
        @{ Type = 'functionapp'; Name = $FuncMailboxName },
        @{ Type = 'functionapp'; Name = $FuncQueueDbName },
        @{ Type = 'functionapp'; Name = $FuncCuQueueDbName },
        @{ Type = 'webapp';      Name = $WebAppName }
    )

    foreach ($svc in $servicesWithKvRefs) {
        $resourceId = Get-AzValue @($svc.Type,'show','--name',$svc.Name,'--resource-group',$ResourceGroupName,'--query','id','-o','tsv')
        if (-not $resourceId) {
            Write-Host "  [WARNING] Could not find $($svc.Type) '$($svc.Name)'; skipping Key Vault reference refresh" -ForegroundColor Yellow
            continue
        }
        Invoke-ConfigReferenceRefresh -ResourceId $resourceId -DisplayName $svc.Name | Out-Null
    }
}

# =============================================================================
# SUMMARY
# =============================================================================
Write-Host ""
if ($changes -gt 0) {
    Write-Host "[SUCCESS] Production hardening applied. $changes change(s) made." -ForegroundColor Green
} else {
    Write-Host "[SUCCESS] Production hardening already in place. No changes needed." -ForegroundColor Green
}
Write-Host ""
Write-Host "  VNet            : $VnetName ($VnetAddressSpace)" -ForegroundColor White
Write-Host "    - $SubnetPe ($SubnetPeCidr) : private endpoints" -ForegroundColor White
Write-Host "    - $SubnetAppService ($SubnetAppServiceCidr) : Web App integration" -ForegroundColor White
Write-Host "    - $SubnetFunctions ($SubnetFunctionsCidr) : Function App integration" -ForegroundColor White
Write-Host "  Private (PE)    : Storage(blob/queue/table), Cosmos DB, Key Vault, AI Foundry, Content Understanding" -ForegroundColor White
if ($ServiceBusId -and $ServiceBusSupportsPrivate) {
    Write-Host "                    Service Bus (Premium)" -ForegroundColor White
} elseif ($ServiceBusId) {
    Write-Host "  Service Bus     : $ServiceBusNamespace ($ServiceBusSku) - NOT privatized (needs Premium)" -ForegroundColor Yellow
}
Write-Host "  Functions       : VNet-integrated, public inbound disabled, outbound to Graph allowed" -ForegroundColor White
Write-Host "  Web App         : VNet-integrated outbound; public UI inbound retained" -ForegroundColor White
Write-Host "  KV references   : refreshed on Web App + Function Apps" -ForegroundColor White
Write-Host ""

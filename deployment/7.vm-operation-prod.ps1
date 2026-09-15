#Requires -Version 5.1
<##
.SYNOPSIS
    Creates a private Windows 11 administration/development VM for EIA.

.DESCRIPTION
    Creates an Azure VM in the existing EIA resource group with its own VNet,
    peers it with the EIA and agent-service VNets, adds Azure Bastion for RDP,
    and installs the local development/deployment toolchain.

    The VM has no public IP and no public RDP rule. Azure Bastion is the only
    inbound access path. A NAT Gateway provides outbound internet access for
    Windows Update, browsers, GitHub, Azure CLI, and package installation.

    Private DNS links are added for existing EIA private DNS zones. Private
    endpoints for the three EIA Function Apps are created in the VM VNet so
    their SCM/OneDeploy endpoints remain reachable after production hardening.

    Run from the repository root after 1.deploy-infrastructure.ps1 and, for
    hardened environments, 6.operation-prod.ps1.

.EXAMPLE
    .\deployment\7.vm-operation-prod.ps1 -Environment ins -Suffix 1

.EXAMPLE
    .\deployment\7.vm-operation-prod.ps1 -Environment ins -Suffix 1 -ReadOnly

.EXAMPLE
    .\deployment\7.vm-operation-prod.ps1 -Environment ins -Suffix 1 -VmSize Standard_D2s_v5

.EXAMPLE
    .\deployment\7.vm-operation-prod.ps1 -Environment ins -Suffix 1 -AdminPassword 'your-password'

.PARAMETER AdminPassword
    Optional VM administrator password. Supplying it skips the confirmation
    prompts; command-line passwords can be exposed in shell history or process
    inspection, so interactive entry is safer.
#>
param(
    [string]$Environment = 'ins',
    [string]$Suffix = '1',
    [string]$ProjectName = 'eia',
    [string]$VmName,
    [string]$VmSize,
    [string]$Image = 'MicrosoftWindowsDesktop:windows-11:win11-24h2-pro:latest',
    [string]$AdminUsername,
    [string]$AdminPassword,
    [switch]$GrantContributor,
    [switch]$ReadOnly,
    [switch]$SkipFunctionPrivateEndpoints
)

$ErrorActionPreference = 'Stop'
$ResourceGroupName = "rg-$ProjectName-$Environment-$Suffix"
if ([string]::IsNullOrWhiteSpace($VmName)) { $VmName = "vm-$ProjectName-$Environment-$Suffix" }
$BastionName = "bas-$ProjectName-$Environment-$Suffix"

do {
    Write-Host 'Select operation:' -ForegroundColor Cyan
    Write-Host '  1. RDP to VM' -ForegroundColor White
    Write-Host '  2. Deploy VM' -ForegroundColor White
    $operation = Read-Host 'Enter 1 or 2 [default: 1]'
    if ([string]::IsNullOrWhiteSpace($operation)) { $operation = '1' }
    if ($operation -notin @('1','2')) { Write-Host 'Enter 1 or 2.' -ForegroundColor Yellow }
} until ($operation -in @('1','2'))

if ($operation -eq '1') {
    if ([string]::IsNullOrWhiteSpace($AdminUsername)) {
        $AdminUsername = (Read-Host 'Enter the VM administrator username [default: eiaadmin]').Trim()
        if ([string]::IsNullOrWhiteSpace($AdminUsername)) { $AdminUsername = 'eiaadmin' }
    }
    if ([string]::IsNullOrWhiteSpace($AdminPassword)) {
        $AdminPassword = Read-Host 'Enter the VM administrator password' -AsSecureString
        $passwordBstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($AdminPassword)
        try { $AdminPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordBstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordBstr) }
    }
    Write-Host "[INFO] Preparing RDP connection to $VmName through Bastion $BastionName..." -ForegroundColor Cyan
    $vmState = ((& az vm get-instance-view --name $VmName --resource-group $ResourceGroupName --query "instanceView.statuses[?starts_with(code, 'PowerState/')].code | [0]" --output tsv 2>$null) -join '').Trim()
    if ($vmState -in @('PowerState/stopped','PowerState/deallocated')) {
        Write-Host "[INFO] VM is $($vmState.Split('/')[1]); starting it..." -ForegroundColor Cyan
        & az vm start --name $VmName --resource-group $ResourceGroupName --output none
        if ($LASTEXITCODE -ne 0) { throw 'Failed to start the VM.' }
    } elseif ($vmState -ne 'PowerState/running') {
        throw "VM '$VmName' is not ready for RDP (state: '$vmState')."
    }

    $elapsed = 0
    do {
        $vmState = ((& az vm get-instance-view --name $VmName --resource-group $ResourceGroupName --query "instanceView.statuses[?starts_with(code, 'PowerState/')].code | [0]" --output tsv 2>$null) -join '').Trim()
        if ($vmState -ne 'PowerState/running') {
            Write-Host "  Waiting for VM to run: $vmState" -ForegroundColor DarkCyan
            Start-Sleep -Seconds 10
            $elapsed += 10
        }
    } while ($vmState -ne 'PowerState/running' -and $elapsed -lt 300)
    if ($vmState -ne 'PowerState/running') { throw "Timed out waiting for VM '$VmName' to reach running state." }

    $vmId = ((& az vm show --name $VmName --resource-group $ResourceGroupName --query id --output tsv 2>$null) -join '').Trim()
    if (-not $vmId) { throw "Could not find VM '$VmName'." }
    $localRdpPort = $null
    $credentialTarget = $null
    Write-Host '[INFO] Opening a local Bastion tunnel and launching the native Windows Remote Desktop client.' -ForegroundColor Cyan
    Write-Host '[INFO] Credentials will be removed from Windows Credential Manager when the RDP client closes.' -ForegroundColor DarkCyan
    $tunnel = $null
    $tunnelStdOut = $null
    $tunnelStdErr = $null
    try {
        for ($candidatePort = 55000; $candidatePort -le 55020 -and -not $tunnel; $candidatePort++) {
            $portInUse = @(Get-NetTCPConnection -LocalPort $candidatePort -ErrorAction SilentlyContinue).Count -gt 0
            if ($portInUse) { continue }
            $localRdpPort = $candidatePort
            $credentialTargets = @(
                "TERMSRV/127.0.0.1:$localRdpPort",
                "TERMSRV/localhost:$localRdpPort",
                'TERMSRV/127.0.0.1',
                'TERMSRV/localhost'
            )
            foreach ($credentialTarget in $credentialTargets) {
                & cmdkey.exe "/generic:$credentialTarget" "/user:$AdminUsername" "/pass:$AdminPassword" | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "Failed to store temporary RDP credentials for $credentialTarget." }
            }

            $tunnelArgs = @('network','bastion','tunnel','--name',$BastionName,'--resource-group',$ResourceGroupName,
                '--target-resource-id',$vmId,'--resource-port','3389','--port',$localRdpPort)
            $tunnelStdOut = Join-Path $env:TEMP "eia-bastion-tunnel-$localRdpPort.out.log"
            $tunnelStdErr = Join-Path $env:TEMP "eia-bastion-tunnel-$localRdpPort.err.log"
            Remove-Item $tunnelStdOut,$tunnelStdErr -Force -ErrorAction SilentlyContinue
            $candidateTunnel = Start-Process -FilePath 'az.cmd' -ArgumentList $tunnelArgs -PassThru -WindowStyle Hidden -RedirectStandardOutput $tunnelStdOut -RedirectStandardError $tunnelStdErr
            for ($attempt = 1; $attempt -le 30; $attempt++) {
                if ($candidateTunnel.HasExited) { break }
                $portOpen = Test-NetConnection -ComputerName '127.0.0.1' -Port $localRdpPort -InformationLevel Quiet -WarningAction SilentlyContinue
                if ($portOpen) { $tunnel = $candidateTunnel; break }
                Write-Host "  Waiting for Bastion tunnel on localhost:$localRdpPort ($attempt/30)..." -ForegroundColor DarkCyan
                Start-Sleep -Seconds 2
            }
            if (-not $tunnel) {
                $tunnelError = if (Test-Path $tunnelStdErr) { (Get-Content $tunnelStdErr -Raw).Trim() } else { '' }
                if ($candidateTunnel -and -not $candidateTunnel.HasExited) { Stop-Process -Id $candidateTunnel.Id -Force -ErrorAction SilentlyContinue }
                foreach ($credentialTarget in $credentialTargets) { & cmdkey.exe "/delete:$credentialTarget" | Out-Null }
                if ($tunnelError -notmatch '10013|forbidden by its access permissions') {
                    if ($tunnelError) { Write-Host $tunnelError -ForegroundColor Red }
                    throw "Bastion tunnel did not open localhost:$localRdpPort."
                }
                Write-Host "  Port $localRdpPort is unavailable; trying another local port." -ForegroundColor Yellow
            }
        }
        if (-not $tunnel) {
            throw 'Could not open a local Bastion tunnel on ports 55000-55020. Check local firewall, VPN, or excluded TCP ports.'
        }
        Write-Host "[INFO] Bastion tunnel is ready on localhost:$localRdpPort." -ForegroundColor Green
        $rdpFile = Join-Path $env:TEMP "eia-bastion-$localRdpPort.rdp"
        @(
            "full address:s:127.0.0.1:$localRdpPort",
            "username:s:$AdminUsername",
            'prompt for credentials:i:0'
        ) | Set-Content -Path $rdpFile -Encoding ASCII
        $rdpClient = Start-Process -FilePath 'mstsc.exe' -ArgumentList $rdpFile -PassThru
        $rdpClient.WaitForExit()
    } finally {
        foreach ($credentialTarget in @($credentialTargets)) { & cmdkey.exe "/delete:$credentialTarget" | Out-Null }
        if ($tunnel -and -not $tunnel.HasExited) { Stop-Process -Id $tunnel.Id -Force -ErrorAction SilentlyContinue }
        if ($rdpFile) { Remove-Item $rdpFile -Force -ErrorAction SilentlyContinue }
        Remove-Item $tunnelStdOut,$tunnelStdErr -Force -ErrorAction SilentlyContinue
    }
    exit 0
}

$AdminUsername = if ([string]::IsNullOrWhiteSpace($AdminUsername)) { 'eiaadmin' } else { $AdminUsername.Trim() }
$GrantContributor = -not $ReadOnly
$VmSizeWasSpecified = $PSBoundParameters.ContainsKey('VmSize') -and -not [string]::IsNullOrWhiteSpace($VmSize)
$Location = ((& az group show --name $ResourceGroupName --query location --output tsv 2>$null) -join '').Trim().ToLowerInvariant()
if ([string]::IsNullOrWhiteSpace($Location)) { throw "Resource group '$ResourceGroupName' was not found or its location could not be determined." }

$AdminVnetName = "vnet-admin-$ProjectName-$Environment-$Suffix"
$AdminVnetAddressSpace = '10.200.0.0/24'
$VmSubnetName = 'snet-vm'
$VmSubnetPrefix = '10.200.0.0/26'
$PrivateEndpointSubnetName = 'snet-private-endpoints'
$PrivateEndpointSubnetPrefix = '10.200.0.64/26'
$BastionSubnetName = 'AzureBastionSubnet'
$BastionSubnetPrefix = '10.200.0.128/26'
$VmNsgName = "nsg-$VmName"
$VmNicName = "nic-$VmName"
$NatName = "nat-$VmName"
$NatPublicIpName = "pip-$NatName"
$BastionPublicIpName = "pip-$BastionName"
$BastionNsgName = "nsg-$BastionName"
$MainVnetName = "vnet-$ProjectName-$Environment-$Suffix"
$AgentVnetName = "vnet-agentservice-$ProjectName-$Environment-$Suffix"
$PrivateDnsZoneName = 'privatelink.azurewebsites.net'
$FunctionApps = @(
    "func-mailbox-$ProjectName-$Environment-$Suffix",
    "func-queuedb-$ProjectName-$Environment-$Suffix",
    "func-cuqueuedb-$ProjectName-$Environment-$Suffix"
)
$StorageAccountName = "st$($ProjectName -replace '-','')$Environment$Suffix"
$CosmosAccountName = "cosmos-$ProjectName-$Environment-$Suffix"
$KeyVaultName = "kv-$ProjectName-$Environment-$Suffix"
$FoundryName = "oai-$ProjectName-$Environment-$Suffix"
$ContentUnderstandingName = "cu-$ProjectName-$Environment-$Suffix"
$SubscriptionId = ((& az account show --query id --output tsv 2>$null) -join '').Trim()
if (-not $SubscriptionId) { throw 'Azure CLI is not logged in. Run az login first.' }

function Invoke-Az {
    param([string[]]$Arguments)
    & az @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI command failed." }
}
function Invoke-AzWithProgress {
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [Parameter(Mandatory=$true)][string[]]$Arguments
    )
    Write-Host "[INFO] $Message This can take several minutes; please wait." -ForegroundColor Cyan
    $job = Start-Job -ScriptBlock {
        param([string[]]$CommandArguments)
        $output = (& az @CommandArguments 2>&1 | Out-String).Trim()
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
    } -ArgumentList (,$Arguments)
    Write-Host "  $Message " -NoNewline -ForegroundColor DarkCyan
    while ($job.State -in @('NotStarted','Running')) {
        Write-Host '.' -NoNewline -ForegroundColor DarkCyan
        Start-Sleep -Milliseconds 500
    }
    $result = Receive-Job -Job $job -Wait -AutoRemoveJob
    Write-Host ' done' -ForegroundColor Green
    if ($result.ExitCode -ne 0) {
        Write-Host $result.Output -ForegroundColor Red
        throw "Azure CLI command failed. See the error output above."
    }
}
function Read-PositiveInteger {
    param([string]$Prompt, [int]$Default)
    do {
        $value = Read-Host "$Prompt [$Default]"
        if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
        $parsed = 0
        $valid = [int]::TryParse($value, [ref]$parsed) -and $parsed -gt 0
        if (-not $valid) { Write-Host 'Enter a positive whole number, or press Enter for the default.' -ForegroundColor Yellow }
    } until ($valid)
    return $parsed
}

function Get-VmHourlyPrice {
    param([string]$SkuName)
    try {
        $filter = "serviceName eq 'Virtual Machines' and armRegionName eq '$Location' and armSkuName eq '$SkuName' and priceType eq 'Consumption'"
        $uri = 'https://prices.azure.com/api/retail/prices?$filter=' + [Uri]::EscapeDataString($filter)
        $items = @((Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 15).Items)
        $windows = @($items | Where-Object { $_.unitOfMeasure -match 'Hour' -and $_.productName -match 'Windows' } | Sort-Object retailPrice)
        if ($windows.Count -gt 0) { return ('${0:N4}/hr' -f [double]$windows[0].retailPrice) }
    } catch { }
    return 'n/a'
}

function Get-AvailableVmSizes {
    $requestedCores = Read-PositiveInteger -Prompt 'Number of vCPUs' -Default 4
    $requestedMemory = Read-PositiveInteger -Prompt 'Memory in GB' -Default 16
    Write-Host "[INFO] Querying Standard VM sizes available to this subscription in $Location. This can take a minute or two." -ForegroundColor Cyan
    $job = Start-Job -ScriptBlock {
        param([string]$Region)
        $output = (& az vm list-skus --location $Region --resource-type virtualMachines --all --output json 2>&1 | Out-String).Trim()
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
    } -ArgumentList $Location
    Write-Host '  Querying VM SKU catalog ' -NoNewline -ForegroundColor DarkCyan
    $elapsed = 0
    while ($job.State -in @('NotStarted','Running') -and $elapsed -lt 180) {
        Write-Host '.' -NoNewline -ForegroundColor DarkCyan
        Start-Sleep -Seconds 2
        $elapsed += 2
    }
    if ($job.State -in @('NotStarted','Running')) {
        Stop-Job -Job $job -ErrorAction SilentlyContinue
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        throw "Timed out querying VM sizes in $Location. Rerun with -VmSize <SKU> to bypass selection."
    }
    $result = Receive-Job -Job $job -Wait -AutoRemoveJob
    if ($result.ExitCode -ne 0) { throw "Could not query VM sizes in $Location. Rerun with -VmSize <SKU> to bypass selection." }
    try { $catalog = @($result.Output | ConvertFrom-Json) } catch { throw "Azure returned invalid VM SKU data for $Location." }

    $available = @($catalog | Where-Object {
        $cores = [int](($_.capabilities | Where-Object name -eq 'vCPUs').value)
        $memory = [double](($_.capabilities | Where-Object name -eq 'MemoryGB').value)
        $_.name -like 'Standard_*' -and $_.resourceType -eq 'virtualMachines' -and
        @($_.restrictions).Count -eq 0 -and $cores -ge $requestedCores -and $memory -ge $requestedMemory
    } | ForEach-Object {
        $cores = [int](($_.capabilities | Where-Object name -eq 'vCPUs').value)
        $memory = [double](($_.capabilities | Where-Object name -eq 'MemoryGB').value)
        $generationText = ($_.capabilities | Where-Object name -eq 'HyperVGenerations').value
        $generationMatches = [regex]::Matches([string]$generationText, 'V(\d+)')
        $generation = if ($generationMatches.Count -gt 0) {
            ($generationMatches | ForEach-Object { [int]$_.Groups[1].Value } | Measure-Object -Maximum).Maximum
        } else { 0 }
        [pscustomobject]@{ Name=$_.name; Cores=$cores; Memory=$memory; Generation=$generation; GenerationText=$generationText }
    } | Sort-Object @{ Expression = { $_.Generation }; Descending = $true }, @{ Expression = { $_.Cores } }, Name)
    if ($available.Count -eq 0) { throw "No unrestricted Standard VM sizes meet at least $requestedCores vCPUs and ${requestedMemory} GB in $Location." }

    $pageSize = 10
    $page = 0
    while ($true) {
        $start = $page * $pageSize
        $pageItems = @($available | Select-Object -Skip $start -First $pageSize)
        Write-Host ''
        Write-Host "Standard VM sizes meeting ${requestedCores} vCPU / ${requestedMemory} GB (page $($page + 1))" -ForegroundColor Cyan
        for ($index = 0; $index -lt $pageItems.Count; $index++) {
            $sku = $pageItems[$index]
            $price = Get-VmHourlyPrice -SkuName $sku.Name
            Write-Host ("  {0,2}. {1,-28} {2,2} vCPU  {3,6} GB  Gen V{4}  {5}" -f ($index + 1),$sku.Name,$sku.Cores,$sku.Memory,$sku.Generation,$price) -ForegroundColor White
        }
        $hasMore = ($start + $pageSize) -lt $available.Count
        if ($hasMore) {
            $next = Read-Host 'Select (1-10), or press Enter to show more'
            if ([string]::IsNullOrWhiteSpace($next)) { $page++; continue }
        } else {
            $next = Read-Host 'Select (1-10), or press Enter to return to the previous page'
            if ([string]::IsNullOrWhiteSpace($next) -and $page -gt 0) { $page--; continue }
        }
        $selectedIndex = 0
        $valid = [int]::TryParse($next, [ref]$selectedIndex) -and $selectedIndex -ge 1 -and $selectedIndex -le $pageItems.Count
        if ($valid) { return $pageItems[$selectedIndex - 1].Name }
        Write-Host 'Enter a displayed number, or press Enter for more results.' -ForegroundColor Yellow
    }
}
function Get-AzValue {
    param([string[]]$Arguments)
    $value = & az @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) { return '' }
    return (($value -join '')).Trim()
}
function Test-AzResource {
    param([string[]]$Arguments)
    return -not [string]::IsNullOrWhiteSpace((Get-AzValue $Arguments))
}
function Test-DnsZoneGroup {
    param([string]$EndpointName, [string]$ZoneGroupName)
    $arguments = @('network','private-endpoint','dns-zone-group','show','--endpoint-name',$EndpointName,
        '--name',$ZoneGroupName,'--resource-group',$ResourceGroupName,'--query','name','-o','tsv')
    Write-Host "  [INFO] Querying Azure for DNS zone group '$ZoneGroupName' " -NoNewline -ForegroundColor DarkCyan
    $job = Start-Job -ScriptBlock {
        param([string[]]$CommandArguments)
        $output = (& az @CommandArguments 2>$null | Out-String).Trim()
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
    } -ArgumentList (,$arguments)
    $elapsed = 0
    while ($job.State -in @('NotStarted','Running') -and $elapsed -lt 120) {
        Write-Host '.' -NoNewline -ForegroundColor DarkCyan
        Start-Sleep -Seconds 2
        $elapsed += 2
    }
    if ($job.State -in @('NotStarted','Running')) {
        Stop-Job -Job $job -ErrorAction SilentlyContinue
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        Write-Host ' timeout' -ForegroundColor Yellow
        return $false
    }
    $result = Receive-Job -Job $job -Wait -AutoRemoveJob
    if ($result.ExitCode -eq 0 -and $result.Output) {
        Write-Host ' found' -ForegroundColor Green
        return $true
    }
    Write-Host ' not found' -ForegroundColor Gray
    return $false
}
function Test-DnsLink {
    param([string]$ZoneName, [string]$LinkName)
    $arguments = @('network','private-dns','link','vnet','show','--name',$LinkName,
        '--zone-name',$ZoneName,'--resource-group',$ResourceGroupName,'--query','name','-o','tsv')
    Write-Host "  [INFO] Checking DNS link '$LinkName' for '$ZoneName' " -NoNewline -ForegroundColor DarkCyan
    $job = Start-Job -ScriptBlock {
        param([string[]]$CommandArguments)
        $output = (& az @CommandArguments 2>$null | Out-String).Trim()
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
    } -ArgumentList (,$arguments)
    $elapsed = 0
    while ($job.State -in @('NotStarted','Running') -and $elapsed -lt 120) {
        Write-Host '.' -NoNewline -ForegroundColor DarkCyan
        Start-Sleep -Seconds 2
        $elapsed += 2
    }
    if ($job.State -in @('NotStarted','Running')) {
        Stop-Job -Job $job -ErrorAction SilentlyContinue
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        Write-Host ' timeout' -ForegroundColor Yellow
        return $false
    }
    $result = Receive-Job -Job $job -Wait -AutoRemoveJob
    if ($result.ExitCode -eq 0 -and $result.Output) {
        Write-Host ' already linked' -ForegroundColor Gray
        return $true
    }
    Write-Host ' not linked' -ForegroundColor Gray
    return $false
}
function Test-ResourceWithProgress {
    param([string]$Label, [string[]]$Arguments)
    Write-Host "  [INFO] Checking $Label " -NoNewline -ForegroundColor DarkCyan
    $job = Start-Job -ScriptBlock {
        param([string[]]$CommandArguments)
        $output = (& az @CommandArguments 2>$null | Out-String).Trim()
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
    } -ArgumentList (,$Arguments)
    $elapsed = 0
    while ($job.State -in @('NotStarted','Running') -and $elapsed -lt 120) {
        Write-Host '.' -NoNewline -ForegroundColor DarkCyan
        Start-Sleep -Seconds 2
        $elapsed += 2
    }
    if ($job.State -in @('NotStarted','Running')) {
        Stop-Job -Job $job -ErrorAction SilentlyContinue
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        Write-Host ' timeout' -ForegroundColor Yellow
        return $false
    }
    $result = Receive-Job -Job $job -Wait -AutoRemoveJob
    if ($result.ExitCode -eq 0 -and $result.Output) {
        Write-Host ' exists' -ForegroundColor Gray
        return $true
    }
    Write-Host ' not found' -ForegroundColor Gray
    return $false
}
function Ensure-NetworkPublicIpFeature {
    $featureState = Get-AzValue @('feature','show','--namespace','Microsoft.Network','--name','AllowBringYourOwnPublicIpAddress','--query','properties.state','-o','tsv')
    if ($featureState -eq 'Registered') {
        return
    }

    Write-Host "[INFO] Registering Microsoft.Network/AllowBringYourOwnPublicIpAddress (current state: $featureState)" -ForegroundColor Cyan
    & az feature register --namespace Microsoft.Network --name AllowBringYourOwnPublicIpAddress --output none
    if ($LASTEXITCODE -ne 0) {
        throw "Could not register Microsoft.Network/AllowBringYourOwnPublicIpAddress. Run: az feature register --namespace Microsoft.Network --name AllowBringYourOwnPublicIpAddress"
    }
    & az provider register --namespace Microsoft.Network --wait --output none
    if ($LASTEXITCODE -ne 0) {
        throw 'Microsoft.Network provider registration failed. Run: az provider register --namespace Microsoft.Network --wait'
    }

    for ($attempt = 1; $attempt -le 30; $attempt++) {
        $featureState = Get-AzValue @('feature','show','--namespace','Microsoft.Network','--name','AllowBringYourOwnPublicIpAddress','--query','properties.state','-o','tsv')
        if ($featureState -eq 'Registered') { return }
        if ($featureState -eq 'NotRegistered' -or $featureState -eq 'Unregistered') {
            throw "Azure did not register Microsoft.Network/AllowBringYourOwnPublicIpAddress. If the feature requires approval, open an Azure support request, then rerun this script."
        }
        Write-Host "[INFO] Waiting for Network feature registration (attempt $attempt/30; state: $featureState)" -ForegroundColor Cyan
        Start-Sleep -Seconds 10
    }
    throw "Timed out waiting for Microsoft.Network/AllowBringYourOwnPublicIpAddress to become Registered. Check: az feature show --namespace Microsoft.Network --name AllowBringYourOwnPublicIpAddress -o table"
}
function Ensure-Role {
    param([string]$PrincipalId, [string]$Role, [string]$Scope)
    if (-not $PrincipalId -or -not $Scope) { return }
    $existing = Get-AzValue @('role','assignment','list','--assignee',$PrincipalId,'--role',$Role,'--scope',$Scope,'--query','[0].id','-o','tsv')
    if ($existing) { Write-Host "[OK] $Role already assigned" -ForegroundColor Gray; return }
    Invoke-Az @('role','assignment','create','--assignee-object-id',$PrincipalId,'--assignee-principal-type','ServicePrincipal','--role',$Role,'--scope',$Scope,'--output','none')
    Write-Host "[OK] Granted $Role" -ForegroundColor Green
}
function Ensure-Peering {
    param([string]$LocalVnet, [string]$LocalPeering, [string]$RemoteVnetId)
    if (Test-AzResource @('network','vnet','peering','show','--name',$LocalPeering,'--vnet-name',$LocalVnet,'--resource-group',$ResourceGroupName,'--query','name','-o','tsv')) {
        Write-Host "[OK] VNet peering '$LocalPeering' already exists" -ForegroundColor Gray
        return
    }
    Invoke-Az @('network','vnet','peering','create','--name',$LocalPeering,'--vnet-name',$LocalVnet,'--resource-group',$ResourceGroupName,
        '--remote-vnet',$RemoteVnetId,'--allow-vnet-access','--allow-forwarded-traffic','--output','none')
    Write-Host "[OK] Created VNet peering '$LocalPeering'" -ForegroundColor Green
}
function Ensure-DnsLink {
    param([string]$ZoneName)
    if (-not (Test-AzResource @('network','private-dns','zone','show','--name',$ZoneName,'--resource-group',$ResourceGroupName,'--query','name','-o','tsv'))) {
        Write-Host "[WARN] Private DNS zone '$ZoneName' does not exist; skipping link" -ForegroundColor Yellow
        return
    }
    $linkName = "link-$AdminVnetName-$($ZoneName -replace '[^a-zA-Z0-9]','-')"
    if (Test-DnsLink -ZoneName $ZoneName -LinkName $linkName) {
        return
    }
    Write-Host "  [INFO] Creating DNS link '$linkName' for '$ZoneName'" -ForegroundColor Cyan
    Invoke-Az @('network','private-dns','link','vnet','create','--name',$linkName,'--zone-name',$ZoneName,'--resource-group',$ResourceGroupName,
        '--virtual-network',$AdminVnetName,'--registration-enabled','false','--output','none')
    Write-Host "[OK] Linked DNS zone '$ZoneName' to $AdminVnetName" -ForegroundColor Green
}
function Read-ConfirmedPassword {
    $first = Read-Host 'Enter the local Windows administrator password' -AsSecureString
    $second = Read-Host 'Re-enter the password to confirm' -AsSecureString
    $firstBstr = [IntPtr]::Zero
    $secondBstr = [IntPtr]::Zero
    try {
        $firstBstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($first)
        $secondBstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($second)
        $firstText = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($firstBstr)
        $secondText = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($secondBstr)
        if ($firstText -cne $secondText) { throw 'The two password entries do not match. No Azure resources were changed.' }
        return $firstText
    } finally {
        if ($firstBstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($firstBstr) }
        if ($secondBstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($secondBstr) }
    }
}

Write-Host "[INFO] Resource group: $ResourceGroupName ($Location)" -ForegroundColor Cyan
Write-Host "[INFO] VM: $VmName ($VmSize)" -ForegroundColor Cyan
Write-Host "[INFO] Admin VNet: $AdminVnetName ($AdminVnetAddressSpace)" -ForegroundColor Cyan
if ($GrantContributor) { Write-Host '[INFO] VM managed identity will receive Contributor on the resource group.' -ForegroundColor Cyan }
else { Write-Host '[INFO] Read-only mode: VM managed identity will not receive Contributor.' -ForegroundColor Cyan }

if ([string]::IsNullOrWhiteSpace($AdminPassword)) {
    $AdminPassword = Read-ConfirmedPassword
}
if ($AdminPassword.Length -lt 12) { throw 'AdminPassword must be at least 12 characters.' }

$mainVnetId = Get-AzValue @('network','vnet','show','--name',$MainVnetName,'--resource-group',$ResourceGroupName,'--query','id','-o','tsv')
$agentVnetId = Get-AzValue @('network','vnet','show','--name',$AgentVnetName,'--resource-group',$ResourceGroupName,'--query','id','-o','tsv')
if (-not $mainVnetId -or -not $agentVnetId) { throw "Expected EIA VNets '$MainVnetName' and '$AgentVnetName' were not found." }
Ensure-NetworkPublicIpFeature

if (-not (Test-AzResource @('network','vnet','show','--name',$AdminVnetName,'--resource-group',$ResourceGroupName,'--query','name','-o','tsv'))) {
    Invoke-Az @('network','vnet','create','--name',$AdminVnetName,'--resource-group',$ResourceGroupName,'--location',$Location,'--address-prefixes',$AdminVnetAddressSpace,
        '--subnet-name',$VmSubnetName,'--subnet-prefixes',$VmSubnetPrefix,'--tags',"project=$ProjectName","environment=$Environment",'purpose=admin-development','--output','none')
}
if (-not (Test-AzResource @('network','vnet','subnet','show','--name',$PrivateEndpointSubnetName,'--vnet-name',$AdminVnetName,'--resource-group',$ResourceGroupName,'--query','name','-o','tsv'))) {
    Invoke-Az @('network','vnet','subnet','create','--name',$PrivateEndpointSubnetName,'--vnet-name',$AdminVnetName,'--resource-group',$ResourceGroupName,
        '--address-prefixes',$PrivateEndpointSubnetPrefix,'--private-endpoint-network-policies','Disabled','--output','none')
}
if (-not (Test-AzResource @('network','vnet','subnet','show','--name',$BastionSubnetName,'--vnet-name',$AdminVnetName,'--resource-group',$ResourceGroupName,'--query','name','-o','tsv'))) {
    Invoke-Az @('network','vnet','subnet','create','--name',$BastionSubnetName,'--vnet-name',$AdminVnetName,'--resource-group',$ResourceGroupName,'--address-prefixes',$BastionSubnetPrefix,'--output','none')
}

if (-not (Test-AzResource @('network','nsg','show','--name',$VmNsgName,'--resource-group',$ResourceGroupName,'--query','name','-o','tsv'))) {
    Invoke-Az @('network','nsg','create','--name',$VmNsgName,'--resource-group',$ResourceGroupName,'--location',$Location,'--output','none')
}
if (-not (Test-AzResource @('network','nsg','rule','show','--nsg-name',$VmNsgName,'--resource-group',$ResourceGroupName,'--name','Allow-Rdp-From-Bastion','--query','name','-o','tsv'))) {
    Invoke-Az @('network','nsg','rule','create','--nsg-name',$VmNsgName,'--resource-group',$ResourceGroupName,'--name','Allow-Rdp-From-Bastion',
        '--priority','100','--source-address-prefixes',$BastionSubnetPrefix,'--destination-port-ranges','3389','--access','Allow','--protocol','Tcp','--direction','Inbound','--output','none')
}
Invoke-Az @('network','vnet','subnet','update','--name',$VmSubnetName,'--vnet-name',$AdminVnetName,'--resource-group',$ResourceGroupName,'--network-security-group',$VmNsgName,'--output','none')

if (-not (Test-AzResource @('network','public-ip','show','--name',$NatPublicIpName,'--resource-group',$ResourceGroupName,'--query','name','-o','tsv'))) {
    Invoke-AzWithProgress -Message "Creating NAT public IP $NatPublicIpName" -Arguments @('network','public-ip','create','--name',$NatPublicIpName,'--resource-group',$ResourceGroupName,'--location',$Location,
        '--sku','Standard','--version','IPv4','--zone','1','--allocation-method','Static','--output','none')
}
if (-not (Test-AzResource @('network','nat','gateway','show','--name',$NatName,'--resource-group',$ResourceGroupName,'--query','name','-o','tsv'))) {
    Invoke-AzWithProgress -Message "Creating NAT gateway $NatName" -Arguments @('network','nat','gateway','create','--name',$NatName,'--resource-group',$ResourceGroupName,'--location',$Location,'--public-ip-addresses',$NatPublicIpName,'--idle-timeout','10','--output','none')
}
Invoke-Az @('network','vnet','subnet','update','--name',$VmSubnetName,'--vnet-name',$AdminVnetName,'--resource-group',$ResourceGroupName,'--nat-gateway',$NatName,'--output','none')

$vmSubnetId = Get-AzValue @('network','vnet','subnet','show','--name',$VmSubnetName,'--vnet-name',$AdminVnetName,'--resource-group',$ResourceGroupName,'--query','id','-o','tsv')
if (-not (Test-AzResource @('network','nic','show','--name',$VmNicName,'--resource-group',$ResourceGroupName,'--query','name','-o','tsv'))) {
    Invoke-Az @('network','nic','create','--name',$VmNicName,'--resource-group',$ResourceGroupName,'--location',$Location,'--subnet',$vmSubnetId,'--network-security-group',$VmNsgName,'--output','none')
}

Ensure-Peering -LocalVnet $AdminVnetName -LocalPeering "peer-$AdminVnetName-to-$MainVnetName" -RemoteVnetId $mainVnetId
Ensure-Peering -LocalVnet $AdminVnetName -LocalPeering "peer-$AdminVnetName-to-$AgentVnetName" -RemoteVnetId $agentVnetId
$adminVnetId = Get-AzValue @('network','vnet','show','--name',$AdminVnetName,'--resource-group',$ResourceGroupName,'--query','id','-o','tsv')
Ensure-Peering -LocalVnet $MainVnetName -LocalPeering "peer-$MainVnetName-to-$AdminVnetName" -RemoteVnetId $adminVnetId
Ensure-Peering -LocalVnet $AgentVnetName -LocalPeering "peer-$AgentVnetName-to-$AdminVnetName" -RemoteVnetId $adminVnetId

Write-Host '[INFO] Linking private DNS zones to the admin VNet. This can take several minutes.' -ForegroundColor Cyan
foreach ($zone in @(
    'privatelink.blob.core.windows.net','privatelink.queue.core.windows.net','privatelink.table.core.windows.net',
    'privatelink.documents.azure.com','privatelink.vaultcore.azure.net','privatelink.cognitiveservices.azure.com',
    'privatelink.openai.azure.com','privatelink.services.ai.azure.com','privatelink.servicebus.windows.net',
    'privatelink.azurewebsites.net')) { Ensure-DnsLink -ZoneName $zone }

if (-not $SkipFunctionPrivateEndpoints) {
    Write-Host '[INFO] Creating Function App private endpoints and DNS links. This can take several minutes.' -ForegroundColor Cyan
    foreach ($functionName in $FunctionApps) {
        Write-Host "  [INFO] Checking Function App '$functionName'" -ForegroundColor Cyan
        $functionId = Get-AzValue @('functionapp','show','--name',$functionName,'--resource-group',$ResourceGroupName,'--query','id','-o','tsv')
        if (-not $functionId) { Write-Host "[WARN] Function App '$functionName' not found; skipping private endpoint" -ForegroundColor Yellow; continue }
        $peName = "pe-adminvm-$($functionName -replace '^func-','')"
        Write-Host "  [INFO] Checking private endpoint '$peName'" -ForegroundColor Cyan
        if (-not (Test-AzResource @('network','private-endpoint','show','--name',$peName,'--resource-group',$ResourceGroupName,'--query','name','-o','tsv'))) {
            Invoke-AzWithProgress -Message "Creating private endpoint $peName" -Arguments @('network','private-endpoint','create','--name',$peName,'--resource-group',$ResourceGroupName,'--vnet-name',$AdminVnetName,
                '--subnet',$PrivateEndpointSubnetName,'--private-connection-resource-id',$functionId,'--group-id','sites',
                '--connection-name',"$peName-conn",'--location',$Location,'--output','none')
        }
        $zoneGroupName = "$peName-zg"
        Write-Host "  [INFO] Checking DNS zone group '$zoneGroupName'" -ForegroundColor Cyan
        if (-not (Test-DnsZoneGroup -EndpointName $peName -ZoneGroupName $zoneGroupName)) {
            $privateDnsZoneId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Network/privateDnsZones/$PrivateDnsZoneName"
            Invoke-AzWithProgress -Message "Linking private DNS for $peName" -Arguments @('network','private-endpoint','dns-zone-group','create','--name',$zoneGroupName,'--endpoint-name',$peName,'--resource-group',$ResourceGroupName,
                '--private-dns-zone',$privateDnsZoneId,'--zone-name',$PrivateDnsZoneName,'--output','none')
        }
    }
}

Write-Host '[INFO] Checking Bastion and VM resources. The next create operations may take several minutes.' -ForegroundColor Cyan
if (-not (Test-ResourceWithProgress -Label "Bastion public IP '$BastionPublicIpName'" -Arguments @('network','public-ip','show','--name',$BastionPublicIpName,'--resource-group',$ResourceGroupName,'--query','name','-o','tsv'))) {
    Invoke-AzWithProgress -Message "Creating Bastion public IP $BastionPublicIpName" -Arguments @('network','public-ip','create','--name',$BastionPublicIpName,'--resource-group',$ResourceGroupName,'--location',$Location,
        '--sku','Standard','--version','IPv4','--zone','1','--allocation-method','Static','--output','none')
}
if (-not (Test-ResourceWithProgress -Label "Bastion '$BastionName'" -Arguments @('network','bastion','show','--name',$BastionName,'--resource-group',$ResourceGroupName,'--query','name','-o','tsv'))) {
    Invoke-AzWithProgress -Message "Creating Azure Bastion $BastionName" -Arguments @('network','bastion','create','--name',$BastionName,'--resource-group',$ResourceGroupName,'--location',$Location,
        '--public-ip-address',$BastionPublicIpName,'--vnet-name',$AdminVnetName,'--sku','Standard','--enable-tunneling','true','--output','none')
}

 $vmExists = Test-ResourceWithProgress -Label "VM '$VmName'" -Arguments @('vm','show','--name',$VmName,'--resource-group',$ResourceGroupName,'--query','name','-o','tsv')
 if (-not $vmExists) {
     if (-not $VmSizeWasSpecified) {
          $VmSize = Get-AvailableVmSizes
          Write-Host "[INFO] Selected VM size: $VmSize" -ForegroundColor Cyan
     }
    Invoke-AzWithProgress -Message "Creating Windows VM $VmName" -Arguments @('vm','create','--name',$VmName,'--resource-group',$ResourceGroupName,'--location',$Location,'--image',$Image,'--size',$VmSize,
        '--admin-username',$AdminUsername,'--admin-password',$AdminPassword,'--nics',$VmNicName,'--os-disk-size-gb','128',
        '--security-type','TrustedLaunch','--enable-agent','true','--assign-identity','--license-type','Windows_Client',
        '--tags',"project=$ProjectName","environment=$Environment",'purpose=admin-development','--output','none')
} else { Write-Host "[OK] VM '$VmName' already exists" -ForegroundColor Gray }

$vmPrincipalId = Get-AzValue @('vm','show','--name',$VmName,'--resource-group',$ResourceGroupName,'--query','identity.principalId','-o','tsv')
$resourceGroupId = Get-AzValue @('group','show','--name',$ResourceGroupName,'--query','id','-o','tsv')
Ensure-Role -PrincipalId $vmPrincipalId -Role 'Reader' -Scope $resourceGroupId
if ($GrantContributor) { Ensure-Role -PrincipalId $vmPrincipalId -Role 'Contributor' -Scope $resourceGroupId }

$storageId = Get-AzValue @('storage','account','show','--name',$StorageAccountName,'--resource-group',$ResourceGroupName,'--query','id','-o','tsv')
$cosmosId = Get-AzValue @('cosmosdb','show','--name',$CosmosAccountName,'--resource-group',$ResourceGroupName,'--query','id','-o','tsv')
$keyVaultId = Get-AzValue @('keyvault','show','--name',$KeyVaultName,'--resource-group',$ResourceGroupName,'--query','id','-o','tsv')
Ensure-Role -PrincipalId $vmPrincipalId -Role 'Storage Blob Data Reader' -Scope $storageId
Ensure-Role -PrincipalId $vmPrincipalId -Role 'Storage Queue Data Reader' -Scope $storageId
Ensure-Role -PrincipalId $vmPrincipalId -Role 'Storage Table Data Reader' -Scope $storageId
Ensure-Role -PrincipalId $vmPrincipalId -Role 'Key Vault Secrets User' -Scope $keyVaultId
if ($cosmosId) {
    $cosmosReaderRoleId = '00000000-0000-0000-0000-000000000001'
    $existingCosmosRole = Get-AzValue @('cosmosdb','sql','role','assignment','list','--account-name',$CosmosAccountName,'--resource-group',$ResourceGroupName,'--query',"[?principalId=='$vmPrincipalId' && contains(roleDefinitionId, '$cosmosReaderRoleId')] | [0].id",'-o','tsv')
    if (-not $existingCosmosRole) { Invoke-Az @('cosmosdb','sql','role','assignment','create','--account-name',$CosmosAccountName,'--resource-group',$ResourceGroupName,'--role-definition-id',$cosmosReaderRoleId,'--principal-id',$vmPrincipalId,'--scope',$cosmosId,'--output','none') }
}

$bootstrap = @'
$ErrorActionPreference = 'Continue'
$packages = @(
    'Git.Git', 'GitHub.cli', 'Microsoft.AzureCLI', 'Microsoft.AzureDeveloperCLI',
  'Microsoft.PowerShell', 'Microsoft.VisualStudioCode',
  'EclipseAdoptium.Temurin.21.JDK', 'Apache.Maven', 'Microsoft.AzureStorageExplorer'
)
$winget = Get-Command winget.exe -ErrorAction SilentlyContinue
if ($winget) {
  foreach ($package in $packages) {
    winget install --id $package --exact --scope machine --silent --accept-package-agreements --accept-source-agreements
  }
}
$javaHome = Get-ChildItem 'C:\Program Files\Eclipse Adoptium' -Directory -Filter 'jdk-21*' -ErrorAction SilentlyContinue | Select-Object -First 1
$mavenHome = Get-ChildItem 'C:\Program Files\Apache Maven' -Directory -Filter 'apache-maven-*' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($javaHome) { [Environment]::SetEnvironmentVariable('JAVA_HOME', $javaHome.FullName, 'Machine') }
if ($mavenHome) { [Environment]::SetEnvironmentVariable('MAVEN_HOME', $mavenHome.FullName, 'Machine') }
$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
$extra = @('C:\Program Files\Git\cmd','C:\Program Files\GitHub CLI','C:\Program Files\Microsoft VS Code\bin','C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin')
[Environment]::SetEnvironmentVariable('Path', (($machinePath -split ';') + $extra | Select-Object -Unique) -join ';', 'Machine')
New-Item -ItemType Directory -Path 'C:\EIA' -Force | Out-Null
@"
EIA admin VM bootstrap completed.
Run `az login --identity` for VM managed identity access.
Run `gh auth login` to connect GitHub for the signed-in developer.
"@ | Set-Content 'C:\EIA\README.txt'
'@
$bootstrapPath = Join-Path $env:TEMP "$VmName-bootstrap.ps1"
$bootstrap | Set-Content -Path $bootstrapPath -Encoding UTF8
Invoke-AzWithProgress -Message "Installing VM development tools" -Arguments @('vm','run-command','invoke','--name',$VmName,'--resource-group',$ResourceGroupName,'--command-id','RunPowerShellScript','--scripts',"@$bootstrapPath",'--output','none')
Remove-Item $bootstrapPath -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host '[SUCCESS] Admin VM provisioning completed.' -ForegroundColor Green
Write-Host "  VM:       $VmName" -ForegroundColor White
Write-Host "  Bastion:  $BastionName" -ForegroundColor White
Write-Host "  RDP path: Azure portal -> $BastionName -> $VmName" -ForegroundColor White
Write-Host "  GitHub:   Run 'gh auth login' inside the VM." -ForegroundColor White
Write-Host "  Azure:    Run 'az login --identity' for VM identity access." -ForegroundColor White
if (-not $GrantContributor) { Write-Host "  Deploy:   Rerun without -ReadOnly if deployment scripts need resource-group Contributor." -ForegroundColor Yellow }
Write-Host '  Note:     Do not expose RDP publicly; connect through Bastion.' -ForegroundColor Yellow

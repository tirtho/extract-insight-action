#Requires -Version 5.1
<##
.SYNOPSIS
    Creates a Premium Service Bus namespace for an existing EIA deployment and
    switches the application configuration to it.

.DESCRIPTION
    Azure does not support upgrading a Standard Service Bus namespace to Premium
    in place. This script creates a replacement namespace, recreates the EIA
    topic/subscription, grants the existing Function App identities access,
    updates Key Vault and the queue-trigger Function App, and optionally deletes
    the old namespace.

    Azure CLI has no management-plane command to move messages between
    namespaces. Do not use -DeleteOld until the old subscription has no messages,
    or you have migrated them with a separate data-plane process.

.EXAMPLE
    .\migrate-servicebus-premium.ps1

.EXAMPLE
    .\migrate-servicebus-premium.ps1 -DeleteOld -AllowMessageLoss
#>
param(
    [string]$Environment = 'ins',
    [string]$Suffix = '1',
    [string]$ProjectName = 'eia',
    [string]$NewNamespace,
    [switch]$DeleteOld,
    [switch]$AllowMessageLoss
)

$ErrorActionPreference = 'Stop'
$ResourceGroupName = "rg-$ProjectName-$Environment-$Suffix"
$OldNamespace = "sb-$ProjectName-$Environment-$Suffix"
if ([string]::IsNullOrWhiteSpace($NewNamespace)) {
    $NewNamespace = "$OldNamespace-premium"
}
$TopicName = 'email-processing'
$SubscriptionName = 'email-processor'
$KeyVaultName = "kv-$ProjectName-$Environment-$Suffix"
$MailboxFunction = "func-mailbox-$ProjectName-$Environment-$Suffix"
$QueueDbFunction = "func-queuedb-$ProjectName-$Environment-$Suffix"
$CuQueueDbFunction = "func-cuqueuedb-$ProjectName-$Environment-$Suffix"
$WebAppName = "app-$ProjectName-$Environment-$Suffix"

function Invoke-Az {
    param([string[]]$Arguments)
    & az @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI command failed: az $($Arguments -join ' ')"
    }
}

function Get-AzValue {
    param([string[]]$Arguments)
    $value = & az @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) { return '' }
    return (($value -join '')).Trim()
}

function Ensure-Role {
    param([string]$PrincipalId, [string]$Role, [string]$Scope)
    if ([string]::IsNullOrWhiteSpace($PrincipalId)) { throw "Missing principal ID for role '$Role'." }
    $existing = Get-AzValue @('role','assignment','list','--assignee',$PrincipalId,'--role',$Role,'--scope',$Scope,'--query','[0].id','-o','tsv')
    if ($existing) {
        Write-Host "[OK] $Role already assigned to $PrincipalId" -ForegroundColor Gray
        return
    }
    Invoke-Az @('role','assignment','create','--assignee-object-id',$PrincipalId,
        '--assignee-principal-type','ServicePrincipal','--role',$Role,'--scope',$Scope,'--output','none')
    Write-Host "[OK] Granted $Role to $PrincipalId" -ForegroundColor Green
}

Write-Host "[INFO] Resource group: $ResourceGroupName" -ForegroundColor Cyan
Write-Host "[INFO] Old namespace:  $OldNamespace" -ForegroundColor Cyan
Write-Host "[INFO] New namespace:  $NewNamespace" -ForegroundColor Cyan

$oldId = Get-AzValue @('servicebus','namespace','show','--name',$OldNamespace,'--resource-group',$ResourceGroupName,'--query','id','-o','tsv')
if (-not $oldId) { throw "Old Service Bus namespace '$OldNamespace' was not found." }
$oldSku = Get-AzValue @('servicebus','namespace','show','--name',$OldNamespace,'--resource-group',$ResourceGroupName,'--query','sku.name','-o','tsv')
if ($oldSku -ne 'Standard') {
    throw "Expected '$OldNamespace' to be Standard, but found '$oldSku'. Stop and verify the target before continuing."
}
$location = Get-AzValue @('servicebus','namespace','show','--name',$OldNamespace,'--resource-group',$ResourceGroupName,'--query','location','-o','tsv')
if (-not $location) { throw "Could not determine the old namespace location." }

$newId = Get-AzValue @('servicebus','namespace','show','--name',$NewNamespace,'--resource-group',$ResourceGroupName,'--query','id','-o','tsv')
if (-not $newId) {
    Write-Host "[INFO] Creating Premium namespace '$NewNamespace' in $location" -ForegroundColor Cyan
    Invoke-Az @('servicebus','namespace','create','--name',$NewNamespace,'--resource-group',$ResourceGroupName,
        '--location',$location,'--sku','Premium','--tags',"project=$ProjectName","environment=$Environment",'migration=servicebus-premium','--output','none')
    $newId = Get-AzValue @('servicebus','namespace','show','--name',$NewNamespace,'--resource-group',$ResourceGroupName,'--query','id','-o','tsv')
} else {
    $newSku = Get-AzValue @('servicebus','namespace','show','--name',$NewNamespace,'--resource-group',$ResourceGroupName,'--query','sku.name','-o','tsv')
    if ($newSku -ne 'Premium') { throw "Target namespace '$NewNamespace' exists but is '$newSku', not Premium." }
    Write-Host "[OK] Premium namespace already exists" -ForegroundColor Gray
}
if ([string]::IsNullOrWhiteSpace($newId)) { throw "Could not determine the resource ID for Premium namespace '$NewNamespace'." }

if (-not (Get-AzValue @('servicebus','topic','show','--name',$TopicName,'--namespace-name',$NewNamespace,'--resource-group',$ResourceGroupName,'--query','name','-o','tsv'))) {
    Invoke-Az @('servicebus','topic','create','--name',$TopicName,'--namespace-name',$NewNamespace,'--resource-group',$ResourceGroupName,
        '--max-size','1024','--default-message-time-to-live','P14D','--enable-duplicate-detection','true',
        '--duplicate-detection-history-time-window','PT10M','--output','none')
    Write-Host "[OK] Created topic '$TopicName'" -ForegroundColor Green
}
if (-not (Get-AzValue @('servicebus','topic','subscription','show','--name',$SubscriptionName,'--topic-name',$TopicName,
    '--namespace-name',$NewNamespace,'--resource-group',$ResourceGroupName,'--query','name','-o','tsv'))) {
    Invoke-Az @('servicebus','topic','subscription','create','--name',$SubscriptionName,'--topic-name',$TopicName,
        '--namespace-name',$NewNamespace,'--resource-group',$ResourceGroupName,'--max-delivery-count','10',
        '--default-message-time-to-live','P14D','--output','none')
    Write-Host "[OK] Created subscription '$SubscriptionName'" -ForegroundColor Green
}

$mailboxId = Get-AzValue @('functionapp','identity','show','--name',$MailboxFunction,'--resource-group',$ResourceGroupName,'--query','principalId','-o','tsv')
$queueDbId = Get-AzValue @('functionapp','identity','show','--name',$QueueDbFunction,'--resource-group',$ResourceGroupName,'--query','principalId','-o','tsv')
$cuQueueDbId = Get-AzValue @('functionapp','identity','show','--name',$CuQueueDbFunction,'--resource-group',$ResourceGroupName,'--query','principalId','-o','tsv')
Ensure-Role -PrincipalId $mailboxId -Role 'Azure Service Bus Data Sender' -Scope $newId
Ensure-Role -PrincipalId $queueDbId -Role 'Azure Service Bus Data Receiver' -Scope $newId
Ensure-Role -PrincipalId $cuQueueDbId -Role 'Azure Service Bus Data Receiver' -Scope $newId

$newUrl = "https://$NewNamespace.servicebus.windows.net/"
$newHost = "$NewNamespace.servicebus.windows.net"
$newConnectionString = Get-AzValue @('servicebus','namespace','authorization-rule','keys','list','--namespace-name',$NewNamespace,
    '--resource-group',$ResourceGroupName,'--name','RootManageSharedAccessKey','--query','primaryConnectionString','-o','tsv')
if (-not $newConnectionString) { throw "Could not retrieve the new namespace connection string." }

Write-Host "[INFO] Updating Key Vault Service Bus secrets" -ForegroundColor Cyan
Invoke-Az @('keyvault','secret','set','--vault-name',$KeyVaultName,'--name','ServiceBusConnectionString','--value',$newConnectionString,'--output','none')
Invoke-Az @('keyvault','secret','set','--vault-name',$KeyVaultName,'--name','ServiceBusUrl','--value',$newUrl,'--output','none')
Invoke-Az @('keyvault','secret','set','--vault-name',$KeyVaultName,'--name','ServiceBusTopicName','--value',$TopicName,'--output','none')
Invoke-Az @('keyvault','secret','set','--vault-name',$KeyVaultName,'--name','ServiceBusSubscriptionName','--value',$SubscriptionName,'--output','none')

Write-Host "[INFO] Updating queue-trigger Function App namespace" -ForegroundColor Cyan
Invoke-Az @('functionapp','config','appsettings','set','--name',$QueueDbFunction,'--resource-group',$ResourceGroupName,
    '--settings',"ServiceBusConnection__fullyQualifiedNamespace=$newHost", "ServiceBusTopicName=$TopicName", "ServiceBusSubscriptionName=$SubscriptionName",'--output','none')
foreach ($functionName in @($MailboxFunction,$QueueDbFunction,$CuQueueDbFunction)) {
    Invoke-Az @('functionapp','restart','--name',$functionName,'--resource-group',$ResourceGroupName)
}
Invoke-Az @('webapp','restart','--name',$WebAppName,'--resource-group',$ResourceGroupName)

Write-Host "[SUCCESS] Application configuration now targets $NewNamespace" -ForegroundColor Green
Write-Host "[WARNING] Azure CLI did not move messages from $OldNamespace. Existing messages remain in the old namespace." -ForegroundColor Yellow

if ($DeleteOld) {
    if (-not $AllowMessageLoss) {
        throw "Refusing to delete '$OldNamespace'. Confirm messages are migrated/empty, then rerun with -DeleteOld -AllowMessageLoss."
    }
    $confirmation = (Read-Host "Type DELETE $OldNamespace to permanently delete the old namespace").Trim()
    if ($confirmation -ne "DELETE $OldNamespace") {
        throw 'Deletion cancelled.'
    }
    Invoke-Az @('servicebus','namespace','delete','--name',$OldNamespace,'--resource-group',$ResourceGroupName)
    Write-Host "[SUCCESS] Deleted old Standard namespace '$OldNamespace'" -ForegroundColor Green
}
else {
    Write-Host "[INFO] Old namespace retained. Delete later with -DeleteOld -AllowMessageLoss after message migration." -ForegroundColor Cyan
}

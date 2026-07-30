#Requires -Version 5.1
<#
.SYNOPSIS
    Check that the pipeline is working: containers exist and are protected,
    records are arriving in the workspace, and blobs are landing in storage.

.DESCRIPTION
    PowerShell twin of verify.sh.

    Every read goes through the caller's own Entra ID identity (--auth-mode
    login), which is both what the storage account is configured to require and
    what makes the read attributable in the blob access logs.

.PARAMETER ResourceGroup
    Resource group holding the storage account.

.PARAMETER StorageAccount
    Storage account holding the retained records.

.PARAMETER WorkspaceGuid
    Workspace GUID, to run the KQL checks. This is the customerId, not the
    resource ID. The workspace checks are skipped if it is omitted.

.PARAMETER TestImmutability
    Additionally attempt a blob delete, which must fail. Off by default because
    the delete can hang rather than return when the policy rejects it.

    Note this test is only meaningful if you hold a role that permits deletion.
    With read-only access the delete fails on permissions, which looks like a
    pass but proves nothing.

.EXAMPLE
    ./scripts/verify.ps1 -ResourceGroup rg-auditlogs-demo -StorageAccount auditlogsabc123 -WorkspaceGuid 00000000-0000-0000-0000-000000000000
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $ResourceGroup,

    [Parameter(Mandatory = $true)]
    [string] $StorageAccount,

    [string] $WorkspaceGuid,

    [switch] $TestImmutability
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'az is required but not installed.'
}

$script:Pass = 0
$script:Fail = 0
$script:Warn = 0

function Write-Ok { param([string] $Message) Write-Output "  [ ok ] $Message"; $script:Pass++ }
function Write-Bad { param([string] $Message) Write-Output "  [FAIL] $Message"; $script:Fail++ }
function Write-Warn { param([string] $Message) Write-Output "  [warn] $Message"; $script:Warn++ }

Write-Output ''
Write-Output 'Storage account'
Write-Output '---------------'

$accountJson = & az storage account show --name $StorageAccount --resource-group $ResourceGroup --output json 2>$null
if ($LASTEXITCODE -ne 0 -or -not $accountJson) {
    Write-Bad "storage account $StorageAccount not found in $ResourceGroup"
    exit 1
}
$account = $accountJson | ConvertFrom-Json

Write-Ok "storage account exists ($($account.sku.name) in $($account.location))"

# Read a boolean property, substituting a default only when it is genuinely
# absent. The shell twin has a comment here about jq's `//` operator collapsing
# `false` into the default; PowerShell has no such trap, but the same explicit
# null check is used so the two scripts stay comparable.
function Get-BoolProperty {
    param([object] $Object, [string] $Name, [bool] $Default)
    $value = $Object.PSObject.Properties[$Name]
    if ($null -eq $value -or $null -eq $value.Value) { return $Default }
    return [bool] $value.Value
}

if (-not (Get-BoolProperty $account 'allowSharedKeyAccess' $true)) {
    Write-Ok 'shared key access disabled, so every read is attributable to an identity'
} else {
    Write-Warn 'shared key access is enabled - reads authorised with the account key appear in the access log as anonymous, with no user attached'
}

if (Get-BoolProperty $account 'enableHttpsTrafficOnly' $false) {
    Write-Ok 'HTTPS-only enforced'
} else {
    Write-Bad 'HTTPS-only is not enforced'
}

if (-not (Get-BoolProperty $account 'allowBlobPublicAccess' $true)) {
    Write-Ok 'anonymous blob access disabled'
} else {
    Write-Bad 'anonymous blob access is permitted'
}

# The firewall is the usual reason the data-plane checks below fail, and it
# looks exactly like a missing role assignment if you do not check for it.
$firewallDefault = 'Allow'
$ipRuleCount = 0
if ($account.PSObject.Properties['networkRuleSet'] -and $account.networkRuleSet) {
    if ($account.networkRuleSet.defaultAction) { $firewallDefault = $account.networkRuleSet.defaultAction }
    if ($account.networkRuleSet.ipRules) { $ipRuleCount = @($account.networkRuleSet.ipRules).Count }
}

if ($firewallDefault -eq 'Deny') {
    if ($ipRuleCount -eq 0) {
        Write-Warn 'firewall denies by default with no IP rules - Azure Monitor can still write via the trusted-services path, but no client can read. Add your address to allowedIpRanges to inspect the archive.'
    } else {
        Write-Ok "firewall denies by default with $ipRuleCount allowed IP range(s)"
    }
} else {
    Write-Warn "firewall default action is $firewallDefault - the account is reachable from any network"
}

Write-Output ''
Write-Output 'Containers and retention'
Write-Output '------------------------'

$containerOutput = & az storage container list --account-name $StorageAccount --auth-mode login --query '[].name' --output tsv 2>$null
$containers = @()
if ($LASTEXITCODE -eq 0 -and $containerOutput) {
    $containers = @($containerOutput -split "`r?`n" | Where-Object { $_ })
}

if ($containers.Count -eq 0) {
    if ($firewallDefault -eq 'Deny' -and $ipRuleCount -eq 0) {
        Write-Bad 'cannot list containers: the storage firewall denies by default and has no IP rules, so this machine is blocked. Add your address to allowedIpRanges and redeploy. This is not a permissions problem.'
    } else {
        Write-Bad 'no containers found, or the caller cannot list them (needs Storage Blob Data Reader or higher on the account, which Contributor does not include)'
    }
} else {
    foreach ($container in $containers) {
        $policyJson = & az storage container immutability-policy show `
            --account-name $StorageAccount --resource-group $ResourceGroup `
            --container-name $container --output json 2>$null

        $period = $null; $state = $null; $appends = $false
        if ($LASTEXITCODE -eq 0 -and $policyJson) {
            $policy = $policyJson | ConvertFrom-Json
            if ($policy.PSObject.Properties['immutabilityPeriodSinceCreationInDays']) {
                $period = $policy.immutabilityPeriodSinceCreationInDays
            }
            if ($policy.PSObject.Properties['state']) { $state = $policy.state }
            if ($policy.PSObject.Properties['allowProtectedAppendWrites']) {
                $appends = [bool] $policy.allowProtectedAppendWrites
            }
        }

        if ($null -eq $period) {
            # An unprotected am-* container means export created it before the
            # template did, and everything already written to it is unprotected.
            if ($container -like 'am-*') {
                Write-Bad "$container has NO retention policy - export created it before the template did"
            } else {
                Write-Warn "$container has no retention policy"
            }
            continue
        }

        if ($appends) {
            Write-Ok "$container protected for $period days, state $state, protected appends allowed"
        } else {
            Write-Bad "$container protected for $period days but protected appends are disabled, which stops export writing to it"
        }
    }
}

Write-Output ''
Write-Output 'Blobs'
Write-Output '-----'

foreach ($container in ($containers | Where-Object { $_ -like 'am-*' })) {
    $count = & az storage blob list --account-name $StorageAccount --container-name $container `
        --auth-mode login --num-results 100 --query 'length(@)' --output tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $count) { $count = 0 }

    if ([int] $count -gt 0) {
        Write-Ok "$container holds $count blob(s)"
    } else {
        Write-Warn "$container is empty - expected for the first ~30 minutes while export provisions, or if nothing has been generated yet"
    }
}

if ($WorkspaceGuid) {
    Write-Output ''
    Write-Output 'Workspace'
    Write-Output '---------'

    # sum(ItemCount) rather than count(). If sampling is ever enabled, each
    # retained row stands for ItemCount originals and a plain count() silently
    # under-reports. The app disables sampling, so with a correct deployment the
    # two agree - a disagreement here means sampling got turned back on.
    $eventsJson = & az monitor log-analytics query --workspace $WorkspaceGuid `
        --analytics-query 'AppEvents | where TimeGenerated > ago(24h) | summarize Events = sum(ItemCount) by Name | order by Events desc' `
        --output json 2>$null

    $events = @()
    if ($LASTEXITCODE -eq 0 -and $eventsJson) { $events = @($eventsJson | ConvertFrom-Json) }

    if ($events.Count -gt 0) {
        Write-Ok "AppEvents has $($events.Count) event type(s) in the last 24h"
        foreach ($row in $events) { Write-Output "         $($row.Name): $($row.Events)" }
    } else {
        Write-Warn 'no AppEvents rows in the last 24h - generate some events, then allow 2-5 minutes for ingestion'
    }

    $httpJson = & az monitor log-analytics query --workspace $WorkspaceGuid `
        --analytics-query 'AppServiceHTTPLogs | where TimeGenerated > ago(24h) | summarize Requests = count()' `
        --output json 2>$null

    $httpRows = 0
    if ($LASTEXITCODE -eq 0 -and $httpJson) {
        $parsed = @($httpJson | ConvertFrom-Json)
        if ($parsed.Count -gt 0 -and $parsed[0].PSObject.Properties['Requests']) { $httpRows = $parsed[0].Requests }
    }

    if ([int] $httpRows -gt 0) {
        Write-Ok "AppServiceHTTPLogs has $httpRows request(s) in the last 24h"
    } else {
        Write-Warn 'no AppServiceHTTPLogs rows in the last 24h'
    }
}

if ($TestImmutability) {
    Write-Output ''
    Write-Output 'Immutability enforcement'
    Write-Output '------------------------'

    $target = $containers | Where-Object { $_ -like 'am-*' } | Select-Object -First 1
    if (-not $target) {
        Write-Warn 'no am-* container to test against'
    } else {
        $blob = & az storage blob list --account-name $StorageAccount --container-name $target `
            --auth-mode login --num-results 1 --query '[0].name' --output tsv 2>$null

        if (-not $blob -or $blob -eq 'None') {
            Write-Warn "no blob in $target to test against yet"
        } else {
            $result = & az storage blob delete --account-name $StorageAccount --container-name $target `
                --name $blob --auth-mode login 2>&1
            $text = ($result | Out-String)

            if ($text -match 'BlobImmutableDueToPolicy|immutable due to a policy') {
                Write-Ok "delete of $blob was rejected by the retention policy, as it should be"
            } elseif ($text -match 'do not have the required permissions|AuthorizationPermissionMismatch') {
                Write-Warn "delete of $blob failed on permissions, not the policy - this proves nothing. Grant Storage Blob Data Contributor and retry if you want a real test."
            } elseif ($LASTEXITCODE -eq 0 -and -not $text.Trim()) {
                Write-Bad "a blob in $target was DELETED - retention is not being enforced"
            } else {
                Write-Warn "delete of $blob did not succeed, but for an unrecognised reason: $($text.Trim())"
            }
        }
    }
}

Write-Output ''
Write-Output '------------------------------------------------------------'
Write-Output ("  {0} passed, {1} warnings, {2} failures" -f $script:Pass, $script:Warn, $script:Fail)
Write-Output '------------------------------------------------------------'
Write-Output ''

if ($script:Fail -gt 0) { exit 1 }
exit 0

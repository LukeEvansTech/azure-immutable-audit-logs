#Requires -Version 5.1
<#
.SYNOPSIS
    Lock the retention policies. THIS CANNOT BE UNDONE.

.DESCRIPTION
    PowerShell twin of lock-retention.sh.

    A locked policy cannot be removed, shortened or unlocked by anyone - not a
    subscription owner, not Microsoft support. The retention period can only be
    extended. Neither the storage account nor its resource group can be deleted
    until every blob's retention has expired, which for the six-year default
    means six years after the last write to each blob.

    This is deliberately a separate script rather than a deployment flag.
    Locking is a governance decision about a specific set of records, taken once
    the pipeline has been seen to work, not a property of a template.

.PARAMETER ResourceGroup
    Resource group holding the storage account.

.PARAMETER StorageAccount
    Storage account whose policies should be locked.

.PARAMETER Container
    Lock only these containers. Defaults to every am-* container with a policy.

.PARAMETER Force
    Skip the confirmation prompt. For automation that has already made this
    decision deliberately.

.EXAMPLE
    ./scripts/lock-retention.ps1 -ResourceGroup rg-auditlogs-prod -StorageAccount auditlogsabc123
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $ResourceGroup,

    [Parameter(Mandatory = $true)]
    [string] $StorageAccount,

    [string[]] $Container,

    [switch] $Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'az is required but not installed.'
}

if (-not $Container -or $Container.Count -eq 0) {
    $listed = & az storage container list --account-name $StorageAccount --auth-mode login `
        --query "[?starts_with(name, 'am-')].name" --output tsv 2>$null
    if ($LASTEXITCODE -eq 0 -and $listed) {
        $Container = @($listed -split "`r?`n" | Where-Object { $_ })
    }
}

if (-not $Container -or $Container.Count -eq 0) {
    throw 'No containers to lock.'
}

function Get-Policy {
    param([string] $Name)
    $json = & az storage container immutability-policy show `
        --account-name $StorageAccount --resource-group $ResourceGroup `
        --container-name $Name --output json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $json) { return $null }
    return $json | ConvertFrom-Json
}

Write-Output ''
Write-Output 'About to LOCK retention on:'
foreach ($name in $Container) {
    $policy = Get-Policy -Name $name
    if ($null -eq $policy) {
        Write-Output "  $name - no policy, will be SKIPPED"
    } elseif ($policy.state -eq 'Locked') {
        Write-Output "  $name - already locked ($($policy.immutabilityPeriodSinceCreationInDays) days)"
    } else {
        Write-Output "  $name - $($policy.immutabilityPeriodSinceCreationInDays) days, currently $($policy.state)"
    }
}

@'

Once locked:
  - the retention period can be extended, never reduced
  - no one can remove the policy, including subscription owners
  - the storage account and resource group cannot be deleted until every
    blob's retention has expired

'@ | Write-Output

if (-not $Force) {
    $confirmation = Read-Host 'Type LOCK to continue'
    if ($confirmation -cne 'LOCK') {
        Write-Output 'Aborted.'
        exit 1
    }
}

foreach ($name in $Container) {
    $policy = Get-Policy -Name $name

    if ($null -eq $policy -or -not $policy.PSObject.Properties['etag'] -or -not $policy.etag) {
        Write-Output "  skipped $name (no policy)"
        continue
    }

    if ($policy.state -eq 'Locked') {
        Write-Output "  skipped $name (already locked)"
        continue
    }

    # The lock has to quote the policy's current ETag. That is what stops it
    # happening by accident, and what makes it fail safely if the policy has
    # changed since it was read a moment ago.
    & az storage container immutability-policy lock `
        --account-name $StorageAccount --resource-group $ResourceGroup `
        --container-name $name --if-match $policy.etag --output none 2>&1 | Out-Null

    if ($LASTEXITCODE -eq 0) {
        Write-Output "  LOCKED $name"
    } else {
        Write-Warning "FAILED to lock $name"
    }
}

Write-Output ''
Write-Output 'Done. Verify with:'
Write-Output "  ./scripts/verify.ps1 -ResourceGroup $ResourceGroup -StorageAccount $StorageAccount"

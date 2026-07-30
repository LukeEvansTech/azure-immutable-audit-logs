#Requires -Version 5.1
<#
.SYNOPSIS
    Remove the deployment.

.DESCRIPTION
    PowerShell twin of teardown.sh.

    Refuses to run if any retention policy is locked. That is not caution for
    its own sake: a locked policy makes the storage account undeletable until
    every blob's retention has expired, so the delete would fail part-way and
    leave the resource group in a half-removed state.

.PARAMETER ResourceGroup
    Resource group to delete.

.PARAMETER StorageAccount
    Storage account to check for locked policies. Discovered from the resource
    group if omitted.

.PARAMETER PurgeWorkspace
    Also purge the soft-deleted Log Analytics workspace, so the name is
    immediately reusable. Without this it is recoverable for 14 days.

.PARAMETER Force
    Skip the confirmation prompt.

.EXAMPLE
    ./scripts/teardown.ps1 -ResourceGroup rg-auditlogs-demo -PurgeWorkspace
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $ResourceGroup,

    [string] $StorageAccount,

    [switch] $PurgeWorkspace,

    [switch] $Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'az is required but not installed.'
}

& az group show --name $ResourceGroup --output none 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Output "Resource group $ResourceGroup does not exist. Nothing to do."
    exit 0
}

if (-not $StorageAccount) {
    $found = & az storage account list --resource-group $ResourceGroup --query '[0].name' --output tsv 2>$null
    if ($LASTEXITCODE -eq 0 -and $found -and $found -ne 'None') { $StorageAccount = $found.Trim() }
}

if ($StorageAccount) {
    Write-Output "==> Checking retention policies on $StorageAccount"

    $locked = @()
    $unlocked = @()

    $listed = & az storage container list --account-name $StorageAccount --auth-mode login `
        --query '[].name' --output tsv 2>$null
    if ($LASTEXITCODE -eq 0 -and $listed) {
        foreach ($container in @($listed -split "`r?`n" | Where-Object { $_ })) {
            $state = & az storage container immutability-policy show `
                --account-name $StorageAccount --resource-group $ResourceGroup `
                --container-name $container --query 'state' --output tsv 2>$null
            if ($LASTEXITCODE -eq 0 -and $state) {
                switch ($state.Trim()) {
                    'Locked' { $locked += $container }
                    'Unlocked' { $unlocked += $container }
                }
            }
        }
    }

    if ($locked.Count -gt 0) {
        $list = ($locked | ForEach-Object { "  $_" }) -join [Environment]::NewLine
        @"

Refusing to delete: these containers have LOCKED retention policies.

$list

A locked policy cannot be removed by anyone. The storage account, and therefore
the resource group, cannot be deleted until every blob in these containers has
passed its retention period. This is the protection working as intended, not a
fault.

If you need the rest of the resource group gone, delete those resources
individually and leave the storage account in place.
"@ | Write-Error -ErrorAction Continue
        exit 1
    }

    # Unlocked policies need no special handling here, which is worth stating
    # because the opposite is a natural assumption.
    #
    # An unlocked policy protects the DATA: deleting a blob under an active
    # unlocked policy is rejected with BlobImmutableDueToPolicy, exactly as
    # under a locked one. It does not protect the ACCOUNT: deleting the storage
    # account itself succeeds, and takes the containers and blobs with it.
    #
    # Verified against a live deployment rather than inferred.
    if ($unlocked.Count -gt 0) {
        Write-Output "    $($unlocked.Count) unlocked polic(ies) present - these do not block account deletion"
    }
}

$workspaceName = $null
if ($PurgeWorkspace) {
    $found = & az monitor log-analytics workspace list --resource-group $ResourceGroup `
        --query '[0].name' --output tsv 2>$null
    if ($LASTEXITCODE -eq 0 -and $found -and $found -ne 'None') { $workspaceName = $found.Trim() }
}

if (-not $Force) {
    Write-Output ''
    Write-Output "This will delete the resource group $ResourceGroup and everything in it."
    $confirmation = Read-Host 'Type the resource group name to confirm'
    if ($confirmation -cne $ResourceGroup) {
        Write-Output 'Aborted.'
        exit 1
    }
}

Write-Output "==> Deleting resource group $ResourceGroup"
& az group delete --name $ResourceGroup --yes --output none
if ($LASTEXITCODE -ne 0) { throw "Failed to delete resource group $ResourceGroup." }

if ($PurgeWorkspace -and $workspaceName) {
    Write-Output "==> Purging soft-deleted workspace $workspaceName"
    # Soft-deleted workspaces hold their name for 14 days, so redeploying with
    # the same parameters into the same resource group otherwise fails.
    & az monitor log-analytics workspace delete --resource-group $ResourceGroup `
        --workspace-name $workspaceName --force true --yes --output none 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Output '    purge failed or was unnecessary - the workspace may already be gone'
    }
}

Write-Output '==> Done'

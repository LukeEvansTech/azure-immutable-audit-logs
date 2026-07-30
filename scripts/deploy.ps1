#Requires -Version 5.1
<#
.SYNOPSIS
    Deploy the self-contained demo: infrastructure, then the app, then optionally
    Entra ID authentication in front of it.

.DESCRIPTION
    PowerShell twin of deploy.sh, with the same behaviour and the same output.

    Retention policies are created unlocked. Locking them is a separate,
    deliberate and irreversible step - see scripts/lock-retention.ps1.

.PARAMETER ResourceGroup
    Resource group to deploy into. Created if absent.

.PARAMETER Location
    Azure region. Defaults to uksouth.

.PARAMETER Subscription
    Subscription to deploy into. Defaults to the current one.

.PARAMETER ParametersFile
    Bicep parameters file. Defaults to infra/main.bicepparam if it exists.

.PARAMETER EnableAuth
    Put Entra ID sign-in in front of the app. Requires permission to create app
    registrations in the tenant.

.PARAMETER SkipApp
    Deploy infrastructure only, do not publish the app.

.EXAMPLE
    ./scripts/deploy.ps1 -ResourceGroup rg-auditlogs-demo -Location uksouth
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $ResourceGroup,

    [string] $Location = 'uksouth',

    [string] $Subscription,

    [string] $ParametersFile,

    [switch] $EnableAuth,

    [switch] $SkipApp
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $PSScriptRoot

function Assert-Command {
    param([string] $Name, [string] $Hint)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "$Name is required but not installed.$(if ($Hint) { " $Hint" })"
    }
}

# Wrapper around az so a non-zero exit becomes a terminating error. az writes
# some perfectly ordinary progress text to stderr, so $ErrorActionPreference
# alone is not enough to distinguish success from failure.
function Invoke-Az {
    param([Parameter(ValueFromRemainingArguments = $true)] [string[]] $Arguments)
    $output = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "az $($Arguments -join ' ') failed:`n$output"
    }
    return $output
}

# jq is not needed here - unlike the shell twin, PowerShell parses JSON natively.
Assert-Command az

if (-not $SkipApp) {
    Assert-Command dotnet 'Use -SkipApp to deploy infrastructure only.'
}

if ($Subscription) {
    Write-Output "==> Selecting subscription $Subscription"
    Invoke-Az account set --subscription $Subscription | Out-Null
}

# Default to the operator's own parameters file when they have made one, so that
# a plain ./scripts/deploy.ps1 picks it up rather than silently ignoring it.
if (-not $ParametersFile) {
    $candidate = Join-Path $RepoRoot 'infra/main.bicepparam'
    if (Test-Path $candidate) { $ParametersFile = $candidate }
}

Write-Output "==> Ensuring resource group $ResourceGroup exists in $Location"
Invoke-Az group create --name $ResourceGroup --location $Location --output none | Out-Null

Write-Output '==> Deploying infrastructure'
$deployName = "immutable-audit-logs-$([DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))"
$deployArgs = @(
    'deployment', 'group', 'create',
    '--resource-group', $ResourceGroup,
    '--template-file', (Join-Path $RepoRoot 'infra/main.bicep'),
    '--name', $deployName
)
if ($ParametersFile) {
    Write-Output "    using parameters from $ParametersFile"
    $deployArgs += @('--parameters', $ParametersFile)
}
$deployArgs += @('--query', 'properties.outputs', '--output', 'json')

$outputs = (Invoke-Az @deployArgs) | ConvertFrom-Json

$workspaceName = $outputs.workspaceName.value
$workspaceGuid = $outputs.workspaceCustomerId.value
$storageAccount = $outputs.storageAccountName.value
$appServiceName = $outputs.appServiceName.value
$appUrl = $outputs.appServiceHostName.value
$appInsightsName = $outputs.appInsightsName.value
$retentionDays = $outputs.retentionDays.value
$sharedKey = $outputs.sharedKeyAccessAllowed.value

Write-Output '==> Infrastructure deployed'

if (-not $SkipApp) {
    Write-Output '==> Publishing the app'
    $buildDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Path $buildDir -Force | Out-Null
    try {
        $publishDir = Join-Path $buildDir 'publish'
        $zipPath = Join-Path $buildDir 'app.zip'

        & dotnet publish (Join-Path $RepoRoot 'app/AuditLogDemo.csproj') `
            --configuration Release `
            --output $publishDir `
            --nologo `
            --verbosity quiet
        if ($LASTEXITCODE -ne 0) { throw 'dotnet publish failed.' }

        Compress-Archive -Path (Join-Path $publishDir '*') -DestinationPath $zipPath -Force

        Invoke-Az webapp deploy `
            --resource-group $ResourceGroup `
            --name $appServiceName `
            --src-path $zipPath `
            --type zip `
            --output none | Out-Null
    } finally {
        Remove-Item -Recurse -Force $buildDir -ErrorAction SilentlyContinue
    }
    Write-Output '==> App published'
}

if ($EnableAuth) {
    Write-Output '==> Enabling Entra ID sign-in'
    $tenantId = (Invoke-Az account show --query tenantId --output tsv).Trim()
    $subscriptionId = (Invoke-Az account show --query id --output tsv).Trim()

    # App Services are created with v1 auth config, which rejects every v2
    # command. Upgrading is a no-op once it has been done.
    $authVersion = (& az webapp auth-classic show --name $appServiceName --resource-group $ResourceGroup --query configVersion --output tsv 2>$null)
    if ($authVersion -eq 'v1') {
        Write-Output '    upgrading auth config v1 -> v2'
        Invoke-Az webapp auth config-version upgrade --name $appServiceName --resource-group $ResourceGroup --output none | Out-Null
    }

    $existingClientId = (& az webapp auth show --name $appServiceName --resource-group $ResourceGroup `
            --query 'properties.identityProviders.azureActiveDirectory.registration.clientId' --output tsv 2>$null)

    $clientSecret = $null
    if ([string]::IsNullOrWhiteSpace($existingClientId) -or $existingClientId -eq 'None') {
        Write-Output '    creating app registration'
        # enable-id-token-issuance is required: Easy Auth uses the hybrid flow
        # (response_type=code+id_token) and the sign-in fails without it.
        $clientId = (Invoke-Az ad app create `
                --display-name $appServiceName `
                --web-redirect-uris "$appUrl/.auth/login/aad/callback" `
                --sign-in-audience AzureADMyOrg `
                --enable-id-token-issuance true `
                --query appId --output tsv).Trim()
        $clientSecret = (Invoke-Az ad app credential reset --id $clientId --query password --output tsv).Trim()
        Write-Output "    app registration created ($clientId)"
    } else {
        $clientId = $existingClientId.Trim()
        Write-Output "    reusing app registration ($clientId)"
    }

    # The secret goes in through a temp file rather than as a command-line
    # argument. On Windows argv is visible to other processes via WMI, and CI
    # log collectors capture it verbatim; a file in the user-scoped temp
    # directory is neither.
    if ($clientSecret) {
        $settingsFile = [System.IO.Path]::GetTempFileName()
        try {
            # az expects a JSON array. ConvertTo-Json -AsArray is PowerShell 7+
            # only, and Windows PowerShell 5.1 collapses a single-element array
            # to a bare object, which az rejects. Bracket it explicitly so the
            # same code works on both.
            $setting = @{
                name        = 'MICROSOFT_PROVIDER_AUTHENTICATION_SECRET'
                value       = $clientSecret
                slotSetting = $false
            } | ConvertTo-Json -Depth 4 -Compress
            "[$setting]" | Set-Content -Path $settingsFile -Encoding utf8

            Invoke-Az webapp config appsettings set `
                --name $appServiceName `
                --resource-group $ResourceGroup `
                --settings "@$settingsFile" `
                --output none | Out-Null
        } finally {
            Remove-Item -Force $settingsFile -ErrorAction SilentlyContinue
        }
    }

    Invoke-Az webapp auth microsoft update `
        --name $appServiceName `
        --resource-group $ResourceGroup `
        --client-id $clientId `
        --client-secret-setting-name MICROSOFT_PROVIDER_AUTHENTICATION_SECRET `
        --issuer "https://login.microsoftonline.com/$tenantId/v2.0" `
        --yes `
        --output none | Out-Null

    # redirectToProvider has no CLI equivalent. Without it an unauthenticated
    # browser lands on a provider-selection page rather than the sign-in page.
    $authBody = @{
        properties = @{
            platform          = @{ enabled = $true }
            globalValidation  = @{
                requireAuthentication       = $true
                unauthenticatedClientAction = 'RedirectToLoginPage'
                redirectToProvider          = 'azureActiveDirectory'
            }
            identityProviders = @{
                azureActiveDirectory = @{
                    enabled      = $true
                    registration = @{
                        clientId                = $clientId
                        clientSecretSettingName = 'MICROSOFT_PROVIDER_AUTHENTICATION_SECRET'
                        openIdIssuer            = "https://login.microsoftonline.com/$tenantId/v2.0"
                    }
                }
            }
            login             = @{ tokenStore = @{ enabled = $true } }
        }
    } | ConvertTo-Json -Depth 10 -Compress

    $bodyFile = [System.IO.Path]::GetTempFileName()
    try {
        Set-Content -Path $bodyFile -Value $authBody -Encoding utf8
        Invoke-Az rest --method PUT `
            --url "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Web/sites/$appServiceName/config/authsettingsV2?api-version=2022-09-01" `
            --body "@$bodyFile" `
            --output none | Out-Null
    } finally {
        Remove-Item -Force $bodyFile -ErrorAction SilentlyContinue
    }

    Write-Output "    sign-in enabled for tenant $tenantId"
}

@"

------------------------------------------------------------
  Deployed
------------------------------------------------------------
  Resource group   $ResourceGroup
  Workspace        $workspaceName
  Workspace GUID   $workspaceGuid
  Storage account  $storageAccount
  App Service      $appServiceName
  App URL          $appUrl
  App Insights     $appInsightsName
  Blob retention   $retentionDays days (UNLOCKED)
  Shared key auth  $sharedKey
------------------------------------------------------------

Export takes around 30 minutes to start writing. Events generated before then
may never reach storage. This is normal and is not worth investigating until
the 30 minutes have passed.

Next:
  1. Open $appUrl and generate some events.
  2. Wait, then check they landed:
       ./scripts/verify.ps1 -ResourceGroup $ResourceGroup ``
         -StorageAccount $storageAccount -WorkspaceGuid $workspaceGuid
  3. Only once you are satisfied, lock retention (IRREVERSIBLE):
       ./scripts/lock-retention.ps1 -ResourceGroup $ResourceGroup ``
         -StorageAccount $storageAccount
"@ | Write-Output

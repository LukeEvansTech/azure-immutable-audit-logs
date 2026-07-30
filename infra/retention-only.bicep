// Immutable (WORM) retention tier for a Log Analytics workspace you already own.
//
// This is the production entry point. It creates the storage account, one
// container per exported table with an immutability policy attached, blob
// diagnostics, and the export rule that ships the named tables into those
// containers as records arrive.
//
// It consumes your existing workspace and creates nothing inside it beyond the
// export rule. It does not touch your application, your Application Insights
// component, or your existing diagnostic settings.
//
// For a self-contained demo that builds the whole pipeline including an app that
// emits events, deploy main.bicep instead.
//
// Retention policies are created UNLOCKED. Unlocked still enforces the retention
// period, but an administrator can remove it. Locking is a separate and
// irreversible step - see the deployment guide.

targetScope = 'resourceGroup'

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------

@description('Resource ID of the existing Log Analytics workspace to export from. If you only have an Application Insights component, the deployment guide has the command that derives its workspace, and tells you what it means when that command returns nothing.')
param workspaceResourceId string

@description('Short prefix used to build default resource names. Lowercase alphanumeric.')
@minLength(3)
@maxLength(11)
param baseName string = 'auditlogs'

@description('Name of the storage account holding the retained records. Must be globally unique, 3-24 characters, lowercase alphanumeric. Override to match local naming conventions.')
@minLength(3)
@maxLength(24)
param storageAccountName string = toLower('${baseName}${uniqueString(resourceGroup().id, baseName)}')

@description('Region for the storage account. MUST match the workspace region: export to a destination in a different region is rejected. Override when the target resource group is not in the workspace region.')
param location string = resourceGroup().location

@description('Retention period applied to every retained blob, in days. Defaults to six years.')
@minValue(1)
@maxValue(146000)
param retentionDays int = 2190

@description('Storage redundancy. Zone-redundant is the minimum for a record set that must survive a datacentre failure; geo-zone-redundant is preferred for production. Locally-redundant is not offered.')
@allowed([
  'Standard_ZRS'
  'Standard_GZRS'
  'Standard_GRS'
])
param storageSku string = 'Standard_ZRS'

@description('Tables to export. One container is created per table, named am-<lowercase table name>. Only list tables that already exist in the workspace: naming a table that has never received data fails the whole rule, not just that table. StorageBlobLogs in particular cannot be listed on the first run - it does not exist until the blob diagnostics this template creates have emitted their first record.')
@minLength(1)
param exportTables array = [
  'AppEvents'
]

@description('Public IP ranges permitted to reach the storage account, for administrative and retrieval access. Empty means no public IP is allowed and only the Azure Monitor platform path can write.')
param allowedIpRanges array = []

@description('Whether account key authorisation is permitted. Leaving this false forces every read through Entra ID, so the access logs record who read what. Confirm export still flows in a test environment before relying on it in production.')
param allowSharedKeyAccess bool = false

@description('Name of the export rule created on the workspace.')
param exportRuleName string = '${baseName}-export'

@description('Tags applied to the storage account.')
param tags object = {}

// ---------------------------------------------------------------------------
// Derived values
//
// The workspace subscription, resource group and name are split out of the
// supplied resource ID. These must come from a parameter rather than a lookup on
// the workspace itself: the scope of the export-rule module has to be resolvable
// before the deployment starts, and a property read off an existing resource is
// not.
// ---------------------------------------------------------------------------

var workspaceSubscriptionId = split(workspaceResourceId, '/')[2]
var workspaceResourceGroup = split(workspaceResourceId, '/')[4]
var workspaceName = split(workspaceResourceId, '/')[8]

// ---------------------------------------------------------------------------
// WORM retention tier
// ---------------------------------------------------------------------------

module wormStorage 'modules/worm-storage.bicep' = {
  name: 'deploy-worm-storage'
  params: {
    storageAccountName: storageAccountName
    location: location
    retentionDays: retentionDays
    storageSku: storageSku
    exportTables: exportTables
    workspaceResourceId: workspaceResourceId
    diagnosticSettingName: '${baseName}-blob-diagnostics'
    allowedIpRanges: allowedIpRanges
    allowSharedKeyAccess: allowSharedKeyAccess
    tags: tags
  }
}

// ---------------------------------------------------------------------------
// Export rule
//
// Created at the workspace, which may be in a different resource group or
// subscription from the storage account, so it goes through a module scoped
// there. Created last, and only once every container carries a retention policy.
// ---------------------------------------------------------------------------

module dataExport 'modules/data-export.bicep' = {
  name: 'deploy-data-export'
  scope: resourceGroup(workspaceSubscriptionId, workspaceResourceGroup)
  params: {
    workspaceName: workspaceName
    exportRuleName: exportRuleName
    storageAccountResourceId: wormStorage.outputs.storageAccountResourceId
    exportTables: exportTables
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

output storageAccountName string = wormStorage.outputs.storageAccountName
output storageAccountResourceId string = wormStorage.outputs.storageAccountResourceId
output storageAccountLocation string = wormStorage.outputs.storageAccountLocation
output blobEndpoint string = wormStorage.outputs.blobEndpoint
output containerNames array = wormStorage.outputs.containerNames
output sharedKeyAccessAllowed bool = wormStorage.outputs.sharedKeyAccessAllowed
output exportRuleName string = dataExport.outputs.exportRuleName
output exportedTables array = exportTables
output retentionDays int = retentionDays

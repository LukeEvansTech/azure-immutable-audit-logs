// End-to-end immutable audit-log retention, self-contained.
//
// Deploys the whole pipeline into one resource group: a demo web app that emits
// audit and security events, the Application Insights component and Log
// Analytics workspace they land in, and the WORM storage tier that Data Export
// ships them to for long-term, tamper-evident retention.
//
//   app -> Application Insights -> Log Analytics -> Data Export -> WORM blobs
//
// This is the "see it working" entry point. To add the retention tier to a
// workspace you already own, deploy retention-only.bicep instead: it creates the
// storage account, containers, policies and export rule, and touches nothing
// else in your workspace.
//
// Retention policies are created UNLOCKED. Unlocked still enforces the retention
// period, but an administrator can remove it. Locking is a separate, deliberate,
// irreversible step - see the deployment guide.

targetScope = 'resourceGroup'

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------

@description('Short prefix used to build resource names. Lowercase alphanumeric. Kept to 11 characters so the generated storage account name stays inside the 24-character limit.')
@minLength(3)
@maxLength(11)
param baseName string = 'auditlogs'

@description('Region for every resource. The storage account and the workspace must share a region: export to a destination in a different region is rejected.')
param location string = resourceGroup().location

@description('Retention period applied to every retained blob, in days. Defaults to six years.')
@minValue(1)
@maxValue(146000)
param retentionDays int = 2190

@description('Storage redundancy for the retention tier. Locally-redundant is deliberately not offered: a record set that must survive a datacentre failure needs at least zone redundancy.')
@allowed([
  'Standard_ZRS'
  'Standard_GZRS'
  'Standard_GRS'
])
param storageSku string = 'Standard_ZRS'

@description('Interactive-query retention on the workspace, in days. This is the hot, queryable window and is independent of the WORM retention above: the workspace is where you query recent data, the blobs are where the long-term record lives. PerGB2018 floor is 30.')
@minValue(30)
@maxValue(730)
param workspaceRetentionDays int = 30

@description('App Service plan SKU. B1 is the smallest tier that supports the always-on demo workload; F1 free tier cannot run it reliably.')
@allowed([
  'B1'
  'B2'
  'P0v3'
  'P1v3'
])
param appServiceSku string = 'B1'

@description('Tables to export into the WORM tier. One container is created per table. Every table listed must already exist in the workspace by the time the rule is created - see the troubleshooting guide before adding to this list.')
@minLength(1)
param exportTables array = [
  'AppEvents'
  'AppServiceHTTPLogs'
]

@description('Public IP ranges permitted to reach the storage account, for administrative and retrieval access. Empty means no public IP is allowed and only the Azure Monitor platform path can write.')
param allowedIpRanges array = []

@description('Whether account key authorisation is permitted on the retention tier. Leaving this false forces every read through Entra ID, which is what makes the reader identity appear in the access logs. Retrieval evidence depends on it.')
param allowSharedKeyAccess bool = false

@description('Tags applied to every resource.')
param tags object = {}

// ---------------------------------------------------------------------------
// Derived names
// ---------------------------------------------------------------------------

var uniqueSuffix = uniqueString(resourceGroup().id, baseName)
var workspaceName = '${baseName}-law-${uniqueSuffix}'
var appInsightsName = '${baseName}-appi-${uniqueSuffix}'
var appServicePlanName = '${baseName}-plan-${uniqueSuffix}'
var appServiceName = '${baseName}-app-${uniqueSuffix}'
var storageAccountName = toLower('${baseName}${uniqueSuffix}')
var exportRuleName = '${baseName}-export'

// ---------------------------------------------------------------------------
// Log Analytics workspace
// ---------------------------------------------------------------------------

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: workspaceName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: workspaceRetentionDays
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

// ---------------------------------------------------------------------------
// Application Insights
//
// Workspace-based, which is what makes the data queryable in Log Analytics and
// therefore exportable. A classic component stores its data outside any
// workspace and cannot be exported from at all.
// ---------------------------------------------------------------------------

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspace.id
    IngestionMode: 'LogAnalytics'
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

// ---------------------------------------------------------------------------
// Demo application
// ---------------------------------------------------------------------------

resource appServicePlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: appServicePlanName
  location: location
  tags: tags
  kind: 'linux'
  sku: {
    name: appServiceSku
  }
  properties: {
    reserved: true
  }
}

resource appService 'Microsoft.Web/sites@2023-12-01' = {
  name: appServiceName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'DOTNETCORE|10.0'
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      http20Enabled: true
      alwaysOn: true
      appSettings: [
        {
          // Connection string rather than instrumentation key: key-only
          // ingestion is retired, and the connection string carries the
          // regional endpoints the SDK needs.
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          name: 'ASPNETCORE_ENVIRONMENT'
          value: 'Production'
        }
      ]
    }
  }
}

// App Service platform logs. AppServiceHTTPLogs is the table that carries the
// request-level record; the others are operational and are not exported by
// default.
resource appDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: '${baseName}-app-diagnostics'
  scope: appService
  properties: {
    workspaceId: workspace.id
    logs: [
      {
        category: 'AppServiceHTTPLogs'
        enabled: true
      }
      {
        category: 'AppServiceConsoleLogs'
        enabled: true
      }
      {
        category: 'AppServiceAppLogs'
        enabled: true
      }
      {
        category: 'AppServicePlatformLogs'
        enabled: true
      }
    ]
  }
}

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
    workspaceResourceId: workspace.id
    diagnosticSettingName: '${baseName}-blob-diagnostics'
    allowedIpRanges: allowedIpRanges
    allowSharedKeyAccess: allowSharedKeyAccess
    tags: tags
  }
}

// ---------------------------------------------------------------------------
// Export rule
//
// Created last, and only once every container carries a retention policy. The
// reverse order leaves a window in which export has created its own containers
// and is writing into them unprotected.
//
// The rule also depends on the diagnostic settings above, because a table that
// has never received data does not exist, and naming one fails the whole rule.
// AppEvents is provisioned with the workspace-based Application Insights
// component; AppServiceHTTPLogs is provisioned by the App Service diagnostic
// setting.
// ---------------------------------------------------------------------------

module dataExport 'modules/data-export.bicep' = {
  name: 'deploy-data-export'
  params: {
    workspaceName: workspace.name
    exportRuleName: exportRuleName
    storageAccountResourceId: wormStorage.outputs.storageAccountResourceId
    exportTables: exportTables
  }
  dependsOn: [
    appDiagnostics
  ]
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

output resourceGroupName string = resourceGroup().name
output location string = location

output workspaceName string = workspace.name
output workspaceResourceId string = workspace.id

@description('The workspace GUID, which is what the Log Analytics query API and the az monitor log-analytics query command take, not the resource ID.')
output workspaceCustomerId string = workspace.properties.customerId

output appInsightsName string = appInsights.name
output appServiceName string = appService.name
output appServiceHostName string = 'https://${appService.properties.defaultHostName}'
output appServicePrincipalId string = appService.identity.principalId

output storageAccountName string = wormStorage.outputs.storageAccountName
output storageAccountResourceId string = wormStorage.outputs.storageAccountResourceId
output blobEndpoint string = wormStorage.outputs.blobEndpoint
output containerNames array = wormStorage.outputs.containerNames
output sharedKeyAccessAllowed bool = wormStorage.outputs.sharedKeyAccessAllowed

output exportRuleName string = dataExport.outputs.exportRuleName
output exportedTables array = exportTables
output retentionDays int = retentionDays

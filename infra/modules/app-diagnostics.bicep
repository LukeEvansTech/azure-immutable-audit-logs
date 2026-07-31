// Diagnostic settings on an App Service that already exists.
//
// Deployed as a module so it can be created at the app's own resource group and
// subscription, which need not be the ones holding the storage account.
//
// This is the only thing the retention templates do to an application they did
// not create, and it is additive: a diagnostic setting is a separate child
// resource, so this does not disturb settings the app already has, and removing
// it later leaves the app untouched.
//
// Without it, AppServiceHTTPLogs never reaches the workspace, and naming that
// table in an export rule fails the whole rule rather than just that table.

targetScope = 'resourceGroup'

@description('Name of the existing App Service. Must be in this resource group.')
param appServiceName string

@description('Name of the diagnostic setting to create. Use something identifiable: an app can carry several, and the portal lists them by name alone.')
param diagnosticSettingName string

@description('Resource ID of the Log Analytics workspace the logs are sent to.')
param workspaceResourceId string

@description('Log categories to enable. AppServiceHTTPLogs is the one that carries the request-level record; the others are operational. Categories vary by plan, and naming one the plan does not support fails the deployment.')
param logCategories array = [
  'AppServiceHTTPLogs'
  'AppServiceConsoleLogs'
  'AppServiceAppLogs'
  'AppServicePlatformLogs'
]

resource appService 'Microsoft.Web/sites@2023-12-01' existing = {
  name: appServiceName
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: diagnosticSettingName
  scope: appService
  properties: {
    workspaceId: workspaceResourceId
    logs: [
      for category in logCategories: {
        category: category
        enabled: true
      }
    ]
  }
}

output diagnosticSettingName string = diagnostics.name
output enabledCategories array = logCategories

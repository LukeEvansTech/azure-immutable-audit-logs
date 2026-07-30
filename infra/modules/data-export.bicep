// Continuous export rule on a Log Analytics workspace.
//
// Deployed as a module so it can be created at the workspace's own resource
// group and subscription, which need not be the ones holding the storage
// account.

targetScope = 'resourceGroup'

@description('Name of the existing Log Analytics workspace. Must be in this resource group.')
param workspaceName string

@description('Name of the export rule.')
param exportRuleName string

@description('Resource ID of the destination storage account. Must be in the same region as the workspace, and must not already be the destination of another export rule on this workspace.')
param storageAccountResourceId string

@description('Tables to export. Every table listed must already exist in the workspace: naming a table that has never received data fails the whole rule, not just that one table.')
@minLength(1)
param exportTables array

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: workspaceName
}

resource exportRule 'Microsoft.OperationalInsights/workspaces/dataExports@2020-08-01' = {
  parent: workspace
  name: exportRuleName
  properties: {
    destination: {
      resourceId: storageAccountResourceId
    }
    tableNames: exportTables
    enable: true
  }
}

output exportRuleName string = exportRule.name
output exportRuleResourceId string = exportRule.id

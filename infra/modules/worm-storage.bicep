// Write-once, read-many (WORM) storage tier for exported log records.
//
// Creates a storage account, one container per exported table, a container-scoped
// immutability policy on each, and blob diagnostics pointing back at the
// workspace.
//
// Containers and their retention policies are created together, before any
// export rule exists. That ordering matters: if export creates a container by
// itself first, records land in it unprotected and a policy applied afterwards
// does not retrospectively cover them.

targetScope = 'resourceGroup'

@description('Name of the storage account holding the retained records. Must be globally unique, 3-24 characters, lowercase alphanumeric.')
@minLength(3)
@maxLength(24)
param storageAccountName string

@description('Region for the storage account. MUST match the workspace region: export to a destination in a different region is rejected.')
param location string

@description('Retention period applied to every retained blob, in days. Defaults to six years.')
@minValue(1)
@maxValue(146000)
param retentionDays int = 2190

@description('Storage redundancy. Zone-redundant is the minimum for a record set that must survive a datacentre failure; geo-zone-redundant is preferred for production. Locally-redundant is deliberately not offered.')
@allowed([
  'Standard_ZRS'
  'Standard_GZRS'
  'Standard_GRS'
])
param storageSku string = 'Standard_ZRS'

@description('Tables being exported. One container is created per table, named am-<lowercase table name>, matching the container naming that export itself uses.')
@minLength(1)
param exportTables array

@description('Resource ID of the Log Analytics workspace that blob diagnostics are sent to.')
param workspaceResourceId string

@description('Name of the diagnostic setting created on the blob service.')
param diagnosticSettingName string

@description('Public IP ranges permitted to reach the storage account, for administrative and retrieval access. Empty means no public IP is allowed and only the Azure Monitor platform path can write.')
param allowedIpRanges array = []

@description('Whether account key authorisation is permitted. Leaving this false forces every read through Entra ID, which is what makes the reader identity appear in the access logs.')
param allowSharedKeyAccess bool = false

@description('Tags applied to the storage account.')
param tags object = {}

// Export writes one container per table, named am- followed by the lowercased
// table name. Building the container list from the same array that feeds the
// export rule keeps the two in step; a container that does not match is a
// container export creates itself, without a retention policy on it.
var containerNames = [for table in exportTables: 'am-${toLower(table)}']

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: storageSku
  }
  properties: {
    accessTier: 'Hot'
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    allowSharedKeyAccess: allowSharedKeyAccess
    defaultToOAuthAuthentication: true

    // Must stay Enabled. Setting this to Disabled blocks the trusted-services
    // path as well as the public internet, which stops export writing at all.
    // The firewall below is what restricts access, not this switch.
    publicNetworkAccess: 'Enabled'

    networkAcls: {
      defaultAction: 'Deny'

      // Admits the Azure Monitor platform, which is how exported data is
      // written. There is no narrower form of this: a per-resource rule naming
      // the workspace is not supported for this resource type, and would grant
      // endpoint reachability rather than data access in any case.
      bypass: 'AzureServices'

      ipRules: [
        for ipRange in allowedIpRanges: {
          value: ipRange
          action: 'Allow'
        }
      ]
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
}

resource containers 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = [
  for name in containerNames: {
    parent: blobService
    name: name
    properties: {
      publicAccess: 'None'
    }
  }
]

resource immutabilityPolicies 'Microsoft.Storage/storageAccounts/blobServices/containers/immutabilityPolicies@2023-05-01' = [
  for (name, i) in containerNames: {
    parent: containers[i]
    name: 'default'
    properties: {
      immutabilityPeriodSinceCreationInDays: retentionDays

      // Exported data arrives as append blobs, extended over the life of each
      // five-minute window. Without this, the first append after the policy
      // takes effect is rejected and export stops.
      //
      // Note the retention clock on an append blob runs from its last
      // modification, not its creation, so a blob becomes eligible for deletion
      // the retention period after the final append to it.
      allowProtectedAppendWrites: true
    }
  }
]

// Records who read the retained data, what was written, and any attempt to
// delete it. Without this the account can show that records were written but
// not who has since read them.
//
// These land in the workspace's StorageBlobLogs table, which does not exist
// until the first of them is emitted. Add that table to exportTables on a later
// run to bring this evidence onto the same retention path as the records.
resource blobDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: diagnosticSettingName
  scope: blobService
  properties: {
    workspaceId: workspaceResourceId
    logs: [
      {
        category: 'StorageRead'
        enabled: true
      }
      {
        category: 'StorageWrite'
        enabled: true
      }
      {
        category: 'StorageDelete'
        enabled: true
      }
    ]
  }
}

output storageAccountName string = storageAccount.name
output storageAccountResourceId string = storageAccount.id
output storageAccountLocation string = storageAccount.location
output containerNames array = containerNames
output blobEndpoint string = storageAccount.properties.primaryEndpoints.blob

// Surfaced so the deploying operator can see, from the deployment output alone,
// whether reads will be attributable to a named identity or will fall back to a
// shared key. Retrieval evidence depends on this being false.
output sharedKeyAccessAllowed bool = allowSharedKeyAccess

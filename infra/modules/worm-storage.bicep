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

@description('Storage redundancy. Zone-redundant is the minimum for a record set that must survive a datacentre failure; geo-zone-redundant is preferred for production. Locally-redundant is not offered.')
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

@description('Whether account key authorisation is permitted. Leaving this false forces every read through Entra ID, so the access logs name the reader.')
param allowSharedKeyAccess bool = false

@description('Whether the account is reachable over its public endpoint at all. Disabled means the private endpoint is the only client route in; the Azure Monitor platform path that Data Export uses is separate and is not affected by this. Enabled still denies by default and admits only allowedIpRanges.')
@allowed([
  'Disabled'
  'Enabled'
])
param publicNetworkAccess string = 'Disabled'

@description('Minimum TLS version accepted on requests to the account. TLS1_2 is the only value the storage resource provider accepts: TLS1_3 appears in the ARM enum and in the Azure Verified Modules allow-list, but a deployment on 2026-07-31 was rejected with "FeatureNotSupported: Feature MinimumTlsVersion 1.3 is not supported". Offered as a parameter so it can be widened if that changes.')
@allowed([
  'TLS1_2'
])
param minimumTlsVersion string = 'TLS1_2'

@description('Resource ID of the subnet to place the blob private endpoint in. Empty creates no endpoint, which only makes sense when publicNetworkAccess is Enabled.')
param privateEndpointSubnetResourceId string = ''

@description('Resource ID of the privatelink blob private DNS zone. Empty registers no DNS, leaving the endpoint unreachable by name.')
param privateDnsZoneResourceId string = ''

@description('Name of the private endpoint resource.')
param privateEndpointName string = 'pep-${storageAccountName}-blob'

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
    minimumTlsVersion: minimumTlsVersion
    supportsHttpsTrafficOnly: true

    // Not a parameter. Anonymous container or blob access has no legitimate use
    // for an audit archive, and making it configurable invites someone to
    // configure it.
    allowBlobPublicAccess: false

    allowSharedKeyAccess: allowSharedKeyAccess
    defaultToOAuthAuthentication: true

    // Disabled means no client reaches the account except through the private
    // endpoint.
    //
    // Data Export is unaffected either way: it writes through the Azure Monitor
    // platform rather than as a network client of this account. Microsoft's own
    // guidance for export is the firewall-plus-trusted-services shape, and
    // whether Disabled also permits it is reported to work but explained as a
    // precedence artefact rather than a guarantee. Treat a change here as
    // something to observe in a test environment before relying on, and check
    // blobs are still arriving afterwards.
    publicNetworkAccess: publicNetworkAccess

    networkAcls: {
      defaultAction: 'Deny'

      // Admits the Azure Monitor platform, which is how exported data is
      // written. There is no narrower form of this: a per-resource rule naming
      // the workspace is not supported for this resource type, and would grant
      // endpoint reachability rather than data access in any case.
      //
      // Retained even when publicNetworkAccess is Disabled, so that flipping
      // back to Enabled does not silently drop the export path.
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

// ---------------------------------------------------------------------------
// Private endpoint
//
// Created after the containers so the account is fully shaped before anything
// is routed to it. This is the retrieval path; export does not use it.
// ---------------------------------------------------------------------------

module privateEndpoint 'private-endpoint.bicep' = if (!empty(privateEndpointSubnetResourceId)) {
  name: 'deploy-${privateEndpointName}'
  params: {
    privateEndpointName: privateEndpointName
    location: location
    subnetResourceId: privateEndpointSubnetResourceId
    storageAccountResourceId: storageAccount.id
    privateDnsZoneResourceId: privateDnsZoneResourceId
    tags: tags
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

output publicNetworkAccess string = publicNetworkAccess
output minimumTlsVersion string = minimumTlsVersion
output privateEndpointDeployed bool = !empty(privateEndpointSubnetResourceId)

@description('Private address the blob endpoint resolves to inside the network, or empty when no endpoint was created. Empty while an endpoint exists means DNS was not registered.')
output privateEndpointIpAddress string = !empty(privateEndpointSubnetResourceId)
  ? privateEndpoint!.outputs.privateIpAddress
  : ''

// Private endpoint for the blob service, with private DNS registration.
//
// This sits on the RETRIEVAL path, not the ingestion path. Data Export writes to
// the storage account through the Azure Monitor platform, which does not
// traverse this endpoint. What the endpoint changes is how an operator, a
// retrieval tool or a jump host reaches the archive: over a private address
// inside the virtual network rather than the public endpoint.
//
// The DNS zone group is the part people forget. Without it the endpoint exists
// and has an address, but clients still resolve the account's public name to a
// public IP and are rejected by the firewall - which presents as a 403 rather
// than anything network-shaped. See the troubleshooting guide.

targetScope = 'resourceGroup'

@description('Name of the private endpoint resource.')
param privateEndpointName string

@description('Region for the private endpoint. Must be the region of the subnet it lands in.')
param location string

@description('Resource ID of the subnet the endpoint gets its address from. The subnet must have privateEndpointNetworkPolicies disabled.')
param subnetResourceId string

@description('Resource ID of the storage account being exposed.')
param storageAccountResourceId string

@description('Resource ID of the privatelink.blob.core.windows.net private DNS zone. Empty skips DNS registration, which leaves the endpoint unusable by name until DNS is handled elsewhere - correct only when a central platform team owns the zone.')
param privateDnsZoneResourceId string = ''

@description('Tags applied to the private endpoint.')
param tags object = {}

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: privateEndpointName
  location: location
  tags: tags
  properties: {
    subnet: {
      id: subnetResourceId
    }
    privateLinkServiceConnections: [
      {
        name: '${privateEndpointName}-blob'
        properties: {
          privateLinkServiceId: storageAccountResourceId

          // Blob only. A storage account can carry an endpoint per sub-resource
          // (blob, file, queue, table, dfs) and each needs its own DNS zone.
          // Exporting only creates blobs, so only blob is exposed.
          groupIds: [
            'blob'
          ]
        }
      }
    ]
  }
}

resource dnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = if (!empty(privateDnsZoneResourceId)) {
  parent: privateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-blob-core-windows-net'
        properties: {
          privateDnsZoneId: privateDnsZoneResourceId
        }
      }
    ]
  }
}

output privateEndpointName string = privateEndpoint.name
output privateEndpointResourceId string = privateEndpoint.id

@description('The private IPv4 address the blob endpoint resolves to inside the virtual network, or empty if it cannot be read at this point in the deployment. Useful when diagnosing whether DNS is resolving to the endpoint or to the public address.')
output privateIpAddress string = length(privateEndpoint.properties.customDnsConfigs) > 0 && length(privateEndpoint.properties.customDnsConfigs[0].ipAddresses) > 0
  ? privateEndpoint.properties.customDnsConfigs[0].ipAddresses[0]
  : ''

output dnsRegistered bool = !empty(privateDnsZoneResourceId)

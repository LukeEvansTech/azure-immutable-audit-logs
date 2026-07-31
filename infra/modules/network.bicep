// Virtual network, subnets and private DNS zone for the self-contained demo.
//
// Production deployments should NOT use this. A landing zone owns its own
// address space and DNS, and a template that invents a virtual network will
// either be rejected or quietly create an island that nothing can route to.
// retention-only.bicep therefore takes an existing subnet and zone instead.
//
// Two subnets, because they cannot be the same one:
//   - the private endpoint subnet needs private-endpoint network policies off
//   - the verifier subnet is delegated to Azure Container Instances, and a
//     delegated subnet cannot host anything else

targetScope = 'resourceGroup'

@description('Name of the virtual network.')
param vnetName string

@description('Region for the network resources.')
param location string

@description('Address space for the virtual network.')
param addressPrefix string = '10.20.0.0/16'

@description('Address prefix for the private endpoint subnet.')
param privateEndpointSubnetPrefix string = '10.20.1.0/24'

@description('Address prefix for the verifier subnet, delegated to Azure Container Instances.')
param verifierSubnetPrefix string = '10.20.2.0/24'

@description('Create the verifier subnet. Only needed when running the in-network verification container; a deployment that reads the archive from elsewhere on the network does not need it.')
param createVerifierSubnet bool = true

@description('Tags applied to the network resources.')
param tags object = {}

var privateDnsZoneName = 'privatelink.blob.${environment().suffixes.storage}'

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        addressPrefix
      ]
    }
    subnets: concat(
      [
        {
          name: 'snet-private-endpoints'
          properties: {
            addressPrefix: privateEndpointSubnetPrefix

            // Network policies have to be off on a private endpoint subnet, or
            // the endpoint deploys and then silently receives no traffic.
            privateEndpointNetworkPolicies: 'Disabled'
          }
        }
      ],
      createVerifierSubnet
        ? [
            {
              name: 'snet-verifier'
              properties: {
                addressPrefix: verifierSubnetPrefix
                delegations: [
                  {
                    name: 'aci-delegation'
                    properties: {
                      serviceName: 'Microsoft.ContainerInstance/containerGroups'
                    }
                  }
                ]
              }
            }
          ]
        : []
    )
  }
}

// The zone name is derived from environment().suffixes.storage rather than
// hard-coded, so this still resolves correctly in sovereign clouds where the
// storage suffix is not core.windows.net.
resource privateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: privateDnsZoneName
  location: 'global'
  tags: tags
}

// Without this link the zone exists but the virtual network does not consult
// it, so clients inside the network keep resolving the public address.
resource dnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: privateDnsZone
  name: '${vnetName}-link'
  location: 'global'
  tags: tags
  properties: {
    virtualNetwork: {
      id: vnet.id
    }
    registrationEnabled: false
  }
}

output vnetName string = vnet.name
output vnetResourceId string = vnet.id
output privateEndpointSubnetResourceId string = vnet.properties.subnets[0].id
output verifierSubnetResourceId string = createVerifierSubnet ? vnet.properties.subnets[1].id : ''
output privateDnsZoneName string = privateDnsZone.name
output privateDnsZoneResourceId string = privateDnsZone.id

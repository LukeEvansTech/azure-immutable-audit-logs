// Worked parameters for the self-contained demo (main.bicep).
//
// Copy to main.bicepparam and edit. main.bicepparam is gitignored, because the
// IP ranges you put in it are yours and do not belong in a public repository.
//
//   cp infra/main.example.bicepparam infra/main.bicepparam
//
// Every value below is a default that main.bicep already applies. Uncomment only
// what you want to change.

using 'main.bicep'

// Short prefix for resource names. Max 11 characters: the storage account name
// is this plus a 13-character hash, and the limit for that is 24.
// param baseName = 'auditlogs'

// Region for everything. The storage account and workspace must share a region.
// Defaults to the resource group's region.
// param location = 'uksouth'

// Blob retention, in days. 2190 is six years. This is the number that becomes
// irreversible once you lock the policies, so decide it before you lock, not
// after: locking permits extension only, never reduction.
// param retentionDays = 2190

// Storage redundancy. Locally-redundant is not offered, because a record
// set that must survive a datacentre failure needs at least zone redundancy.
// param storageSku = 'Standard_ZRS'

// Hot, queryable retention on the workspace, in days. Independent of the blob
// retention above: this is the window you can run KQL over, and it is where the
// cost of a long value shows up. The long-term record lives in the blobs.
// param workspaceRetentionDays = 30

// App Service plan SKU for the demo app. B1 is the smallest that runs it
// reliably; the F1 free tier cannot.
// param appServiceSku = 'B1'

// Tables shipped into the WORM tier, one container each.
//
// AppEvents is the audit and security event stream from the app. Both defaults
// exist by the time the export rule is created - AppEvents comes with the
// workspace-based Application Insights component, AppServiceHTTPLogs with the
// App Service diagnostic setting.
//
// StorageBlobLogs is left out for a reason: it does not exist until the blob
// diagnostics created here have emitted their first record, so it can only be
// added on a later run. Doing so is worthwhile - it brings the record of who
// read the archive onto the same retention path as the archive itself.
// param exportTables = [
//   'AppEvents'
//   'AppServiceHTTPLogs'
// ]

// Public IP ranges allowed to reach the storage account, for administrative and
// retrieval access. Empty means no public IP reaches it and only the Azure
// Monitor platform path can write - correct for production, but it also means
// you cannot browse the containers from your own machine.
// param allowedIpRanges = [
//   '203.0.113.0/24'
// ]

// Whether account key authorisation is permitted.
//
// Leave this false. A key-authorised read is recorded as an anonymous shared-key
// request with no user identity attached, which destroys the attribution that
// makes the access log worth keeping. Setting it true is a decision to accept
// unattributable reads.
// param allowSharedKeyAccess = false

// Tags applied to every resource.
// param tags = {
//   environment: 'demo'
//   owner: 'platform-team'
// }

// --- Hardening -------------------------------------------------------------

// Whether the retention tier is reachable over its public endpoint.
//
// Disabled is the default and means the private endpoint is the only client
// route in. Data Export is unaffected: it writes through the Azure Monitor
// platform rather than as a network client of the account.
//
// The practical cost is that you cannot read the archive from your own machine
// any more. Use scripts/verify-private.sh, which runs the check from a
// throwaway container inside the virtual network.
// param storagePublicNetworkAccess = 'Disabled'

// Minimum TLS version on the storage account.
//
// TLS1_3 is in the ARM enum, but parts of Microsoft's SDK reference state that
// minimum TLS 1.3 is not supported, and the two have not been reconciled.
// TLS1_2 is the safe default. If you set TLS1_3, confirm the deployment is
// accepted rather than assuming it.
// param storageMinimumTlsVersion = 'TLS1_2'

// Minimum TLS version on the demo app.
// param appMinimumTlsVersion = '1.2'

// --- Private networking ----------------------------------------------------

// This template creates its own virtual network, because it is the
// self-contained demo. Production should use retention-only.bicep, which
// attaches to a subnet the platform team already owns.
//
// Set false to skip the network and the private endpoint entirely. Only
// sensible alongside storagePublicNetworkAccess = 'Enabled' and an entry in
// allowedIpRanges, or nothing can reach the archive at all.
// param deployPrivateEndpoint = true

// Address space. Change if these overlap something you peer with later.
// param vnetAddressPrefix = '10.20.0.0/16'
// param privateEndpointSubnetPrefix = '10.20.1.0/24'
// param verifierSubnetPrefix = '10.20.2.0/24'

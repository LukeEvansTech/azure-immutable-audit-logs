// Worked parameters for adding a retention tier to a workspace you already own
// (retention-only.bicep).
//
// Copy to retention-only.bicepparam and edit. retention-only.bicepparam is
// gitignored, because the workspace resource ID and IP ranges you put in it are
// yours and do not belong in a public repository.
//
//   cp infra/retention-only.example.bicepparam infra/retention-only.bicepparam
//
// workspaceResourceId is the only required value.

using 'retention-only.bicep'

// The workspace to export from. Required.
//
// If you have an Application Insights component rather than a workspace ID, the
// deployment guide has the command that derives one from the other - and
// explains why a component that returns nothing cannot be exported from at all.
param workspaceResourceId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-monitoring/providers/Microsoft.OperationalInsights/workspaces/law-central'

// Short prefix for resource names. Max 11 characters.
// param baseName = 'auditlogs'

// Override when your naming convention does not tolerate a generated name. Must
// be globally unique, 3-24 characters, lowercase alphanumeric.
// param storageAccountName = 'auditlogsprod001'

// MUST match the workspace region, not merely the resource group's region.
// Export to a destination in a different region is rejected. Set this explicitly
// whenever the target resource group lives somewhere else.
// param location = 'uksouth'

// Blob retention, in days. 2190 is six years. This is the number that becomes
// irreversible once you lock the policies, so decide it before you lock, not
// after: locking permits extension only, never reduction.
// param retentionDays = 2190

// Storage redundancy. Locally-redundant is not offered.
// param storageSku = 'Standard_ZRS'

// Tables to export, one container each.
//
// Every table listed must already exist in the workspace. A table that has never
// received data does not exist, and naming it fails the whole rule rather than
// just that one table - this is the most common way a first deployment fails.
//
// StorageBlobLogs cannot be listed on the first run: it comes from the blob
// diagnostics this template creates, so it does not exist until after the first
// deployment has completed and emitted a record. Add it on a later run to bring
// the record of who read the archive onto the same retention path as the
// archive itself.
// param exportTables = [
//   'AppEvents'
//   'AppServiceHTTPLogs'
//   'StorageBlobLogs'
// ]

// Public IP ranges allowed to reach the storage account, for administrative and
// retrieval access. Empty means no public IP reaches it and only the Azure
// Monitor platform path can write.
// param allowedIpRanges = [
//   '203.0.113.0/24'
// ]

// Whether account key authorisation is permitted.
//
// Leave this false. A key-authorised read is recorded as an anonymous shared-key
// request with no user identity attached, which destroys the attribution that
// makes the access log worth keeping. If you have existing tooling that depends
// on account keys, change the tooling rather than this setting.
// param allowSharedKeyAccess = false

// Name of the export rule created on the workspace. A workspace supports at
// most 10 active rules, and each storage account can be the destination of only
// one of them.
// param exportRuleName = 'auditlogs-export'

// Tags applied to the storage account.
// param tags = {
//   environment: 'production'
//   dataClassification: 'audit-record'
// }

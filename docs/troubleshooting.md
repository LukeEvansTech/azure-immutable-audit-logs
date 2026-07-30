# Troubleshooting

Failures worth knowing about before you hit them.

## Nothing has arrived in storage

**Almost always: you have not waited long enough.** A new export rule takes around 30 minutes to provision before it writes anything, and data generated during that window may never appear. After it is live, batches land roughly every five minutes.

Wait the full 30 minutes before investigating. Then, in order:

```bash
# Is the rule there and enabled?
az monitor log-analytics workspace data-export show \
  --resource-group <workspace-rg> --workspace-name <workspace> --name auditlogs-export

# Is anything reaching the workspace at all? If this is empty, the problem is
# upstream of export and storage is a red herring.
az monitor log-analytics query --workspace <workspace-guid> \
  --analytics-query "AppEvents | where TimeGenerated > ago(1h) | summarize sum(ItemCount)"

# Can you actually see the container contents?
az storage blob list --account-name <storage-account> \
  --container-name am-appevents --auth-mode login --output table
```

If the workspace query returns rows but storage is empty after an hour, check the export rule's destination region against the workspace region.

## `one of the tables does not exist`

The export rule names a table that has never received data. A table with no data does not exist, and naming it **fails the entire rule**, not just that table.

The usual culprits:

- **`StorageBlobLogs` on a first deployment.** It comes from the blob diagnostics the template itself creates, so it cannot exist until after the first deployment has completed and emitted a record. Add it on a second run.
- **`AppServiceHTTPLogs` before the app has served a request.**
- A typo. Table names are case-sensitive in this context.

Deploy with `exportTables = ['AppEvents']`, confirm it works, then add tables one at a time.

## Export was working, then stopped

Check `allowProtectedAppendWrites` on the container's policy:

```bash
az storage container immutability-policy show \
  --account-name <storage-account> --resource-group <rg> \
  --container-name am-appevents \
  --query '{period:immutabilityPeriodSinceCreationInDays, state:state, appends:allowProtectedAppendWrites}'
```

Exported blobs are append blobs, extended across their five-minute window. If protected appends are disabled, the first append after the policy takes effect is rejected and export stops writing to that container. The templates set this to `true`; a policy applied by hand may not have.

## `The storage account is in a different region`

The storage account must be in the **workspace's** region, which is not necessarily the resource group's region. `retention-only.bicep` defaults `location` to the resource group, so set it explicitly when the two differ:

```bash
az monitor log-analytics workspace show --ids "$WORKSPACE_ID" --query location -o tsv
```

## Storage account name errors

Storage account names are **3-24 characters, lowercase alphanumeric, globally unique**. The generated name is `baseName` plus a 13-character hash, so `baseName` is capped at 11 characters by the template.

This fails at deployment time, not at build time - `az bicep build` will not catch an over-long name. Override `storageAccountName` directly if your naming convention needs something specific.

## `AuthorizationPermissionMismatch` reading blobs

Contributor on the storage account is a *control-plane* role. It does not grant data-plane access, and with shared key access disabled there is no key to fall back on.

```bash
az role assignment create --assignee "<upn>" \
  --role "Storage Blob Data Reader" \
  --scope "<storage-account-resource-id>"
```

Role assignments can take a few minutes to propagate.

## Every `az storage` command fails

Add `--auth-mode login`. Without it the CLI attempts account-key authorisation, which the account rejects by default.

This is intended behaviour. Key-authorised reads appear in the access log as anonymous shared-key requests with no user attached, which destroys the attribution the archive exists to provide.

## The portal downloaded a blob but no user appears in the logs

The portal silently prefers the **account key** whenever your identity can retrieve one. Check the authentication method at the top of the container view in **Storage browser** and switch it to Entra ID.

A key-authorised read is recorded with `AuthenticationType` of shared key and an empty `RequesterUpn`. It cannot be attributed to a person after the fact.

## A container has no retention policy

If an `am-*` container exists with no policy, export created it before the template did - which means everything already in it is unprotected, and applying a policy now does not retrospectively cover it.

This happens when a table is named in the export rule but not in the container list. The templates here build both from the same array so they cannot diverge; a hand-edited rule can.

```bash
az storage container immutability-policy create \
  --account-name <storage-account> --resource-group <rg> \
  --container-name <container> \
  --period 2190 --allow-protected-append-writes true
```

Treat the records written before that point as unprotected, and be prepared to say so.

## Teardown fails, or `teardown.sh` refuses to run

### If the policy is locked

Expected, and unfixable. A locked policy cannot be removed by anyone, and the storage account cannot be deleted until every blob has passed its retention period - six years, on the default.

`teardown.sh` checks first and stops rather than half-deleting the resource group. If you need the rest gone, delete the other resources individually and leave the storage account.

This is why the demo should never be locked.

### If the policy is unlocked

Teardown works, and needs no special handling. This is worth stating because the opposite is a reasonable assumption: if a blob cannot be deleted, surely the account holding it cannot either.

It can. The protection is scoped to the data, not the container of it. Checked against a live deployment with an active, unexpired policy and blobs present:

| Operation | Unlocked | Locked |
| --- | --- | --- |
| Delete a blob | Rejected, `BlobImmutableDueToPolicy` | Rejected |
| Delete the storage account | **Succeeds** | Fails until retention expires |

So `az group delete`, and `teardown.sh`, work normally against unlocked policies. If you are dismantling something by hand and want the containers gone without the account, remove the policy first:

```bash
ETAG=$(az storage container immutability-policy show \
  --account-name <storage-account> --resource-group <rg> \
  --container-name am-appevents --query etag -o tsv)

az storage container immutability-policy delete \
  --account-name <storage-account> --resource-group <rg> \
  --container-name am-appevents --if-match "$ETAG"
```

Container deletion, unlike account deletion, does fail while a container holds blobs under an active policy.

## Redeploying fails on the workspace name

Deleted Log Analytics workspaces are soft-deleted and hold their name for 14 days. Redeploying with the same parameters into the same resource group hits the reserved name.

Either purge at teardown:

```bash
./scripts/teardown.sh --resource-group <rg> --purge-workspace
```

or recover the soft-deleted one, or change `baseName`.

## `BCP120` when deriving the workspace in Bicep

If you try to take an Application Insights resource ID and read the workspace off it:

```bicep
// This does not compile.
resource ai 'Microsoft.Insights/components@2020-02-02' existing = { name: aiName }
module export 'modules/data-export.bicep' = {
  scope: resourceGroup(split(ai.properties.WorkspaceResourceId, '/')[4])
}
```

Module `scope` and resource `location` must both be resolvable *before* the deployment starts. Any property read off an `existing` resource is a runtime `reference()`, which is not.

This is why `retention-only.bicep` takes `workspaceResourceId` as a parameter and the derivation command lives in the [deployment guide](deployment.md#step-1-identify-the-workspace) instead.

## Records are missing

If specific events are absent from the archive but the application definitely emitted them, check sampling:

```kusto
AppEvents
| where TimeGenerated > ago(1h)
| summarize Rows = count(), Events = sum(ItemCount)
```

If `Events` exceeds `Rows`, adaptive sampling is active and the archive is **not** a complete account of what the application did. Sampling is on by default in the SDK; the demo app disables it explicitly. See [How it works](how-it-works.md#why-sampling-is-disabled).

Also check the obvious: `Properties.UserId` versus the built-in `UserId` column. A query filtering on the wrong one returns nothing and looks like missing data.

## Parsing the exported files fails

They are newline-delimited JSON - one object per line, no enclosing array. `json.load` on the whole file will not work.

```bash
jq -c '.' < PT05M.json          # per line
jq -s '.' < PT05M.json          # slurp into an array
```

And the path traps, again, because they are worth repeating:

- `m=` after `y=` is the **month**; `m=` after `h=` is the **minute**
- the workspace resource ID inside the path is **lowercased**, so a prefix built from the portal's casing will not match
- the filename spelling is contested - `PT5M.json` and `PT05M.json` both circulate, and the deployment behind this documentation produced `PT5M.json`. Glob the folder instead of hardcoding either
- busy windows overflow into numbered siblings - enumerate the folder

## Rule and destination limits

- A workspace supports at most **10 active export rules**
- A storage account can be the destination of **only one rule** per workspace
- **Premium storage accounts** are not supported as destinations

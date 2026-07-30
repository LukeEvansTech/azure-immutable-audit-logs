# Deployment

## Prerequisites

- **Azure CLI**, signed in (`az login`). Bicep support is built in; `az bicep version` confirms it.
- **jq** and **zip**, used by the scripts.
- **.NET 10 SDK**, only if you are publishing the demo app. Not needed for `--skip-app` or for the production template.

If you use [mise](https://mise.jdx.dev), `mise install` picks up the pinned versions from `.mise.toml`.

### Permissions

The two templates need different things, because the export rule is created at the workspace and the workspace may live somewhere else entirely.

| Scope | Role | Needed for |
|---|---|---|
| Target resource group | Contributor | Creating the storage account and, for the demo, the app and workspace |
| Workspace's resource group | Log Analytics Contributor | Creating the export rule |
| Storage account | Storage Blob Data Reader or higher | Reading blobs back, including from `verify.sh` |

Contributor on the storage account does **not** grant data-plane access. Reading a blob needs a data role, and with shared key access disabled there is no key to fall back on. Grant yourself Storage Blob Data Reader if you intend to look at the contents.

## Quickstart: the self-contained demo

Stands up the whole pipeline in a throwaway resource group, including an app that emits events.

```bash
git clone https://github.com/LukeEvansTech/azure-immutable-audit-logs.git
cd azure-immutable-audit-logs

# Optional: take a copy of the parameters and edit it. Every value has a
# working default, so this is only needed if you want to change something.
cp infra/main.example.bicepparam infra/main.bicepparam

./scripts/deploy.sh --resource-group rg-auditlogs-demo --location uksouth
```

Add `--enable-auth` to put Entra ID sign-in in front of the app, so the events carry a real user identity rather than being anonymous. It needs permission to create app registrations in the tenant.

The script prints a summary with the names you will need next.

### Then

1. **Open the app URL** and generate some events. The test console has one-click scenarios, a custom event builder and a bulk generator.

2. **Wait.** Records are queryable in the workspace within 2-5 minutes, but Data Export takes around 30 minutes to provision before it writes anything at all. Events generated during that window may never reach storage.

3. **Check it worked:**

    ```bash
    ./scripts/verify.sh \
      --resource-group rg-auditlogs-demo \
      --storage-account <storage-account> \
      --workspace-guid <workspace-guid>
    ```

    Both values are in the deploy summary. `--workspace-guid` is the workspace's `customerId`, not its resource ID.

4. **Tear it down** when you are finished:

    ```bash
    ./scripts/teardown.sh --resource-group rg-auditlogs-demo --purge-workspace
    ```

    `--purge-workspace` removes the soft-deleted workspace so its name is immediately reusable. Without it the name is held for 14 days, and redeploying with the same parameters into the same resource group fails.

!!! warning "Do not lock retention on the demo"

    A locked policy makes the storage account, and therefore the resource group, undeletable until every blob has passed its retention period. On the six-year default that is six years. `teardown.sh` refuses to run when it finds a locked policy, for exactly this reason.

## Production: add retention to a workspace you already own

`infra/retention-only.bicep` creates the storage account, containers, policies, blob diagnostics and export rule. It creates nothing inside your workspace beyond the export rule, and does not touch your application, your Application Insights component or your existing diagnostic settings.

### Step 1: identify the workspace

Export runs from a Log Analytics workspace, not from an Application Insights component. If you have a component, this returns the workspace behind it:

```bash
APP_INSIGHTS_ID='/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Insights/components/<name>'

WORKSPACE_ID=$(az monitor app-insights component show \
  --ids "$APP_INSIGHTS_ID" \
  --query properties.WorkspaceResourceId -o tsv)

echo "${WORKSPACE_ID:?component is classic - its data is not in a workspace and cannot be exported}"
```

An empty result means the component is classic. That is a blocker, not a detail: classic components store data outside any workspace, so there is nothing to export. Migrate it to workspace-based first.

Take the region too. The storage account **must** be created in the workspace's region, or the export rule is rejected:

```bash
az monitor log-analytics workspace show --ids "$WORKSPACE_ID" --query location -o tsv
```

### Step 2: configure

```bash
cp infra/retention-only.example.bicepparam infra/retention-only.bicepparam
```

Set `workspaceResourceId`. Set `location` explicitly if the target resource group is not in the workspace's region. Review `retentionDays` carefully - it is the number that becomes irreversible when you lock.

Start `exportTables` small. `AppEvents` alone is a valid first deployment, and tables are cheap to add later.

### Step 3: deploy

```bash
az deployment group create \
  --resource-group <target-resource-group> \
  --template-file infra/retention-only.bicep \
  --parameters infra/retention-only.bicepparam
```

Policies are created **unlocked**.

### Step 4: confirm records are arriving

Wait 30 minutes for export to provision, then another five for the first batch.

```bash
az storage blob list \
  --account-name <storage-account> \
  --container-name am-appevents \
  --auth-mode login \
  --output table
```

`--auth-mode login` is required. The account is deployed with key access disabled, so a command without it fails - which is the intended behaviour, not a misconfiguration.

You can also confirm the rule itself:

```bash
az monitor log-analytics workspace data-export show \
  --resource-group <workspace-resource-group> \
  --workspace-name <workspace-name> \
  --name auditlogs-export
```

**Do not lock retention until you have seen blobs arrive.**

### Step 5: lock retention

This is irreversible. Read [How it works](how-it-works.md#immutability-mechanics) first if you have not.

```bash
./scripts/lock-retention.sh \
  --resource-group <target-resource-group> \
  --storage-account <storage-account>
```

It lists what it is about to lock, states the consequences, and requires you to type `LOCK`.

Locking cannot be expressed in a template. It is a separate operation that has to quote the policy's current ETag, which is precisely what stops it happening by accident as part of a routine redeploy.

## Adding tables later

Every table in `exportTables` must already exist in the workspace. A table that has never received data does not exist, and naming it fails the whole rule rather than just that one table. This is the most common way a first deployment fails.

`StorageBlobLogs` cannot be included on the first run. It comes from the blob diagnostics these templates create, so it does not exist until after the first deployment has completed and emitted a record. **Adding it on a later run is worth doing**: it brings the record of who has read the archive onto the same retention path as the archive itself, which is usually the entire point of keeping the archive.

To add a table, uncomment it in the parameters file and redeploy. The matching container is created with its retention policy at the same time as the rule is updated.

!!! note "Redeploying does not retrofit policies"

    If export has already created a container by itself - because it was named in the rule but not in the container list - a later deployment will not add a policy to it. Apply one directly, and treat everything already in that container as unprotected.

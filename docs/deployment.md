# Deployment

## Prerequisites

- **Azure CLI**, signed in (`az login`). Bicep support is built-in; `az bicep version` confirms it.
- **jq** and **`zip`**, used by the shell scripts. Neither is needed for the PowerShell twins.
- **.NET 10 SDK**, only if you are publishing the demo app. Not needed for `--skip-app` or for the production template.

Every script has a PowerShell twin with identical behaviour, for Windows or anywhere else with PowerShell. Windows PowerShell 5.1 and PowerShell 7+ both work. The shell scripts take flags, the PowerShell ones take named parameters:

| Shell | PowerShell |
| --- | --- |
| `./scripts/deploy.sh --resource-group <rg>` | `./scripts/deploy.ps1 -ResourceGroup <rg>` |
| `--location <region>` | `-Location <region>` |
| `--enable-auth` | `-EnableAuth` |
| `--skip-app` | `-SkipApp` |
| `--workspace-guid <guid>` | `-WorkspaceGuid <guid>` |
| `--purge-workspace` | `-PurgeWorkspace` |
| `--yes` | `-Force` |

If you use [mise](https://mise.jdx.dev), `mise install` picks up the pinned versions from `.mise.toml`.

### Permissions

The two templates need different things, because the export rule is created at the workspace and the workspace may live somewhere else entirely.

| Scope | Role | Needed for |
| --- | --- | --- |
| Target resource group | Contributor | Creating the storage account and, for the demo, the app and workspace |
| Workspace's resource group | Log Analytics Contributor | Creating the export rule |
| Storage account | Storage Blob Data Reader or higher | Reading blobs back, including from `verify.sh` |

Contributor on the storage account does **not** grant data-plane access. Reading a blob needs a data role, and with shared key access disabled there is no key to fall back on. Grant yourself Storage Blob Data Reader if you intend to look at the contents.

A data role is necessary but not sufficient. The account deploys with its public endpoint disabled, so a client outside the virtual network is refused regardless of what it holds. See [Checking the archive](#checking-the-archive).

### Networking

`main.bicep` creates a virtual network with two subnets, because the demo has to stand alone. `retention-only.bicep` takes both of these as parameters instead:

| Parameter | What it needs |
| --- | --- |
| `privateEndpointSubnetResourceId` | An existing subnet with `privateEndpointNetworkPolicies` **disabled**. Without that the endpoint deploys and then receives no traffic. |
| `privateDnsZoneResourceId` | An existing `privatelink.blob` zone, **linked to the network your clients sit in**. A zone that exists but is not linked resolves nothing, and the symptom is a 403 rather than a DNS error. |

Both are usually owned by a platform team. Leaving `privateDnsZoneResourceId` empty creates the endpoint without registration, which is only right if someone else registers it.

### Checking the archive

With the public endpoint disabled, `verify.sh` cannot reach the blobs from your machine and will say so. Use the in-network check instead:

```bash
./scripts/verify-private.sh \
  --resource-group <rg> \
  --storage-account <name> \
  --subnet <verifier-subnet-id>
```

`main.bicep` outputs the subnet as `verifierSubnetResourceId`. The script creates a user-assigned identity, grants it Storage Blob Data Reader, runs a container in that subnet, prints what the container could see, and removes both. Add `--keep` to leave them in place for debugging.

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

## Production: add retention to an estate you already have

`infra/retention-only.bicep` is the template for the common case, where the application, its Application Insights component and the Log Analytics workspace all exist already and only the retention tier is missing.

| | Yours, untouched | Created by the template |
| --- | --- | --- |
| Log Analytics workspace | ✓ | |
| Application Insights | ✓ | |
| App Service | ✓ (see below) | |
| Virtual network, subnet, private DNS zone | ✓ | |
| WORM storage account | | ✓ |
| Containers and immutability policies | | ✓ |
| Blob diagnostics | | ✓ |
| Blob private endpoint | | ✓ |
| Data Export rule | | ✓ (on your workspace) |

Application Insights is not referenced at all. It already writes to the workspace, and the export rule reads from the workspace, so the template has no reason to touch it.

The App Service is touched only if you ask. Supplying `appServiceResourceId` adds a diagnostic setting so `AppServiceHTTPLogs` reaches the workspace and can be exported. That is additive, does not disturb settings the app already has, and leaves the app as it was if you later remove it. Omit the parameter if your platform team already wires app diagnostics, or if `AppEvents` alone is what you need retained.

!!! note "`appServiceResourceId` has had less exercise than the rest"

    Everything else here has been deployed and watched working. This one parameter has not: the subscription it was built against had no App Service quota left to stand a throwaway app up on, so the branch is compile-checked rather than run.

    It creates a single diagnostic setting through the same scoped-module pattern as the export rule, which is proven, so there is not much room for it to go wrong. The realistic failure is a category your plan does not support, and that fails at deployment with a message naming the category rather than doing anything quiet.

    Deploy it once on its own before adding `AppServiceHTTPLogs` to `exportTables`, and check the setting appears under the app's **Diagnostic settings** blade.

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

`StorageBlobLogs` cannot be included on the first run. It comes from the blob diagnostics these templates create, so it does not exist until after the first deployment has completed and emitted a record. **Add it on a later run.** It puts the record of who has read the archive under the same protection as the archive, which is normally why you are keeping one.

To add a table, uncomment it in the parameters file and redeploy. The matching container is created with its retention policy at the same time as the rule is updated.

!!! note "Redeploying does not retrofit policies"

    If export has already created a container by itself - because it was named in the rule but not in the container list - a later deployment will not add a policy to it. Apply one directly, and treat everything already in that container as unprotected.

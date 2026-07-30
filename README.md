# azure-immutable-audit-logs

Ship application audit and security events into write-once, read-many (WORM) blob storage, where they cannot be altered or deleted for a fixed retention period, using only Azure Monitor plumbing that is already there.

Bicep-provisioned, one command up, one command down. Includes a demo app that emits the events, so you can watch a record travel the whole path end-to-end.

**Documentation: <https://lukeevanstech.github.io/azure-immutable-audit-logs/>**

## The pipeline

```text
Application  ->  Application Insights  ->  Log Analytics  ->  Data Export  ->  Immutable blobs
 TrackEvent        workspace-based           AppEvents        ~5 min batches      WORM, 6 years
```

The application calls `TrackEvent`. Everything after that is configuration - custom events land in `AppEvents`, which is a standard Log Analytics table and therefore exportable, so **no application change is needed beyond the telemetry calls you would write anyway**.

## Why

Plenty of systems log what users did. Rather fewer can prove the log has not been edited since.

If an audit trail exists to answer a question after the fact, then anyone with administrative access to the logging system is a hole in it: retention can be shortened, rows deleted, tables dropped, none of it leaving a mark. A locked immutable container closes that - the records cannot be modified or deleted by anyone for the retention period, including subscription owners and Microsoft support.

## Quickstart

Prerequisites: Azure CLI (signed in), `jq`, `zip`, and the .NET 10 SDK if you want the demo app. `mise install` picks up the pinned versions.

```bash
git clone https://github.com/LukeEvansTech/azure-immutable-audit-logs.git
cd azure-immutable-audit-logs

./scripts/deploy.sh --resource-group rg-auditlogs-demo --location uksouth
```

Add `--enable-auth` to put Entra ID sign-in in front of the app, so events carry a real user identity.

Then open the app URL, generate some events, and check they landed:

```bash
./scripts/verify.sh --resource-group rg-auditlogs-demo \
  --storage-account <storage-account> --workspace-guid <workspace-guid>
```

When you are finished:

```bash
./scripts/teardown.sh --resource-group rg-auditlogs-demo --purge-workspace
```

> **Export takes around 30 minutes to provision** before it writes anything. Events generated during that window may never reach storage. This is the single most common "it is broken" report, and it is not broken.

## Production

Two entry points, sharing the same retention module.

|                                    | `infra/main.bicep`        | `infra/retention-only.bicep` |
| ---------------------------------- | ------------------------- | ---------------------------- |
| **For**                            | Seeing it work end-to-end | Production                   |
| Log Analytics workspace            | Created                   | **Yours**, untouched         |
| Application Insights               | Created                   | Untouched                    |
| Demo app                           | Created                   | Not deployed                 |
| WORM storage, containers, policies | Created                   | Created                      |
| Data Export rule                   | Created                   | Created                      |

`retention-only.bicep` adds the retention tier to a workspace you already own, creating nothing inside it beyond the export rule. It handles the workspace living in a different resource group or subscription from the storage account.

```bash
cp infra/retention-only.example.bicepparam infra/retention-only.bicepparam
# set workspaceResourceId, and location if the target RG is in another region

az deployment group create \
  --resource-group <target-rg> \
  --template-file infra/retention-only.bicep \
  --parameters infra/retention-only.bicepparam
```

See the [deployment guide](https://lukeevanstech.github.io/azure-immutable-audit-logs/deployment/) for permissions, deriving the workspace from an Application Insights component, and adding tables later.

## Design decisions worth knowing

- **Containers are created with retention policies already attached**, before the export rule exists. Letting export create its own containers and applying policies afterwards leaves a window where records land unprotected - and a later policy does not retrospectively cover them.
- **Shared key access is off by default**, so every read goes through Entra ID and appears in the blob access log with the reader's identity. With keys enabled, reads are recorded as anonymous.
- **Telemetry sampling is disabled in the app.** It is on by default in the SDK, and it silently discards a proportion of events - which is right for performance monitoring and wrong for an archive whose value is completeness.
- **Locking is a separate script with its own confirmation.** Policies deploy unlocked. Locking is irreversible, and `scripts/lock-retention.sh` makes you type `LOCK`.
- **`teardown.sh` refuses to run against locked policies**, because the delete would fail part-way and strand the resource group.

## Locking retention

```bash
./scripts/lock-retention.sh --resource-group <rg> --storage-account <storage-account>
```

**This cannot be undone.** A locked policy cannot be removed, shortened or unlocked by anyone. The period can only be extended, and neither the storage account nor its resource group can be deleted until every blob has passed its retention - six years, on the default. Decide the retention period before locking, and never lock the demo.

Nothing locks anything automatically. Both templates deploy policies **unlocked**, and `lock-retention.sh` is the only thing that locks, interactively, after making you type `LOCK`.

> **Unlocked still protects the data, but never traps you.** Under an active unlocked policy a blob delete is rejected with `BlobImmutableDueToPolicy`, exactly as under a locked one - so the demo genuinely demonstrates immutability. Deleting the storage account, however, succeeds and takes the blobs with it. That asymmetry is the entire practical difference: **unlocked means you can always get rid of it.** Locked removes that escape hatch for the full retention period.

## Repository layout

| Path       | Contents                                                                    |
| ---------- | --------------------------------------------------------------------------- |
| `infra/`   | `main.bicep`, `retention-only.bicep`, shared `modules/`, example parameters |
| `app/`     | .NET 10 demo app and its test console UI                                    |
| `scripts/` | `deploy.sh`, `verify.sh`, `lock-retention.sh`, `teardown.sh`                |
| `docs/`    | Documentation site source (Zensical)                                        |

## Verification

CI builds both Bicep templates and both parameter files, compiles and publishes the app with warnings as errors, runs ShellCheck over the scripts, and builds the docs site.

There is no unit test suite: the app is a telemetry emitter with no logic worth isolating, and the meaningful verification is end-to-end, which is what `scripts/verify.sh` does against a live deployment. It checks container protection, blob arrival, and the KQL surfaces, and optionally attempts a delete that must fail.

## Cost

Blob storage grows without bound for the retention period, because nothing can be deleted - six years of a busy application is the number to model before locking anything. On top of that: Log Analytics ingestion at your workspace rate, blob diagnostics (which are themselves ingested, and never go quiet because export writes every five minutes), and for the demo, a B1 App Service plan.

## License

MIT. See [`LICENSE`](LICENSE).

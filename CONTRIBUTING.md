# Contributing

Orientation for anyone changing this repository, and a record of the decisions that
look like mistakes until you know why they were made.

This repo ships application audit and security events into immutable (WORM) blob storage
using Azure Monitor plumbing: an app calls `TrackEvent` -> Application Insights ->
Log Analytics `AppEvents` -> Data Export -> storage containers with immutability policies.
Bicep-provisioned, one command up, one command down. A demo .NET app emits the events so
the pipeline can be seen working end-to-end.

## Key paths

- `infra/main.bicep` - self-contained demo: workspace, App Insights, App Service, WORM
  storage, export rule.
- `infra/retention-only.bicep` - production entry point: adds the retention tier to a
  workspace the operator already owns. Handles the workspace being in another RG or
  subscription via a scoped module.
- `infra/modules/worm-storage.bicep` - shared by both. Storage account, containers,
  immutability policies, blob diagnostics.
- `app/` - .NET 10 demo app (`Program.cs`, `Services/TelemetryService.cs`,
  `wwwroot/index.html` test console).
- `scripts/` - `deploy`, `verify`, `lock-retention`, `teardown`, each as a `.sh` and a
  `.ps1` twin. Keep the pair in step: a change to one belongs in the other.
  The `.ps1` files use `Write-Output`, never `Write-Host` - PSScriptAnalyzer's
  `PSAvoidUsingWriteHost` is enforced in CI and by super-linter.
- `docs/` - Zensical documentation site, published to GitHub Pages by `.github/workflows/docs.yml`.

## Commands

- `az bicep build --file infra/main.bicep --stdout > /dev/null` - compile check.
- `dotnet build app/AuditLogDemo.csproj` - the app's static gate (TreatWarningsAsErrors).
- `shellcheck --severity=style scripts/*.sh`
- `zensical build` - build the docs site (needs `pip install -r docs-requirements.txt`).
- `./scripts/deploy.sh --resource-group <rg>` then `./scripts/verify.sh ...`

## Things not to "fix"

- **Containers are created before the export rule, on purpose.** Reordering them
  reintroduces a window where records land unprotected.
- **`allowProtectedAppendWrites: true` is required**, not a weakening. Exported blobs are
  append blobs; without it export stops writing.
- **`allowSharedKeyAccess` defaults to false on purpose.** It is what makes reads
  attributable in `StorageBlobLogs`. It also means every `az storage` call needs
  `--auth-mode login`.
- **Sampling is explicitly disabled** in `Program.cs`. It is on by default in the SDK and
  drops events without saying so, which is fatal for an archive whose value is
  completeness.
- **`retention-only.bicep` takes `workspaceResourceId` as a parameter** rather than
  deriving it from an Application Insights component. Deriving it fails `BCP120`: module
  `scope` needs a start-of-deployment value and any property read off an `existing`
  resource is a runtime `reference()`. The derivation command lives in `docs/deployment.md`.
- **Locking is a separate script**, not a deployment flag. It is irreversible.
- **`publicNetworkAccess` defaults to `Disabled`.** Export still writes: it goes through the
  Azure Monitor platform, not as a network client. Confirmed on a live deployment, not
  inferred. Do not "fix" this by opening the account up because a read failed.
- **`bypass: 'AzureServices'` stays even when public access is disabled**, so flipping back
  to `Enabled` cannot silently drop the export path.
- **Storage is pinned to TLS 1.2.** `TLS1_3` is in the ARM enum and the AVM allow-list, and
  the resource provider rejects it: `FeatureNotSupported`. App Service does accept 1.3.
- **The two subnets cannot be merged.** A private endpoint subnet needs network policies
  disabled; an ACI-delegated subnet cannot host anything else.
- **No unit test suite**, by choice: the app has no logic worth isolating and the
  meaningful check is end-to-end via `verify.sh`. Don't add one unasked.

## Rules

- Run the repo's linters before pushing: super-linter (via `LukeEvansTech/shared-workflows`),
  `az bicep build`, `dotnet build`, `shellcheck`, `zensical build`.
- Never commit `infra/*.bicepparam` (only the `.example.` ones), or anything containing
  subscription IDs, tenant IDs, workspace resource IDs, IP addresses or email addresses -
  this repo is public.
- This repo is generic by design. It carries no client, customer or engagement references,
  and none should be introduced. Sample data and example values use reserved documentation
  ranges (`example.com`, `203.0.113.0/24`).

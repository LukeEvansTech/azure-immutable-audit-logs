# Retrieving records

Getting records back out, in a way that stands up when someone asks how you got them.

An archive nobody can read is not much better than no archive. An archive anyone can read without leaving a trace is arguably worse than none, because it invites the assumption that reads were controlled when they were not. This page covers the mechanics of retrieval and the evidence that should come with it.

## Pick the surface first

Two places hold the same records, and which one you use is decided by how old the data is.

| | Log Analytics | Blob storage |
| --- | --- | --- |
| **Covers** | The workspace retention window (default 30 days) | The full retention period (default 6 years) |
| **Interface** | KQL | File download plus local filtering |
| **Good for** | Filtering, joining, aggregating, "show me everything this user did" | Bulk export, anything older than the hot window |
| **Effort** | Minutes | Proportional to the time range |

**If the period requested falls inside the workspace window, use KQL.** It is faster, filters server-side, and produces a clean result set. Go to the blobs only when the data has aged out, or when you need the archived artefact itself rather than a query result.

## Before you start

**Fix the time range in UTC.** Everything stored is UTC. The blob path is UTC. A request phrased in local time during British Summer Time is an hour out, which is exactly the kind of error that surfaces only when someone notices a gap. Convert once, write it down, and use the converted values throughout.

**Grant access as a decision, not a default, and time-box it.** Retrieval needs a data-plane role, which routine platform administration does not include:

```bash
az role assignment create \
  --assignee "<upn-or-object-id>" \
  --role "Storage Blob Data Reader" \
  --scope "<storage-account-resource-id>"
```

Read-only is sufficient and is the correct level: nothing about retrieval requires the ability to write. Remove it when the work is done - see [Afterwards](#afterwards).

**Confirm what you actually have** before assuming a role is missing. In the portal this is **Access control (IAM)** then **View my access** on the storage account.

## Route 1: KQL, for data inside the workspace window

```kusto
AppEvents
| where TimeGenerated between (datetime(2026-07-01T00:00:00Z) .. datetime(2026-07-31T23:59:59Z))
| where tostring(Properties.UserId) == "someone@example.com"
| project TimeGenerated,
          EventName   = Name,
          UserId      = tostring(Properties.UserId),
          Severity    = tostring(Properties.Severity),
          Outcome     = tostring(Properties.Outcome),
          Path        = tostring(Properties.Path),
          Method      = tostring(Properties.Method),
          StatusCode  = tostring(Properties.StatusCode)
| order by TimeGenerated asc
```

!!! warning "`Properties.UserId`, not `UserId`"

    `AppEvents` has a built-in `UserId` column holding the SDK's anonymous session identifier. The signed-in principal is in `Properties.UserId`. Projecting the built-in column returns a plausible-looking answer that is not the person.

From the CLI:

```bash
az monitor log-analytics query \
  --workspace "<workspace-guid>" \
  --analytics-query "$(cat query.kql)" \
  --output json > results.json
```

`--workspace` takes the workspace **GUID** (its `customerId`), not the resource ID.

### Query limits

The portal and the query API cap results at **500,000 records, roughly 100 MB, and 10 minutes**. A broad range over a busy application will hit one of these, and the portal's own **Show** limit defaults lower still - so a result that looks complete may be truncated.

Check the row count before trusting a result:

```kusto
AppEvents
| where TimeGenerated between (datetime(...) .. datetime(...))
| summarize Records = sum(ItemCount)
```

`sum(ItemCount)` rather than `count()`: if sampling has been enabled anywhere upstream, each retained row stands for `ItemCount` originals and a plain count under-reports.

If you are near the ceiling, narrow the range and run several passes, or use a [search job](https://learn.microsoft.com/azure/azure-monitor/logs/search-jobs) for up to 100 million rows.

## Route 2: blobs, for anything older

Records live under a deeply nested, UTC-based path:

```text
WorkspaceResourceId=<lowercased workspace resource id>/y=2026/m=07/d=30/h=16/m=25/PT5M.json
```

!!! danger "Three ways this path bites"

    - **`m=` appears twice.** After `y=` it is the month; after `h=` it is the minute.
    - **The filename spelling is contested.** `PT5M.json` and `PT05M.json` both circulate. Every blob written by the deployment behind this documentation was `PT5M.json`. Do not hardcode either - glob the folder.
    - **Busy windows overflow** into numbered siblings in the same folder. Enumerate it rather than fetching one known filename, or you drop the busiest five minutes of the day and never find out.

Download a day:

```bash
az storage blob download-batch \
  --account-name "<storage-account>" \
  --source am-appevents \
  --destination ./extract \
  --pattern "*/y=2026/m=07/d=30/*" \
  --auth-mode login
```

`--auth-mode login` is not optional. Without it the CLI falls back to account-key authorisation, which the account rejects by default - and if keys were enabled, the read would be recorded as anonymous, defeating the attribution below.

!!! warning "The portal prefers the account key"

    Browsing containers in **Storage browser**, the portal authorises with the account key whenever your identity is able to retrieve one, without telling you. Check the authentication method shown at the top of the container view and switch it to Entra ID before downloading anything. A key-authorised read appears in the access log with no user attached.

### Merging

The files are newline-delimited JSON - one record per line, no enclosing array. `json.load` on a whole file fails.

```bash
# Concatenate, filter to a time range, and emit a single JSON array.
find ./extract -name '*.json' -print0 \
  | xargs -0 cat \
  | jq -c 'select(.TimeGenerated >= "2026-07-30T09:00:00Z"
                  and .TimeGenerated <= "2026-07-30T17:00:00Z")' \
  | jq -s '.' > extracted.json

jq 'length' extracted.json
```

Record the count. It is the first thing anyone receiving the extract will ask for, and the first thing to check against the KQL count if both routes covered the same period.

## The audit of the audit

The retrieval is itself an auditable event, and this is the part most often skipped.

Because blob diagnostics are enabled, every read lands in `StorageBlobLogs`. Capture the evidence of your own extraction as part of the extraction:

```kusto
StorageBlobLogs
| where TimeGenerated between (datetime(<start>) .. datetime(<end>))
| where OperationName in ("GetBlob", "ListBlobs")
| project TimeGenerated,
          OperationName,
          RequesterUpn,
          AuthenticationType,
          Uri,
          StatusText
| order by TimeGenerated asc
```

`RequesterUpn` is populated only for Entra ID authorised requests. If `AuthenticationType` reads as shared key and `RequesterUpn` is empty, the read was made with the account key and **cannot be attributed to a person**. That is a finding, not a formatting quirk: it means the retrieval has no reliable record of who performed it.

Keep that output with the extract. Together they answer the two questions that follow any disclosure: what was released, and who took it out.

## Afterwards

Remove the access you granted:

```bash
az role assignment delete \
  --assignee "<upn-or-object-id>" \
  --role "Storage Blob Data Reader" \
  --scope "<storage-account-resource-id>"
```

Standing access to an immutable archive undermines the point of having one. The records cannot be altered, but who has been reading them is a separate question, and the honest answer should be a short list.

Then confirm it is gone, rather than assuming the command worked:

```bash
az role assignment list \
  --assignee "<upn-or-object-id>" \
  --scope "<storage-account-resource-id>" \
  --output table
```

## A note on governance

This page covers only the technical half. Who may request an extract, who authorises it, what is recorded about the request, how the result is transmitted and how long the copy is kept are organisational questions, and the right answers differ by sector and jurisdiction.

Worth settling before the first real request, not during it:

- who can raise a request, and to whom
- who authorises release, and whether that is the same person
- what the requester is told about scope and completeness, including the effect of the workspace window on anything requested near the boundary
- how the extract is transmitted, and what happens to it afterwards

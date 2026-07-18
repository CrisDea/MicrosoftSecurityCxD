# Defender Migration Dashboard

A self-contained Power BI dashboard for running and reporting on a **Microsoft Defender for
Endpoint (MDE) + Defender Antivirus (MDAV) migration** — for example, moving off a third-party
EDR/AV such as Trend Micro. It tracks deployment progression, version compliance
(AV signature / AV engine / Defender platform / MDE sensor), a client-vs-server split, OS posture,
the third-party AV and EDR products still present across the estate, and a device-level triage list
of non-compliant machines.

The dashboard reads **live from your own Microsoft Defender for Endpoint tenant** through the
Defender export-assessment REST APIs (`api.securitycenter.microsoft.com`) — no data lake, no
Sentinel, and no Log Analytics required, and no 10,000-row hunting cap, so it scales to 100k+ device
estates. A one-command deployment publishes the semantic model and report to a Power BI / Microsoft
Fabric workspace, binds the data source to your Entra app registration (a **Service Principal**),
generates the 30-day trend history, and enables a scheduled refresh so the report keeps itself up to
date with no local scheduler.

---

## Why this exists

Migrations off a third-party EDR/AV need an operational, repeatable view of progress that a customer
can keep using after the engagement:

- **Migration maturity** — active vs stale/removed devices over time, not a point-in-time snapshot.
- **Version compliance** — clear visibility of devices behind on AV signature, AV engine, Defender
  platform, or MDE sensor versions, with simple KPIs.
- **Third-party footprint** — how many machines still run each third-party antivirus and EDR product,
  so you can target what remains.
- **Operational triage** — a device-level table of non-compliant machines for follow-up.
- **OS-centric reporting** — posture broken down by OS platform, version and build.
- **Client vs Server** — first-class separation, with client-first emphasis.

## Requirements coverage

| Requirement | Where it is delivered |
|-------------|------------------------|
| Deployment progression — active vs stale/removed **trend** (not a point-in-time snapshot) | **Migration Overview** page (active vs stale by client/server) and a 30-day day-by-day **DeploymentTrend** by machine group, materialised at deploy time from Defender advanced hunting. "Stale" is the `StaleAfterDays` parameter. |
| Version compliance — AV signature, AV engine, Defender platform, MDE sensor | **Version Compliance** page (KPIs + "devices not on latest" by component) and per-check pies on **Configuration Drill-down**. Targets set in the `LatestBaselines` table. |
| Third-party AV / EDR footprint | Histograms of **machines by third-party antivirus product** and **machines by EDR solution** on the **Overview** page (product name on X, machine count on Y). |
| Non-compliant devices — device-level triage table | **Non-Compliant Devices** page, plus **Device Details** drill-through for the full per-device record + Export data. |
| Client vs Server split (client first) | `DeviceType` slicer on every page; client-vs-server splits on **Overview** and **Migration Overview**. |
| OS-centric reporting — OS platform, version/build, breakdowns | **OS Posture** page; `OSPlatform` / `OSDistribution` filters available in the **Filters pane** on every page. |
| Filters/selectors — Client/Server, OS platform, device group/tags, onboarding status, active/stale | Searchable filter rail on every page, including **MDE tags**, Onboarding status, and Active/Stale. |

## What you get

| Path | What |
|------|------|
| `pbip-project/` | The full **PBIP project** (TMDL semantic model + PBIR report). Opens in Power BI Desktop, commits to Git, and publishes via the deploy script. DeviceHealth queries the Defender export APIs live; the trend history is embedded at deploy time; no customer data is baked into the committed files. |
| `deploy/Deploy-Dashboard.ps1` | **One-button deployment** — publishes the semantic model + report, binds the data source to your Entra app (Service Principal), generates the trend history, enables scheduled refresh, and runs a first refresh. |
| `deploy/Import-TrendInventory.ps1` | Standalone **Trend Micro CSV ingest** — matches a Trend device export to the current Defender inventory (exact hostname, domain-only fuzzy) and previews the mapping; `-Materialize` embeds it into the **TrendMigration** table for the next deploy. |
| `deploy/Export-Report.ps1` | Headless export of the published report to PDF / PPTX. |
| `deploy/Bootstrap-Deployment.ps1` | Creates **or reuses** an Entra app registration for deployment and the live data path, and grants the required WindowsDefenderATP permissions (`Machine.Read.All`, `Software.Read.All`, `Vulnerability.Read.All`, `AdvancedQuery.Read.All`). |
| `deploy/assets/DeploymentTrend.kql` | The 30-day advanced-hunting query the deploy script runs to build the trend history seed. |
| `deploy/config.json.template` | Template for the app credentials and workspace settings (copy to `config.json`, which is git-ignored). |
| `templates/defender-kql-pack.kql` | KQL for inventory, AV health, sensor version, active-vs-stale trend, and compliance. |
| `templates/power-query-source.m` | Reference Power Query M for the Defender export-API app-only source. |
| `templates/dax-measures.dax` | The DAX measures (population, active/stale, compliance %). |

## Prerequisites

- **PowerShell 7.x** (or Windows PowerShell 5.1) — no third-party modules.
- **Azure CLI** (`az`) for interactive sign-in to publish to Fabric, or an Entra app registration for
  service-principal deployment.
- An **Entra app registration** with the four **WindowsDefenderATP** application permissions
  (`Machine.Read.All`, `Software.Read.All`, `Vulnerability.Read.All`, `AdvancedQuery.Read.All`,
  admin-consented). Its `tenantId` / `clientId` / `clientSecret` are bound to the dataset as a
  Service Principal and used to generate the trend history. `Bootstrap-Deployment.ps1` can create or
  reuse one for you.
- A **Power BI / Fabric workspace** on a capacity that supports semantic models
  (Fabric, Premium, or Premium-Per-User). The script can create the workspace for you if you pass a
  capacity id.
- Rights to publish to that workspace (Workspace Admin or Member).

## Quick start (3 commands)

```powershell
# 1. Create/reuse the Entra app and grant the WindowsDefenderATP permissions (writes deploy/config.json)
pwsh ./deploy/Bootstrap-Deployment.ps1 -Mode CreateNew -DisplayName "defender-migration-dashboard"

# 2. Sign in to publish to Fabric, then deploy (credentials come from config.json)
az login
pwsh ./deploy/Deploy-Dashboard.ps1 -ConfigPath ./deploy/config.json -SelectWorkspace -Wait

# 3. Open the report at the URL the script prints when it finishes
```

That publishes the semantic model and report, binds the report to the model, binds the data source to
your app as a Service Principal, generates the 30-day trend history, enables a scheduled refresh, and
runs a first refresh so the report shows your real Defender data.

> **Prefer prompts to switches?** Run `pwsh ./deploy/Deploy-Dashboard.ps1` with **no parameters** to
> launch a guided wizard that walks you through config, workspace and options (see *Guided mode*).

### Other ways to target a workspace

```powershell
# Deploy into a specific existing workspace by id
pwsh ./deploy/Deploy-Dashboard.ps1 -ConfigPath ./deploy/config.json -WorkspaceId <workspace-guid>

# Create a new workspace on a given capacity
pwsh ./deploy/Deploy-Dashboard.ps1 -ConfigPath ./deploy/config.json -WorkspaceName "Defender Migration" -CapacityId <capacity-guid>

# Fully non-interactive (CI / service principal) — the same app publishes and queries
pwsh ./deploy/Deploy-Dashboard.ps1 -ConfigPath ./deploy/config.json -WorkspaceId <workspace-guid>
```

## Parameters (Deploy-Dashboard.ps1)

| Parameter | Purpose |
|-----------|---------|
| `-SelectWorkspace` | Enumerate accessible workspaces and choose one interactively (includes a "create new" option). |
| `-WorkspaceId` | Deploy into a specific workspace by GUID. |
| `-WorkspaceName` | Find (or, with `-CapacityId`, create) a workspace by name. |
| `-CapacityId` | Capacity to create the workspace on when it does not yet exist. |
| `-ModelName` / `-ReportName` | Display names for the published items. |
| `-ConfigPath` | Path to a `config.json` holding the app credentials + workspace (see Bootstrap). |
| `-ClientId` / `-ClientSecret` / `-TenantId` | App credentials passed directly instead of a config file. |
| `-SkipRefresh` | Publish without triggering a dataset refresh. |
| `-SkipSchedule` | Publish without enabling the scheduled refresh. |
| `-TrendCsv` | Path to a Trend Micro device export (CSV). At deploy time each Trend device is matched to the current Defender inventory and the result is embedded in the **TrendMigration** table (see *Trend Micro migration mapping*). Omit to **reuse the previously ingested list** (it is no longer emptied). |
| `-TrendMode` | `Replace` (default) — the supplied export becomes the whole Trend list; `Append` adds only new devices to the git-ignored local master store. Both de-duplicate on the Trend id. Also settable as `trendMode` in config.json. |
| `-CheckVersionOnly` | Read-only: report local/GitHub/live versions and whether an update is available, then exit. Needs only workspace **Viewer**. |
| `-Force` | Deploy even when the workspace is already current (refresh live data / re-seed trend + AV tables). |
| `-SkipVersionCheck` / `-SkipGitHubCheck` | Skip the whole preflight (offline) / skip only the GitHub comparison. |
| `-SkipGitHubRestore` | Do not auto-download missing/corrupt local content from GitHub (fully offline runs). Also `skipGitHubRestore` in config.json. |
| `-MatchThreshold` | Domain-suffix fuzzy-match acceptance score (0–100). The short hostname must always match exactly; this governs only how much the DNS domain may differ. Default `82`. Lower to accept looser domains; raise to require closer domains. |
| `-RemovedAfterDays` | Noise filter. When > 0, devices whose Defender "last seen" is older than this many days are excluded from the model (treated as decommissioned). Default `0` = keep all. Also settable as `removedAfterDays` in config.json. |
| `-RefreshTimes` | Times of day (`HH:mm`) for the scheduled refresh. Default: 2×/day (06:00, 18:00) — TVM snapshot tables refresh ~daily. |
| `-RefreshTimeZone` | Time-zone id for the schedule (e.g. `UTC`, `GMT Standard Time`). Default `UTC`. |

The app credentials are used to bind the Defender data source (as a Service Principal) and to
generate the trend history at deploy time; when you pass them via `-ClientId`/`-ClientSecret` or a
`config.json`, the same app can also publish to Fabric. If you prefer to publish as yourself, run
`az login` and supply only the app credentials — the script signs in interactively for Fabric and
still binds the data source. If you want a **separate** app for the Defender query, set
`graphTenantId` / `graphClientId` / `graphClientSecret` in `config.json`.

## How the live data path works

1. **DeviceHealth (current state)** — the semantic model's DeviceHealth query calls the Microsoft
   Defender for Endpoint export/list machine APIs on `api.securitycenter.microsoft.com` with a plain
   GET (no in-query token, no second data source). The deploy script binds that data source to your
   Entra app as a **Service Principal**, so Power BI mints and attaches the app-only bearer token
   itself on every scheduled refresh. Keeping it a single-source query is what sidesteps the Power
   Query data-combination firewall that blocks the older "mint a token, then call the API" pattern on
   cloud refresh. The paged export APIs have no 10,000-row hunting cap, so this scales to 100k+
   devices.
2. **DeploymentTrend (30-day history)** — the advanced-hunting endpoint is POST-only and cannot run
   during a cloud scheduled refresh (a `Web.Contents` POST body is rejected on any non-Anonymous
   data source). So the 30-day day-by-day history is **materialised at deploy time**: the deploy
   script runs `deploy/assets/DeploymentTrend.kql` against the Defender advanced-hunting API,
   base64-encodes the aggregated result, and embeds it in the model. It is regenerated on every
   redeploy — so the trend advances each time you redeploy, while DeviceHealth stays live on the
   normal refresh cadence.
3. No secret is ever written to the committed project files. The DeviceHealth query carries no
   credentials, and the trend table carries only a base64 placeholder that the deploy script fills.

## Third-party AV / EDR classification

The two histograms count machines by the third-party product detected in `DeviceTvmSoftwareInventory`.
Product matching uses a **hardcoded catalogue** of enterprise antivirus and EDR/XDR vendors (Trend
Micro, Sophos, McAfee/Trellix, Symantec, Kaspersky, ESET, Bitdefender, and more for AV; CrowdStrike
Falcon, SentinelOne, Carbon Black, Cortex XDR, Cybereason, Tanium, and more for EDR), so the graphs are
generic across estates. Machines with none detected fall into a **None** bucket so the bars total the
full estate.

## Setting "latest version" baselines
Compliance measures compare each device against a **LatestBaselines** control table
(signature / engine / platform / sensor). Edit those values (in the model, or via the `Latest*`
parameters) to your current target versions — no query changes needed.

The "stale" threshold is a parameter (`StaleAfterDays`, default 7). Agree the value with the customer.

## Data hygiene and noise filters

The model is built to reflect the estate accurately, not to inflate counts:

- **Merged and excluded devices are dropped** (`mergedIntoMachineId` / `isExcluded`), so duplicates and
  suppressed machines never reach the report.
- **Onboarding backlog is honest.** `onboardingStatus` is split into *Onboarded*, *Can be onboarded*,
  *Unsupported*, and *Insufficient info*. Only genuinely onboardable devices count toward the
  Migration Backlog — devices Defender reports as *Unsupported* / *Insufficient info* are shown
  separately and no longer inflate the remaining-to-migrate figure.
- **Active vs Stale is onboarded-only.** The `Active Devices` / `Stale Devices` measures count only
  onboarded devices (recency by `lastSeen`), matching the population of the deployment-trend chart, so
  the two never disagree. Not-yet-onboarded discovered devices are excluded from this signal.
- **Optional removed-device cutoff.** `-RemovedAfterDays <n>` (default `0` = keep all) drops devices not
  seen in the last *n* days, removing long-decommissioned records that would otherwise drag the
  migration denominator. Set it to e.g. `180` for a noisy estate.
- **AV posture ignores pre-release rings.** The deploy-time AV currency baseline excludes Beta and
  Current-Channel-Preview rings, so a preview build never sets the fleet "latest" bar.
- **KPI cards show `0`, not blank**, when a count is genuinely zero, so an empty card is never mistaken
  for a data-load failure.
- **`Migration %` measures Trend-list coverage.** The headline `Migration %` is *healthy, onboarded MDE
  devices ÷ the ingested Trend asset list* (`Trend Source Devices`) — i.e. how much of the Trend estate
  is now protected by a healthy Defender sensor. It requires a Trend list (`-TrendCsv`); with no Trend
  list ingested the card shows **N/A** rather than a misleading 0%. The older onboarded-÷-all-Defender-
  devices ratio is retained separately as `MDE Onboarding Coverage %`.

## Pages
1. **Overview** — migration & configuration summary: fully-migrated KPIs, estate configuration state, client-vs-server and cloud/on-prem splits, healthy-by-OS, and the third-party AV / EDR histograms. The **estate configuration-state donut** spans the whole estate: green = fully migrated & configured, amber = onboarded but needs attention, **red = not onboarded but discovered and on the ingested Trend list**, **grey = on the Trend list only (never discovered by Defender)**. It is driven by the `EstateConfigState` table, which unions MDE-discovered devices with Trend-only devices so blind spots are visible.
2. **Configuration Drill-down** — per-check RAG posture (sensor, AV mode/signature/engine/platform, real-time, cloud, behaviour, tamper, network, PUA, OS), each drillable to device. The per-check pies use the full page width; slicing is via the native **Filters pane** (friendly-named filter cards), not an on-canvas rail.
3. **Device Inventory** — the full onboarded-device results table on its own full-page layout (moved off the drill-down page). Columns follow the **MDE Major Health Check (v2.9.5)** order and include the AV platform / engine / signature **update rings**, the AV signature version, and the OS update-currency columns (OS product, build/UBR, support state, EOL date, patch currency, months behind, EDR platform).
4. **Migration Overview** — active vs stale/removed trend by client/server (migration maturity).
5. **Trend Migration** — maps each device in your **Trend Micro export** to the current Defender inventory: Trend Source Devices, Trend Migrated, Trend Migration % and Trend Not In Defender KPI cards, a migration-status donut, and the full per-device mapping table (Trend name → Defender name, match type, score, onboarding status). Populated with `-TrendCsv` at deploy time — see *Trend Micro migration mapping*.
6. **Version Compliance** — KPIs and "devices not on latest" by component and OS.
7. **Non-Compliant Devices** — device-level triage table.
8. **OS Posture** — OS update-currency view: KPI cards (supported / EOL-imminent / unsupported, EDR legacy platform, monthly coverage), OS lifecycle-support and monthly patch-currency charts (Windows with UBR, fleet-relative), devices by OS product, and a detail table (product, build/UBR, support state, EOL date, patch currency, EDR platform, last seen).
9. **Mobile (MDE)** — mobile-device management state.
10. **Device Details** — a hidden drill-through page: right-click any chart element → *Drill through* to see the full per-device record, then **Export data**.
11. **KPI Guide** — a plain-language reference page explaining what every headline metric means, organised by the report page it appears on (no technical knowledge required).

Every visible page carries the same filters: Client/Server, OS platform,
OS version, Healthy, Managed by / onboarding, Trend installed, AD domain, Cloud/on-prem, Citrix VDI,
Onboarding status, Active/Stale, Sensor connectivity, **MDE tags**, and Last seen. These are now
presented consistently as cards in the native **Filters pane** on the right of every page (open it
with the filter icon); the previous on-canvas slicer rail has been removed.

## Versioning

The dashboard uses **calendar versioning**: `YYYY.MM.DD.XX`, where `XX` is the two-digit release
number within that day — it starts at `01`, increments for each release the same day, and resets to
`01` at midnight (for example `2026.07.17.01`). The current version is shown on the **KPI Guide** page
and heads each entry in [`CHANGELOG.md`](CHANGELOG.md).

### Checking and updating in place

`Deploy-Dashboard.ps1` runs a **version preflight** before every publish. It compares three versions
and only republishes when the workspace is behind, so re-running the script is a safe no-op when you
are already current:

| Source | Where it comes from |
| --- | --- |
| **Local content** | the `Version` marker on the KPI Guide page of the report you are about to deploy |
| **GitHub latest** | the top entry of `CHANGELOG.md` on the tracked branch, fetched over an unauthenticated raw URL (no GitHub credentials) |
| **Workspace (live)** | the version stamped on the semantic-model item's **description**, read with a single read-only Fabric `GET item` call |

```powershell
# Read-only: is a newer version available than what is live? (needs only Viewer / Item.Read.All)
.\Deploy-Dashboard.ps1 -ConfigPath .\config.json -WorkspaceId <guid> -CheckVersionOnly

# Normal run: updates in place only if the workspace is behind; no-op if already current
.\Deploy-Dashboard.ps1 -ConfigPath .\config.json -WorkspaceId <guid>

# Force a redeploy even when current (refresh live data / re-seed trend + AV tables)
.\Deploy-Dashboard.ps1 -ConfigPath .\config.json -WorkspaceId <guid> -Force
```

**Least privilege.** The update check reads the live version from the item description — a Fabric
`GET item` — so a plain workspace **Viewer** (`Item.Read.All`) can check for updates without any
deploy rights. Publishing the update still requires workspace **Contributor** (or Member). The
version is stamped onto the model description automatically after each successful publish.

Other switches: `-SkipVersionCheck` (offline/air-gapped runs), `-SkipGitHubCheck` (compare local vs
live only). In `config.json` you can set `"skipGitHubVersionCheck": true` or point at a fork with
`"githubRawChangelogUrl": "https://raw.githubusercontent.com/<owner>/<repo>/<branch>/DefenderMigrationDashboard/CHANGELOG.md"`.

### Guided mode (no parameters)

Run the deploy script with **no parameters** to get a step-by-step wizard instead of memorising
switches:

```powershell
.\Deploy-Dashboard.ps1
```

It walks through the config-file path, an action menu (check for updates only, or deploy/update in
place), workspace selection, whether to import an updated Trend CSV, force, and a final confirmation
before anything is published. Supplying **any** parameter runs the classic non-interactive path and
skips the wizard, so CI/automation is unaffected.

### Self-healing local content

Before every install/update the script deep-checks the local project (model and report `.tmdl`, seed
placeholders, `definition.pbir`, at least one report page, and non-empty KQL assets). If anything is
**missing or invalid**, it automatically re-downloads the `DefenderMigrationDashboard` folder from
GitHub and re-validates — so a partial clone or a corrupted file self-heals without a manual `git`
step. The restore is line-ending-insensitive and selective (only genuinely missing/different files
are replaced), so it never rewrites your whole working tree. Pass `-SkipGitHubRestore` (or
`"skipGitHubRestore": true` in `config.json`) to disable it for fully offline runs.

### Preserving ingested data across updates

Updates never lose data you have already ingested:

- The imported **Trend Micro device list** is reused automatically when you deploy **without**
  `-TrendCsv`, instead of being emptied. Pass `-TrendCsv` only when you actually want to replace or
  append the list.
- The **DeploymentTrend history** accumulates across deploys (it grows beyond the 30-day live query
  window) so the trend-over-time charts keep their history, and the last-known history is re-pushed if
  a live hunting query transiently returns zero rows.
- Both stores are **backed up** before every overwrite (timestamped, the last 15 kept, under
  `deploy/backups/`, which is git-ignored).

## Trend Micro migration mapping

The **Trend Migration** page answers "which of the devices in my Trend Micro estate are now in
Defender, and which still need migrating?" — using your Trend export as the source of truth.

- **Source of truth** — a CSV exported from Trend Micro. The **unique Trend id** (Apex One `GUID`,
  Deep Security `Host GUID`) and the **host-name** column are auto-detected; the id is the
  de-duplication key. Pass it with `-TrendCsv <path>` on `Deploy-Dashboard.ps1`, or preview/ingest it
  with the standalone `deploy/Import-TrendInventory.ps1`. Imports **Replace** the list by default or
  **Append** new devices only (see *Replace vs Append* below).
- **Matched against the same inventory as the dashboard** — the current Defender device list is read
  from the paged `GET /api/machines` export endpoint (the same source as DeviceHealth), so the
  mapping never disagrees with the rest of the report. Only `Machine.Read.All` is required.
- **Exact hostname, domain-tolerant matching** — the **short hostname must match exactly** (after
  normalising case, a trailing `$`, and punctuation), so two different machines are never conflated.
  Fuzzy tolerance is applied **only to the DNS domain suffix**: a device whose hostname matches is
  still accepted when its domain differs but scores at or above `-MatchThreshold` (default 82) — e.g.
  `ws01.contoso.com` vs `ws01.contoso.local` — and classified as a **Fuzzy** match. A hostname with
  no domain (short name, or the AD `$` form) matches any domain for that host, preferring an onboarded
  record on ties. Each row is classified **Migrated to Defender** (matched + onboarded),
  **Matched — not onboarded**, or **Not found in Defender**. A same-host / very different-domain pair
  (e.g. `ws09.contoso.com` vs `ws09.fabrikam.com`) is **rejected**.
- **Why it is a deploy-time ingest, not an in-report file upload** — the model refreshes in the
  Power BI service as a Service Principal with no on-premises data gateway, so a locally uploaded file
  cannot be re-read on a cloud refresh. The mapping is therefore computed at deploy time and embedded
  in the **TrendMigration** table (the same deploy-time seed pattern as the trend history). Re-run the
  deploy (or `Import-TrendInventory.ps1 -Materialize`) whenever the Trend export changes.

### Trend CSV format

The ingest reads a CSV and needs only two things per device — its **unique Trend id** and its
**host name** — so you can hand it a raw Trend Micro export or a minimal hand-built list.

**Columns ingested (the bare minimum):**

| Field | Purpose | Auto-detected from |
|-------|---------|--------------------|
| **Trend id** (required for de-dup) | The tool's own unique device identifier — the de-duplication key across imports | Apex One `GUID`; Deep Security `Host GUID` (preferred) or `Agent GUID`; or a `TrendId` column |
| **Device name** (required) | Host/endpoint name — matched against the Defender inventory | `Endpoint`, `Endpoint Name`, `Host Name`, `Hostname`, `Computer Name`, `Device Name`, `Machine Name`, `Name`, `DeviceName` |
| **Trend source** (optional) | Which Trend product the row came from (for reporting) | Inferred from the header signature (Apex One vs Deep Security), a `TrendSource` column, or the `-Source` override |

Everything else in the export is ignored. Both native Trend exports work as-is:

- **Apex One – Security Agents** export → id `GUID`, name `Endpoint`, source auto-detected as *Apex One*.
- **Deep Security – Computers** export → id `Host GUID`, name `Name`, source auto-detected as *Deep Security*.

Notes:

- **FQDN or short hostname both accepted.** `WS01`, `WS01.contoso.com`, and the AD form `WS01$` all
  resolve to the same host. Only the part **before the first dot** is treated as the hostname; the
  rest is the domain suffix used for the domain-only fuzzy step.
- **De-duplication is keyed on the Trend id.** The same device appearing twice (or re-imported) is
  counted once. When a row has no usable id, a normalised `host|source` key is used as a fallback.
- **Encoding/quoting** — a standard comma-separated, UTF-8 CSV with a header row. Values may be quoted.
- **`.xls`/`.xlsx` exports must be saved as CSV first.** Trend consoles (and sensitivity-label /
  IRM-protected exports) often produce `.xls`; open it and *Save As → CSV UTF-8* before ingesting.

Minimal hand-built list (matches the starter template):

```csv
TrendId,DeviceName,TrendSource
11111111-1111-1111-1111-111111111111,WS01.contoso.com,Apex One
22222222-2222-2222-2222-222222222222,FILESERVER01,Deep Security
```

A blank, header-only starter is provided at
[`templates/trend-inventory-template.csv`](templates/trend-inventory-template.csv) — copy it, add one
row per Trend device, and pass the file with `-TrendCsv`. It ships with **no rows** (structure only);
the repository never contains real or sample device data.

### Replace vs Append (updating the ingested list)

Every import merges into a **local master store** (`deploy/trend-inventory.local.csv`, git-ignored —
it holds customer device data). Two modes control how future imports update that list:

| Mode | Behaviour | Use when |
|------|-----------|----------|
| **Replace** (default) | The supplied export becomes the entire Trend list (wipes the previous one), de-duplicated on the Trend id. | You have a single, complete export and want the list to mirror it exactly. |
| **Append** | Keeps everything already ingested and adds only the export's **new** devices (de-duplicated on the Trend id). | You are building one estate view from several partial exports (e.g. Apex One + Deep Security, or per-region files) over time. |

```powershell
# Replace (default): this export IS the whole list
pwsh ./deploy/Import-TrendInventory.ps1 -TrendCsv .\apex-one.csv -ConfigPath .\deploy\config.json -Materialize

# Append: add Deep Security devices to the existing Apex One list (new items only)
pwsh ./deploy/Import-TrendInventory.ps1 -TrendCsv .\deep-security.csv -ConfigPath .\deploy\config.json -Mode Append -Materialize
```

To start over, delete `deploy/trend-inventory.local.csv` (or run any `-Mode Replace` import), and use
`Import-TrendInventory.ps1 -RestorePlaceholder` to clear the model table before committing.

### How to ingest the Trend asset list

You need: a Trend Micro device export as CSV (see *Trend CSV format* above — or start from
[`templates/trend-inventory-template.csv`](templates/trend-inventory-template.csv)) and a working
`config.json` (Service Principal with `Machine.Read.All`). Then choose one of the two flows below.

**Option A — preview first, then deploy (recommended).**

```powershell
# 1. Preview the mapping without touching the model.
#    Prints a table and writes trend-migration-mapping.csv for review.
pwsh ./deploy/Import-TrendInventory.ps1 -TrendCsv .\trend-export.csv -ConfigPath .\deploy\config.json

# 2. (Optional) tune domain tolerance, or append instead of replace, then re-preview.
pwsh ./deploy/Import-TrendInventory.ps1 -TrendCsv .\trend-export.csv -ConfigPath .\deploy\config.json -MatchThreshold 90
pwsh ./deploy/Import-TrendInventory.ps1 -TrendCsv .\deep-security.csv -ConfigPath .\deploy\config.json -Mode Append

# 3. Embed the reviewed mapping into the TrendMigration table.
pwsh ./deploy/Import-TrendInventory.ps1 -TrendCsv .\trend-export.csv -ConfigPath .\deploy\config.json -Materialize

# 4. Deploy.
pwsh ./deploy/Deploy-Dashboard.ps1 -ConfigPath .\deploy\config.json -Wait
```

**Option B — one shot (ingest + deploy in a single command).**

```powershell
pwsh ./deploy/Deploy-Dashboard.ps1 -ConfigPath .\deploy\config.json -TrendCsv .\trend-export.csv -Wait
# Append a second export on a later deploy:
pwsh ./deploy/Deploy-Dashboard.ps1 -ConfigPath .\deploy\config.json -TrendCsv .\deep-security.csv -TrendMode Append -Wait
```

Re-run whenever the Trend export changes. To clear the mapping, run
`Import-TrendInventory.ps1 -RestorePlaceholder` (no CSV needed) and redeploy. You can also set
`"trendCsv"`, `"trendMode"`, and `"trendSource"` in `config.json` so the export is picked up
automatically on every deploy.

## Output & sharing

```powershell
# Headless export of the published report (ids are printed by Deploy-Dashboard.ps1)
pwsh ./deploy/Export-Report.ps1 -WorkspaceId <ws-guid> -ReportId <report-guid> -Format PDF
pwsh ./deploy/Export-Report.ps1 -WorkspaceId <ws-guid> -ReportId <report-guid> -Format PPTX
pwsh ./deploy/Export-Report.ps1 -WorkspaceId <ws-guid> -ReportId <report-guid> -Format PDF -Pages "Non-Compliant Devices"
```

You can also export from the service (Export → PowerPoint / PDF), export a visual's data
(… → Export data), or connect Excel live to the semantic model (Analyze in Excel). Image/CSV export
of unbounded tables requires a paginated (.rdl) report over the same model.

## Security & secrets
- **No customer data or credentials are committed.** DeviceHealth carries no credentials (the data
  source is bound to your app as a Service Principal after publish); the trend table carries only a
  base64 placeholder that the deploy script fills at deploy time.
- `config.json` (real credentials) is **git-ignored** — never commit it.
- Client secrets are written by the bootstrap script to a local path only. Do not save them to
  OneDrive, SharePoint, or any cloud-synced location.
- On a machine with OneDrive + Microsoft Information Protection, save `.pbix`/`.pbit` to a non-synced
  path first (e.g. `C:\temp`) to avoid auto-encryption corrupting the file, then copy it into your clone.

## Permission reference

| Purpose | Permission | Type |
|---------|-----------|------|
| Publish semantic model + report | Workspace Admin or Member on the target workspace | Power BI role |
| Service-principal deployment | "Service principals can use Fabric APIs" tenant setting + workspace role | Tenant setting |
| Live data (Defender export APIs + trend seed) | WindowsDefenderATP `Machine.Read.All`, `Software.Read.All`, `Vulnerability.Read.All`, `AdvancedQuery.Read.All` | Application |

Full details, who grants each permission, and how to verify: see **[PERMISSIONS.md](PERMISSIONS.md)**.
Step-by-step install with a decision tree and troubleshooting: see **[INSTALL.md](INSTALL.md)**.

## Troubleshooting
- **"Workspace not found"** — pass `-SelectWorkspace` to pick from a list, `-WorkspaceId`, or
  `-CapacityId` to create it.
- **"Workspace has no capacity"** — assign a Fabric/Premium/PPU capacity, or pass `-CapacityId`.
- **Report shows no data** — the refresh needs the app credentials bound as a Service Principal and
  the consented WindowsDefenderATP permissions; re-run with `-Wait`, or open the dataset in the
  service and click Refresh. Confirm the data source is bound under Settings > Data source
  credentials (Service principal).
- **Service-principal token fails** — confirm admin consent was granted and the "Service principals
  can use Fabric APIs" tenant setting includes the app.
- **Cleanup / teardown** — two parts: `pwsh ./deploy/Remove-Dashboard.ps1 -WorkspaceId <id>` removes
  the published report + model (add `-RemoveWorkspace -Force` for a throwaway workspace); then
  `pwsh ./deploy/Bootstrap-Deployment.ps1 -Mode Uninstall -AppId <app-guid> -WorkspaceId <id>`
  revokes the app's Defender permissions, removes it from the workspace and deletes local `config.json`
  (add `-DeleteApp` to also delete the app registration). `Remove-Dashboard.ps1` retries transient
  failures, skips items that are already gone, never deletes the workspace when an item failed, and
  exits with a summary — so it is always safe to re-run. `-WorkspaceId` can also come from `-ConfigPath`.
- **Corrupt or missing local files** — the deploy script auto-detects an incomplete project and
  re-downloads it from GitHub before publishing; if you are offline, add `-SkipGitHubRestore` and
  restore the folder manually (`git pull`).

For a fix for each specific error code, see **[FAILURE-CODES.md](FAILURE-CODES.md)**.

## File layout
```
DefenderMigrationDashboard/
├─ README.md
├─ INSTALL.md               # step-by-step install guide
├─ PERMISSIONS.md           # permission reference
├─ pbip-project/            # TMDL model (Defender export-API query + deploy-time trend seed) + PBIR report
├─ deploy/
│  ├─ _Common.ps1           # shared sign-in, REST, workspace + SP-credential + trend-seed helpers
│  ├─ Deploy-Dashboard.ps1
│  ├─ Import-TrendInventory.ps1  # Trend Micro CSV → Defender inventory mapping (ingest)
│  ├─ Remove-Dashboard.ps1  # cleanup / teardown (published report + model)
│  ├─ Export-Report.ps1
│  ├─ Bootstrap-Deployment.ps1  # app-registration setup + CheckPermissions + Uninstall
│  ├─ assets/               # DeploymentTrend.kql + DeviceAvPosture.kql (deploy-time seed queries)
│  └─ config.json.template
└─ templates/               # KQL / M / DAX for the live path
```

## License

Licensed under the **MIT License** — see [`LICENSE`](./LICENSE). The software is provided as-is,
without warranty of any kind, and with no obligation to provide support, updates, or maintenance.
Please try it in a test workspace before using it in production.

## Author

Cristian De Angelis

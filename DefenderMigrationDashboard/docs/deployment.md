# Deployment, parameters & upgrades

[← Back to the README](../README.md)

Full parameter reference for `Deploy-Dashboard.ps1`, plus how versioning and in-place updates work.

---

## Quick start (3 commands)

```powershell
# 1. Create/reuse the Entra app and grant the WindowsDefenderATP permissions (writes deploy/config.json)
pwsh ./deploy/Bootstrap-Deployment.ps1 -Mode CreateNew -DisplayName "defender-migration-dashboard"

# 2. Sign in to publish to Fabric, then deploy (credentials come from config.json)
az login
pwsh ./deploy/Deploy-Dashboard.ps1 -ConfigPath ./deploy/config.json -SelectWorkspace -Wait

# 3. Open the report at the URL the script prints when it finishes
```

That publishes the semantic model and report, binds the report to the model, binds each data source
with the credential type it needs (the Defender API as a Service Principal; Microsoft's public
release-notes and security-intelligence pages as Anonymous), generates the 30-day trend history,
enables a scheduled refresh, and runs a first refresh so the report shows your real Defender data.

> **Outbound access.** Refresh reaches three hosts: `api.securitycenter.microsoft.com` (your estate),
> plus `learn.microsoft.com` and `www.microsoft.com` (the published-version baselines). The latter two
> are public and unauthenticated; if they are blocked, the baseline table falls back to the snapshot
> captured at deploy time and everything else still works.

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
| `-LegacyCsv` | Path to a third-party AV/EDR device export (CSV). At deploy time each legacy device is matched to the current Defender inventory and the result is embedded in the **LegacyAvMigration** table (see *Legacy AV/EDR migration mapping*). Omit to **reuse the previously ingested list** (it is no longer emptied). |
| `-LegacyMode` | `Replace` (default) — the supplied export becomes the whole legacy AV list; `Append` adds only new devices to the git-ignored local master store. Both de-duplicate on the legacy device id. Also settable as `legacyMode` in config.json. |
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
place), workspace selection, whether to import an updated legacy AV CSV, force, and a final confirmation
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

- The imported **legacy AV/EDR device list** is reused automatically when you deploy **without**
  `-LegacyCsv`, instead of being emptied. Pass `-LegacyCsv` only when you actually want to replace or
  append the list.
- The **DeploymentTrend history** accumulates across deploys (it grows beyond the 30-day live query
  window) so the trend-over-time charts keep their history, and the last-known history is re-pushed if
  a live hunting query transiently returns zero rows.
- Both stores are **backed up** before every overwrite (timestamped, the last 15 kept, under
  `deploy/backups/`, which is git-ignored).

---

## Upgrading an existing (pre-2.x) deployment

Applies when the workspace already hosts a dashboard published before the vendor-neutral
release — for example an existing tenant deployment that was ingesting Trend Micro only.

The upgrade is an **update in place**. The semantic model and report keep the display name
`Defender Migration`, so the deploy locates the existing items and updates their definitions;
no duplicate item is created and report links, bookmarks and permissions survive.

### What changed under the hood

| Pre-2.x | Current | Handling |
|---|---|---|
| `deploy/trend-inventory.local.csv` | `deploy/legacy-inventory.local.csv` | Adopted automatically on first upgraded run |
| Table `TrendMigration` | Table `LegacyAvMigration` | Rebound in model and report |
| `TrendSource` / `TrendId` | `LegacyProduct` / `LegacyId` (+ new `LegacyVendor`) | Upgraded on read |

### Steps

1. Pull the current release and keep your existing `deploy/config.json`.
2. Leave the old `deploy/trend-inventory.local.csv` where it is — do **not** delete it. The
   deploy copies it to `legacy-inventory.local.csv` and reports
   `Upgrade: adopted ...` on the run that performs the adoption.
3. Re-run the deploy. No `-LegacyCsv` is required: with no new export the previously ingested
   devices are re-used and re-published rather than dropped.

```powershell
cd DefenderMigrationDashboard\deploy
.\Deploy-Dashboard.ps1 -ConfigPath .\config.json
```

4. Confirm the run logs `Legacy list preserved: re-using <n> devices ...` and a non-zero
   `Legacy migration mapped: <n> devices` before the publish step.

### Adding further vendors after the upgrade

Existing rows keep their original product and vendor labels, so append rather than replace:

```powershell
.\Deploy-Dashboard.ps1 -ConfigPath .\config.json -LegacyCsv .\crowdstrike-export.csv -LegacyMode Append
```

A host covered by two tools deliberately remains **two** rows — each agent still has to be removed.

### Data-loss safeguard

Publishing replaces the migration table rather than merging into it. If the Defender lookup fails
(expired secret, missing `Machine.Read.All`, transient outage) while devices are already ingested,
the deploy now **fails and leaves the live table untouched** instead of overwriting it with an empty
one. Fix the cause and re-run. To publish an empty table on purpose, pass `-AllowEmptyLegacyTable`.

### Verifying the upgrade without touching the tenant

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Test-UpgradePath.ps1
```

Runs fully offline and asserts that a pre-2.x store is adopted, retains every device, keeps
per-row provenance, and that nothing still binds the old `TrendMigration` table.

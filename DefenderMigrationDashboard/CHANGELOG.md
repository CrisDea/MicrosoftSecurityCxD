# Changelog

All notable changes to the Defender Migration Dashboard are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/). From 2026-07-17 the project uses **calendar
versioning** — `YYYY.MM.DD.XX`, where `XX` is the two-digit release number within that day (starting
at `01`, incrementing per release, reset to `01` at midnight). Earlier entries used date-stamped
semantic versions and are kept as history.

## [2026.07.18.01] — 2026-07-18

### Added
- **AV update rings on the Device Inventory table.** The AV posture seed (`DeviceAvPosture.kql`) now
  reads and maps the platform, engine and signature update **rings** (Default / Beta / Preview /
  Staged / Broad / Delayed) from live Defender AV telemetry. New model columns `AVPlatformRing`,
  `AVEngineRing`, `AVSignatureRing`.
- **Device Inventory table rebuilt to the "MDE Major Health Check" (v2.9.5) column contract** — exact
  column order plus the three rings and the AV signature version, with the new OS-currency columns
  appended (`OSProduct`, `OSFullVersion`, `OSPatchUBR`, `OSSupportState`, `OSEolDate`,
  `OSPatchCurrency`, `OSMonthsBehind`, `OSFamily`, `EDRPlatform`).
- **OS Posture page rebuilt** as a real OS update-currency view: KPI cards (Supported / EOL-imminent /
  Unsupported / EDR legacy platform / monthly coverage), an **OS lifecycle support** chart, an **OS
  monthly patch currency** chart (Windows with UBR, fleet-relative), a devices-by-OS-product chart and
  a detail table (product, build/UBR, support state, EOL date, patch currency, EDR platform, last seen).
- **Overview page OS-family filter** — restricts the page to Windows / Linux / macOS computers,
  excluding mobile and other/IoT device families.

### Changed
- **Full-width page layouts.** Overview, Version Compliance, Non-Compliant, Mobile and OS Posture now
  fill the page width (eliminating the right-hand dead strip).
- **Migration Overview** switched to *Fit to page* and re-laid-out to give the migration-status
  breakdown prominence, with a clean five-chart bottom row.

## [2026.07.17.01] — 2026-07-17

### Added
- **Calendar versioning (`YYYY.MM.DD.XX`).** Releases are now stamped with the build date plus a
  same-day counter (`XX`, reset at midnight). The current version is shown on the **KPI Guide** page.
- **`EstateConfigState` calculated table** powering the Overview "Estate configuration state" donut.
  It unions MDE-discovered devices with **Trend-only** devices (on the ingested Trend list but never
  seen by Defender) so the donut reflects the *whole* estate, not just what Defender can see. New
  measures `Config State Devices`, `Not Onboarded In Trend` (red), `Trend Only Devices` (grey).

### Changed
- **Estate configuration-state donut recoloured.** Not-onboarded devices that are **discovered and on
  the Trend list** now render **red** (`#D13438`); devices that exist **only on the Trend list** render
  **grey** (`#8A8886`). Green = fully migrated & configured, amber = onboarded but needs attention.
- **Slicers moved to the native Filters pane on every page.** The per-page slicer strip was removed;
  all fields (device group, OS, onboarding state, version currency, etc.) are now `filterConfig`
  filters on the right-hand Filters pane, matching the Configuration Drill-down page.
- **`Trend Remaining` now includes Trend-only devices** (`+ [Trend Not In Defender]`) so the migration
  backlog counts devices Defender cannot yet see, not just discovered-but-not-onboarded machines.
- **KPI Guide refreshed** — documents the estate-donut red/grey semantics, the new
  `Not Onboarded In Trend` / `Trend Only Devices` populations, a dedicated **Trend Migration** section,
  and the move of slicers to the Filters pane.
- **PBIP artifacts renamed `MDE-MDAV-Migration.*` → `Defender-Migration.*`** (report, semantic model,
  `.pbip`, and their metadata references). Published Fabric names are unchanged (set by deploy-script
  parameters), so existing deployments are unaffected.

## [3.8.0] — 2026-07-17

### Added
- **Trend id ingestion + de-duplication.** The ingest now captures each device's **unique Trend id**
  (Apex One `GUID`; Deep Security `Host GUID`, preferred over `Agent GUID`) alongside the host name and
  a **Trend source** label (auto-detected as *Apex One* / *Deep Security*, or set with `-Source`). New
  `TrendId` and `TrendSource` columns are surfaced in the **TrendMigration** table. De-duplication is
  keyed on the Trend id (falling back to a normalised `host|source` key when a row has no id).
- **Replace vs Append import modes.** `Import-TrendInventory.ps1 -Mode` and `Deploy-Dashboard.ps1
  -TrendMode` (`Replace` default / `Append`) control how each export updates a git-ignored local master
  store (`deploy/trend-inventory.local.csv`): Replace uses the export as the whole list; Append adds
  only new devices. New `_Common.ps1` helpers `Get-TrendDeviceRecords`, `Get-TrendDedupKey`,
  `Read-/Merge-/Write-TrendStore`. Config keys `trendMode`, `trendSource`, `trendInventoryStore`.

### Changed
- **Trend template is now the normalised `TrendId,DeviceName,TrendSource`** (header-only, no rows).
  Native Apex One and Deep Security exports are still auto-detected and ingested directly.
- **README** *Trend CSV format*, *Replace vs Append*, and *How to ingest* sections rewritten to
  document the id/name/source columns, the two native export layouts (and saving `.xls` as CSV first),
  dedup-on-id, and the Replace/Append modes.

### Security
- **`deploy/trend-inventory.local.csv` and `*.local.csv` added to `.gitignore`** — the accumulated
  master store holds customer device data and is never committed.

## [3.7.1] — 2026-07-17

### Added
- **OpenSSF Scorecard workflow** (`.github/workflows/scorecard.yml`) — weekly + on-push supply-chain
  security analysis, publishing to the OpenSSF API and the repo Code Scanning dashboard. All actions
  are pinned to full commit SHAs (checkout v7.0.0, scorecard-action v2.4.3, upload-artifact v7.0.1,
  codeql-action/upload-sarif v4.36.2).
- **Dependabot** (`.github/dependabot.yml`) — weekly `github-actions` updates (the only ecosystem with
  managed dependencies in this repo), keeping the pinned action SHAs current.
- **`SECURITY.md`** — private vulnerability-reporting policy and a reminder never to include real
  tenant/SP/workspace IDs or exported device data in reports.
- **`templates/trend-inventory-template.csv`** — a blank, header-only (`Endpoint Name,Domain,Last
  Scan,Agent Version`) starter for the Trend asset list; ships with no rows. README *Trend CSV format*
  and *How to ingest the Trend asset list* now reference it.

### Security
- **Pre-publication data assessment** (public release): confirmed no real tenant/SP/workspace/capacity
  IDs, emails, secrets, IP addresses, or exported device names are committed; all model seeds are empty
  `__PLACEHOLDER__` literals; `config.json` and Trend/mapping CSVs remain git-ignored. The demo ships
  with **no sample Trend data** — `Migration %` renders as **N/A** until a real Trend export is ingested.

## [3.7.0] — 2026-07-17

### Changed
- **`Migration %` redefined as Trend-list coverage.** The headline `Migration %` measure now returns
  *healthy, onboarded MDE devices ÷ `Trend Source Devices`* (the ingested Trend asset list), i.e. how
  much of the Trend estate is protected by a healthy Defender sensor. It returns **"N/A"** when no Trend
  list is ingested (`Trend Source Devices = 0`), matching the AV-% measures' empty-denominator pattern,
  instead of a misleading 0%. Previously it was `MDE Onboarded ÷ Total Devices`.

### Added
- **`Healthy Onboarded Devices` measure** — `COUNTROWS` of DeviceHealth where `OnboardingStatus =
  "Onboarded"` and `Healthy = "Healthy"`; the numerator of the new `Migration %`.
- **`MDE Onboarding Coverage %` measure** — preserves the previous `Migration %` definition
  (`MDE Onboarded ÷ Total Devices`) so the onboarded-÷-all-Defender ratio remains available.

## [3.6.0] — 2026-07-17

### Changed
- **Active / Stale is now onboarded-only.** `Active Devices` / `Stale Devices` measures count only
  devices with `OnboardingStatus = "Onboarded"`, matching the deployment-trend chart population, so the
  two "stale" figures in the report no longer disagree. Not-yet-onboarded discovered devices are
  excluded from this signal.
- **Honest onboarding backlog.** The DeviceHealth query splits `onboardingStatus` into *Onboarded*,
  *Can be onboarded*, *Unsupported*, and *Insufficient info* (previously everything non-Onboarded was
  labelled "Can be onboarded"). The Migration Backlog now counts only genuinely onboardable devices;
  *Unsupported* / *Insufficient info* devices surface as their own categories instead of inflating the
  remaining-to-migrate figure.
- **KPI cards show `0` instead of blank** for genuinely-zero counts/percentages
  (`Total Devices`, `Clients`, `Servers`, `MDE Onboarded`, `Trend Remaining`, `Healthy Devices`,
  `Fully Migrated`, `Needs Attention`, `Migration %`, `Fully Migrated & Configured %`, `Healthy %`,
  `Not On Latest %`), so an empty card is never mistaken for a data-load failure.

### Added
- **`-RemovedAfterDays` deploy parameter (and `removedAfterDays` in config.json).** Optional noise
  filter that excludes devices whose Defender `lastSeen` is older than *n* days (default `0` = keep
  all), removing long-decommissioned records that would otherwise drag the migration denominator.
  Implemented as a `RemovedAfterDaysCutoff` literal in the DeviceHealth M query that the deploy script
  rewrites at publish time; the committed default is valid with no injection.

### Verified
- End-to-end redeploy against a live workspace; all KPIs reconciled against the raw Defender machines
  API (20 devices, 7 onboarded / 13 backlog, Active/Stale correctly onboarded-scoped to 3/4).

## [3.5.0] — 2026-07-17

### Changed
- **Trend → Defender matching now requires an exact short hostname; fuzzy tolerance applies only to
  the DNS domain suffix.** Previously the whole device name (including domain) was fuzzy-matched,
  which could conflate two different hosts. Now the normalised short hostname (case-folded, trailing
  `$` and punctuation stripped, domain removed) must match a Defender device exactly, and
  `-MatchThreshold` (default 82) governs only how far the domain suffix may differ
  (e.g. `ws01.contoso.com` vs `ws01.contoso.local` = **Fuzzy**; `ws09.contoso.com` vs
  `ws09.fabrikam.com` = **rejected**). A hostname with no domain (short name or the AD `$` form)
  matches any domain for that host, preferring an onboarded record on ties.
- Help text updated in `Import-TrendInventory.ps1` (.SYNOPSIS/.DESCRIPTION/`-MatchThreshold`) and
  `Deploy-Dashboard.ps1` (`-TrendCsv`/`-MatchThreshold`) to describe the exact-host, domain-only
  behaviour.

### Added
- **`Get-NormalizedDomainSuffix`** helper in `_Common.ps1` and a rewritten `Get-TrendDefenderMapping`
  (exact-hostname hashtable lookup + domain-only fuzzy; dedup key is now `host|domain`).
- **Docs: dedicated "Trend CSV format" and "How to ingest the Trend asset list" sections** in
  `README.md`, covering the accepted host-name column headers, FQDN/short/`$` handling, one-row-per
  -device layout, a worked CSV example, and the preview → materialise → deploy workflow.

## [3.4.0] — 2026-07-17

### Changed
- **Default item names are now "Defender Migration"** (was "MDE-MDAV-Migration") for both the
  semantic model and the report, across `Deploy-Dashboard.ps1` and `Remove-Dashboard.ps1`.

### Added
- **Customer-overridable item names via `config.json`.** New optional `modelName` / `reportName`
  keys let a customer name the published dataset and report without editing the scripts. Precedence:
  an explicit `-ModelName`/`-ReportName` argument wins, then `config.json`, then the default.
  `config.json.template` documents the new keys.

## [3.3.2] — 2026-07-17

### Fixed
- **`Remove-Dashboard.ps1` / `Export-Report.ps1` no longer crash on a partial `config.json`.** Both
  scripts read optional config keys with unguarded `$cfg.<key>` access, which throws
  ("The property '<key>' cannot be found on this object") under `Set-StrictMode -Version Latest`
  when a key is absent (e.g. a config that supplies only `workspaceId` + `graph*` for az-user
  publish + Service-Principal Defender auth). Switched to `$cfg.ContainsKey('<key>')` guards,
  matching `Deploy-Dashboard.ps1`. Verified end-to-end with a clean workspace teardown + full
  redeploy.

## [3.3.1] — 2026-07-17

Hardening of the v3.3.0 Trend → Defender migration mapping after a full code review.

### Fixed
- **Mapping now excludes merged/excluded machines.** `Get-DefenderInventory` selects
  `mergedIntoMachineId` / `isExcluded` and drops those records, matching the DeviceHealth table's
  own filter so the Trend mapping can no longer match a stale or hidden duplicate.
- **Onboarded preference now also applies to fuzzy matches.** Fuzzy candidate buckets are built from
  the de-duplicated (Onboarded-preferred) index, so a fuzzy tie can no longer classify an onboarded
  device as "Matched — not onboarded".
- **Fuzzy matcher bounded for large estates.** The Levenshtein distance now short-circuits once it
  cannot reach the acceptance threshold (length-gap fast-reject + per-row minimum early-exit),
  keeping the match near-linear on large fleets instead of degrading on common name prefixes.
- **`-MatchThreshold` validated.** Added `[ValidateRange(0,100)]` on both `Deploy-Dashboard.ps1` and
  `Import-TrendInventory.ps1`, with an internal clamp in the matcher.
- **`Import-TrendInventory.ps1 -RestorePlaceholder` no longer requires a CSV.** `-TrendCsv` is now
  optional; the CSV is required only for an actual ingest (and the `config.json` `trendCsv` fallback
  is now reachable). Corrected the script synopsis to describe the `/api/machines` source and the
  `Machine.Read.All`-only requirement (it previously referenced advanced hunting).
- **Status donut legend enabled** so each slice (Migrated to Defender / Matched — not onboarded /
  Not found in Defender) is identifiable; the auto-title stays suppressed via the separate label.

## [3.3.0] — 2026-07-17

Adds a Trend Micro → Defender migration mapping, driven by your Trend device export, so you can see
exactly which Trend-managed devices are now in Defender and which still need migrating.

### Added
- **New "Trend Migration" page.** Maps each device in a Trend Micro export to the current Defender
  inventory: Trend Source Devices / Trend Migrated / Trend Migration % / Trend Not In Defender KPIs,
  a status donut, and a full per-device mapping table (Trend name → Defender name, match type, match
  score, onboarding status, OS). Sliceable by migration status and match type via the Filters pane.
- **`-TrendCsv` / `-MatchThreshold` on `Deploy-Dashboard.ps1`.** Pass a Trend export CSV to compute
  and embed the mapping at deploy time; tune the fuzzy-match acceptance score (default 82).
- **`deploy/Import-TrendInventory.ps1`** — standalone ingest script that previews the Trend→Defender
  mapping (and writes it to CSV), with `-Materialize` / `-RestorePlaceholder` to embed or clear the
  seed in the **TrendMigration** table.
- **`TrendMigration` seed table** in the semantic model (mapping columns + migration measures),
  populated via the same deploy-time base64-seed pattern as the trend history.

### Notes
- The Defender inventory used for matching is read from the paged `GET /api/machines` export endpoint
  — the **same source as the dashboard's DeviceHealth** — so the mapping is always consistent with
  the rest of the report. Only `Machine.Read.All` is required.
- Names are matched tolerantly (case, domain suffix, trailing `$`, punctuation), exact first then
  closest-name fuzzy. Each device is classified Migrated to Defender / Matched — not onboarded / Not
  found in Defender.
- The mapping is a **deploy-time ingest**, not an in-report file upload: the model refreshes in the
  service as a Service Principal with no data gateway, so a locally uploaded file cannot be re-read on
  a cloud refresh. Re-deploy (or re-run `Import-TrendInventory.ps1 -Materialize`) when the Trend
  export changes.

## [3.2.4] — 2026-07-16

Overhauls the Configuration Drill-down layout so the per-check pies are no longer cut off or
covered by the on-canvas slicer rail, and gives the full device list its own page.

### Changed
- **On-canvas slicers relocated to the native Filters pane.** The 14 slicer visuals (and their
  "Filters" label) that previously occupied the right column are removed from the page canvas and
  re-created as 13 friendly-named filter cards in the report Filters pane (Active / Stale, AD
  domain, Citrix VDI, Client / Server, Cloud / on-prem, Healthy, Last seen, Managed by, MDE tags,
  OS platform, OS version, Sensor connectivity, Trend installed). The onboarded-only lock filter is
  retained as a locked card. This frees the entire right rail.
- **Pies re-laid to a full-width 4×3 grid.** With the slicer column removed, the 12 per-check pies
  now use the full page width in a balanced four-column, three-row grid, so the outside percentage
  labels render fully without being clipped by, or overlapping, the slicer rail.
- **Subheader updated** to direct users to the Filters pane for slicing and to the new Device
  Inventory page for the full device list.

### Added
- **New "Device Inventory" page.** The device results table that previously sat below the pies on
  the drill-down page has been moved to its own full-page table, giving the full onboarded-device
  list room to breathe. It carries the same onboarded-only lock as the drill-down content.

### Validated
- Redeployed to the Power BI service and visually confirmed via live QA: the drill-down shows all
  12 pies full-width with every percentage label visible (nothing cut or covered), no slicers on
  the canvas, and all 13 filter cards present in the Filters pane; the Device Inventory page renders
  the full-page device table. All 168 report JSON files parse cleanly.

## [3.2.3] — 2026-07-16

Refines the Configuration Drill-down data labels for readability after live visual QA.

### Changed
- **Per-check pies now label each slice with the percentage only** (`Percent of total`) instead of
  `count (percent)`. Power BI always renders the percentage at two decimals and ignores the label
  precision properties, so the combined `count (percent)` label overflowed and truncated (e.g.
  `2 (28...)`) in the compact 12-tile grid. Percentage-only labels (e.g. `28.57%`) render fully in
  every tile. The device count for each slice remains available on hover (tooltip) and in the
  drill-through device table below the pies.
- **Subheader updated to match** — states that each slice shows the % of onboarded devices in that
  state and points to the hover tooltip for the device count.

### Validated
- Clean-workspace redeploy from a fresh GitHub clone (teardown → publish model + report → bind the
  Service Principal datasource → schedule → refresh) completed end-to-end, confirming customer
  readiness. The percentage-only labels were visually confirmed in the Power BI service.

## [3.2.2] — 2026-07-16

Improves readability of the Configuration Drill-down (per-check posture) report page.

### Changed
- **Every per-check pie now shows data labels** (`Data value, percent of total`) so each slice
  states the device count and its percentage of the onboarded population — previously the pies had
  no legend and no labels, showing colour only. Applies to all 12 checks (AV mode, real-time / cloud /
  PUA / network / behavior / tamper protection, AV platform / engine / signature currency, MDE sensor
  currency, OS currency).
- **The page subheader now states the denominator explicitly** — all pies cover onboarded devices
  only, and each slice is the count and % of the onboarded total — reinforcing the existing
  page-level `OnboardingStatus = Onboarded` filter so not-yet-onboarded devices never distort a check.

## [3.2.1] — 2026-07-16

Follow-up fixes surfaced by a code review of the deployment scripts, plus removal of dead
configuration and a deprecated parameter.

### Fixed
- **`Remove-Dashboard.ps1` teardown was a silent no-op.** Its default `-ModelName` / `-ReportName`
  (`DefenderMigration` / `Defender Migration Dashboard`) did not match what `Deploy-Dashboard.ps1`
  actually publishes (`MDE-MDAV-Migration` for both). Because items are matched by exact display name,
  the documented `Remove-Dashboard.ps1 -WorkspaceId <id>` found nothing and exited 0, leaving the
  report and model in place. Defaults now match the deployed item names.
- **`Export-Report.ps1 -Pages` now resolves display names to internal page names.** The Power BI
  `ExportTo` API expects each `pages[].pageName` to be the internal page name (e.g. `ReportSection0`),
  not the visible display name; the previous code passed the display name straight through, so the
  page filter failed. The script now GETs the report pages, maps the supplied display (or internal)
  name to the internal name, and errors clearly listing the available pages if one is not found.

### Removed
- **Dead `defenderScope` config key.** It was written into `config.json` and listed in
  `config.json.template` but never read (every script hard-codes the securitycenter scope), so it
  implied a non-existent knob. Dropped from both.
- **Deprecated `-IncludeDefenderApiPerms` parameter** on `Bootstrap-Deployment.ps1` (Defender
  permissions are always configured now); the no-op notice was removed with it.

### Changed
- **Docs now describe the complete two-part teardown** (remove published items with
  `Remove-Dashboard.ps1`, then revoke identity/permissions with `Bootstrap-Deployment.ps1 -Mode
  Uninstall`) across `README.md`, `INSTALL.md` and `deploy/README.md`; the `deploy/README.md` script
  table lists the current Bootstrap modes (`CheckPermissions`, `Uninstall`).

## [3.2.0] — 2026-07-16

Hardens `deploy/Bootstrap-Deployment.ps1` for customer self-service: a verified least-privilege model,
a read-only permission checker with an opt-in fix, per-step verification with manual-prerequisite
gating, and a full uninstall path — all using one shared helper core.

### Added
- **`CheckPermissions` mode** — reads `servicePrincipals/{id}/appRoleAssignments` (the source of truth
  for consented application permissions) and reports each required WindowsDefenderATP permission as
  GRANTED / MISSING. Read-only; runs with only Directory Readers / Global Reader. `-Fix` grants any
  missing permission and re-verifies (gated on Privileged Role Administrator / Global Admin).
- **Least-privilege access model** — on every run the script reads the signed-in account's directory
  roles (`/me/memberOf`) and maps them to each operation's verified least-privilege role, so a write is
  only attempted (and only requires elevation) when actually needed. `Assert-WriteCapability` STOPS
  with precise `az login` re-login guidance when the required role is absent. New `-ForceWrite` skips
  the pre-check (PIM-eligible-but-not-activated roles aren't detectable).
- **Per-step verification + manual-step gating** — install runs as numbered steps, each read back to
  confirm it applied; the "Service principals can use Fabric APIs" tenant prerequisite pauses with
  instructions and is re-checked (`Test-FabricSpAccess`) before continuing. An honest final summary
  lists any outstanding items and exits non-zero when the run is incomplete.
- **`Uninstall` mode** (`-DeleteApp`, `-Yes`) — reverses a deployment using the same helper core:
  removes the SP from the workspace, revokes the Defender app-role assignments, optionally deletes the
  app registration + SP, and deletes the local `config.json`, confirming each removal.
- **Documentation** — `PERMISSIONS.md` gains a bootstrap least-privilege / permission-check / uninstall
  section and a role-gating table; the script's comment-based help gains a Permissions-Required table,
  a step-by-step of exactly what it does, and Uninstall / CheckPermissions examples.

### Fixed
- **`Invoke-Az` no longer corrupts JSON on `az` warnings** — `az` writes warnings (e.g. the cp1252
  encoding notice) to stderr; under `2>&1` those arrived as `ErrorRecord` objects and were concatenated
  into the returned text, breaking `ConvertFrom-Json` for every Graph call (role detection silently
  reported "could not read directory roles" even for a Global Admin). Stdout and stderr are now
  separated: only real stdout is returned, and stderr is still surfaced on failure.
- **Workspace membership uses the service-principal object id**, not the app/client id — the Power BI
  `AddGroupUser` API requires the SP object id for `principalType: App` (passing the appId returns 400).
  Add/remove now verify the membership landed with the requested access right and return `$false` when
  the read-back cannot be confirmed.
- Removed a redundant, over-broad `az ad app permission admin-consent` call (the `appRoleAssignments`
  grant already consents exactly the four required permissions); the grant step now runs only when a
  permission is actually missing, so a configured re-run is not blocked for a non-PRA operator.
- `-NoSecret` now refuses to overwrite `config.json` with a null or mismatched secret (it requires an
  existing config for the same app/tenant with a non-empty secret), and the install step count no longer
  double-counts the Fabric verification step.
- `Verify` mode now also confirms real Fabric API usability (and workspace reachability when a
  `workspaceId` is present), not just raw token acquisition.

## [3.1.0] — 2026-07-16

Restores real AV posture (mode, exact platform / engine / signature versions and their fleet-relative
currency) to DeviceHealth via a deploy-time advanced-hunting seed, replacing the hardcoded "N/A"
placeholders of the cloud-only build. Signature and platform versions are now graded per exact OS
build for Windows, Linux and macOS, mirroring the EDR-sensor grading.

### Added
- **`deploy/assets/DeviceAvPosture.kql`** — a lean per-device advanced-hunting query returning
  `AVMode`, `AVProductVersion` (platform), `AVEngineVersion`, `AVSigVersion`, `AVSigLastUpdateTime`,
  `EBPFStatus` and precomputed `AVPlatformCompliant` / `AVEngineCompliant` / `AVSigCompliant`
  (GOOD / WARN / BAD / N/A). Grading is fleet-relative per OS build: newest production-ring version is
  the green baseline; Windows AV platform uses release-month gap, Linux/macOS (and signature/engine)
  use release-order rank (Linux n-9, Windows n-2). One row per device, well within advanced-hunting
  limits (100k rows / 10 min).
- **`New-AvPostureSeedOverride`** in `deploy/_Common.ps1` — clones the trend-seed mechanism: runs
  the AV posture query at deploy with the app-only token and embeds the result in `DeviceHealth.tmdl`
  as base64 JSON (`__AVPOSTURE_SEED_B64__`). Fails soft to an empty seed (all AV fields stay "N/A").

### Changed
- **`DeviceHealth` now populates AV mode / versions / compliance from the seed** instead of hardcoding
  "N/A". The seed is decoded into a DeviceId lookup and merged per device inside the existing `Build`
  projection, so all downstream columns, measures and visuals are unchanged — just populated with real
  values. Devices absent from the seed (not onboarded / no telemetry) still resolve to "N/A".
- **AV signature compliance is now version-graded** (fleet-relative, per OS build) rather than derived
  from the boolean "signature up to date" secure-config flag; the flag remains the fallback when a
  device is not present in the seed.
- **`Deploy-Dashboard.ps1`** generates and merges both the trend and AV-posture overrides before
  publishing the model.
- The live current-state refresh is unaffected: `DeviceHealth` still refreshes on the normal cadence
  via its Service-Principal-bound export datasource; only the AV version snapshot is materialised at
  (re)deploy (advanced hunting is POST-only and cannot run during a cloud scheduled refresh).

## [3.0.1] — 2026-07-16

Human visual-QA pass on the live report. Fixes headline fields that rendered as blank ("- -") or
empty charts for metrics that are unavailable in the cloud-only build, and repurposes a permanently
empty chart with data that is actually available. Behaviour is unchanged for tenants that do supply
the underlying data.

### Fixed
- **Compliance % cards now read "N/A" instead of blank "- -"** when no gradable devices exist.
  `AV Sig Compliant %`, `AV Engine Compliant %`, `Platform Compliant %` and `Sensor Compliant %`
  return the text "N/A" when their non-N/A denominator is zero, rather than an empty card. In the
  cloud-only build AV Engine and Platform version data is not returned by the export API, so those
  two cards correctly show "N/A".
- **Count KPI cards now show `0` instead of blank "- -"** when a filter matches no rows. Affected
  cards: Non-Compliant, Sensor Attention, Not Reporting, Sensor Outdated, and the Mobile page counts
  (Mobile Devices, Android, iOS, MDM Enrolled, MAM Enrolled, App Outdated).
- **`Platform Outdated` card reads "N/A"** in the cloud-only build (platform build data unavailable)
  rather than a blank card.
- **Version Compliance: the always-empty "AV platform posture" chart was repurposed** to
  "AV signature posture (green / amber / red) by DeviceType", which is populated from AV signature
  data that the export API does provide. Added supporting measures `AV Sig Up To Date`,
  `AV Sig Behind`, `AV Sig Out Of Date`.

### Changed
- Corrected the `-ModelName` / `-ReportName` default values documented in `Deploy-Dashboard.ps1`
  help to match the code (`MDE-MDAV-Migration`).

## [3.0.0] — 2026-07-16

Major re-architecture of the live data path for scale (100k+ devices) and reliable cloud scheduled
refresh, plus a self-contained scripted end-to-end deployment for customer handoff.

### Changed
- **DeviceHealth now uses the Defender for Endpoint export-assessment REST APIs**
  (`api.securitycenter.microsoft.com`) instead of a Microsoft Graph advanced-hunting query. The paged
  export/list machine APIs have no 10,000-row hunting cap, so the current-state fact scales to 100k+
  device estates and filters server-side.
- **Data source is bound as a Service Principal.** The DeviceHealth query is a single-source GET with
  no in-query token; Power BI mints and attaches the app-only bearer token itself on each refresh.
  This eliminates the Power Query data-combination firewall failure that blocked the old
  "mint a token, then call the API" pattern on cloud scheduled refresh.
- **Deployment permissions** switched to WindowsDefenderATP application permissions (admin-consented):
  `Machine.Read.All`, `Software.Read.All`, `Vulnerability.Read.All`, `AdvancedQuery.Read.All`. No
  Microsoft Graph data permission is required. `Bootstrap-Deployment.ps1` grants these unconditionally.
- **Default published item names** aligned to the project (`MDE-MDAV-Migration` for both the model and
  the report) so the report-to-model connection string resolves correctly.
- Documentation (README, INSTALL, QUICKSTART, PERMISSIONS, deploy/README, FAILURE-CODES,
  config.json.template) updated to the Service-Principal + export-API model.

### Added
- **`deploy/assets/DeploymentTrend.kql`** — the 30-day advanced-hunting query the deploy script runs
  to build the trend history.
- **`New-TrendSeedOverride`** in `deploy/_Common.ps1` — runs `DeploymentTrend.kql` via the Defender
  advanced-hunting API at deploy time, base64-encodes the day × machine-group result, and embeds it in
  the model. Regenerated on every (re)deploy.
- **`Set-LiveCredentials`** now binds the `api.securitycenter.microsoft.com` data source as a Service
  Principal over REST (no manual credential dialog).

### Fixed
- Scheduled refresh no longer fails with the data-combination firewall error, because DeviceHealth is
  a single data source and the trend history is materialised at deploy time (the advanced-hunting POST
  cannot run during a cloud refresh — a `Web.Contents` POST body is rejected on any non-Anonymous data
  source).
- Slicer fonts reduced to fit their space (7–9pt) so the filter rail is legible.
- Health / version-compliance pages (Version Compliance, Configuration Drill-down, Non-Compliant
  Devices) are filtered to `OnboardingStatus = Onboarded`, because Defender only reports
  configuration/health data for onboarded devices.

### Removed
- **`expressions.tmdl`** (the `GraphTenantId` / `GraphClientId` / `GraphClientSecret` model
  parameters) — no in-query token or secret is embedded in the model any more.
- The vestigial Microsoft Graph `ThreatHunting.Read.All` grant from `Bootstrap-Deployment.ps1`.

### Known limitations
- The 30-day trend history advances on **redeploy**, not on scheduled refresh (the advanced-hunting
  POST cannot run in a cloud refresh). DeviceHealth still refreshes live on the normal cadence.
- Exact AV mode / platform / engine versions that require the gateway `DeviceTvmInfoGathering` export
  are `N/A` in this cloud-only build; the corresponding KPIs show "- -" where the tenant does not
  expose them via the export APIs.

## [2.9.7] — prior baseline

- Device-group split fix, `DupDeviceId` flag, TVM configuration-assessment dedup, group-aware trend,
  refresh cadence reduced from 8×/day to 2×/day, and the KPI Guide page. (See git history for the full
  pre-3.0.0 changes.)

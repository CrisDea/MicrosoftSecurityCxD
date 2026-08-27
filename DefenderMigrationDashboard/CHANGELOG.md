# Changelog

All notable changes to the Defender Migration Dashboard are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/). From 2026-07-17 the project uses **calendar
versioning** — `YYYY.MM.DD.XX`, where `XX` is the two-digit release number within that day (starting
at `01`, incrementing per release, reset to `01` at midnight). Earlier entries used date-stamped
semantic versions and are kept as history.

## [2026.08.20.19] - 2026-08-27

### Added
- A dashed 90% target line on the ranked control-coverage chart, so the
  "Controls Below Target" KPI can be verified at a glance against the bars
  rather than being an unexplained number.

### Changed
- Refreshed the pinned SHAs for `github/codeql-action` and `ossf/scorecard-action`.
  Both upstream projects re-tagged their releases in place, so the pinned commits
  no longer matched the tags they claim; each new SHA was verified against the
  upstream annotated tag before applying.
## [2026.08.20.18] - 2026-08-20

### Fixed
- **macOS and Linux version baselines were being compared in the wrong namespace.** Defender on
  macOS/Linux does not use the Windows version series, and the value a device reports as its *EDR
  version* is not its app build. The baseline table listed only the `101.x` app build for those
  platforms, so a Linux device reporting `EDRVersion 30.126052` was shown against a published
  `101.26062.0007` — two unrelated numbers. The release notes publish the matching `Release version`
  (macOS `20.x`, Linux `30.x`) alongside each build; both are now carried as separate rows.
- The macOS/Linux **AV engine** is now listed as *in-box* — the engine that shipped with that
  release. The running engine advances independently via the signature channel and is routinely
  newer, so a device ahead of the released value is healthy rather than out of date.
- **Security intelligence is listed once as *All platforms*** instead of under Windows, since the
  definitions are shared across operating systems.

### Changed
- The baseline table grew from 8 rows to 12 to cover the per-platform components; the Version
  Compliance layout was reflowed to fit them without a scrollbar.
## [2026.08.20.17] - 2026-08-20

### Changed
- **Version baselines are now live.** The "Latest published by Microsoft" table on Version
  Compliance was a hardcoded four-row list that had gone stale on every single value (AV
  signature 1.453.250.0, engine 1.1.26050.11, platform 4.18.26050.15, sensor 10.8805). It now
  reads the two authoritative Microsoft pages on every dataset refresh, so it stays correct
  between deploys instead of drifting until someone remembers to edit it:
  - the [Defender for Endpoint release notes](https://learn.microsoft.com/en-us/defender-endpoint/microsoft-defender-endpoint-releases)
    for the AV engine and platform, the Windows EDR sensor build, and the current macOS,
    Linux, Android and iOS builds;
  - the [WDSI security intelligence page](https://www.microsoft.com/en-us/wdsi/defenderupdates)
    for the AV signature version, which changes several times a day and is deliberately not
    carried on the release-notes page.
- The table now covers **all five platforms** rather than Windows only, and reports the
  release month and which page each value came from alongside the version.

### Added
- Anonymous credential binding for the two public Microsoft pages. `Set-LiveCredentials`
  previously applied the Service Principal to every data source it found, which would have
  failed for anonymous web sources; it now selects the credential type per source URL.
- A deploy-time snapshot of the published versions as a per-row fallback, so an unreachable or
  restructured source page degrades that row to last-known-good instead of failing the refresh.
## [2026.08.20.16] - 2026-08-20

### Changed - pages now explain their own numbers instead of looking broken
Several pages showed technically correct values that were indistinguishable from a failed report,
because the definition behind the number was never stated:
- **Overview** reported `Fully Migrated 0`, `Fully Migrated % 0.0%` and `Healthy Devices 0` beside
  `Total Devices 20`. `Fully Migrated` requires onboarded **and** legacy AV removed **and** all
  thirteen health signals green, so it stays at 0 until the last signal clears. The subtitle now
  says so and points at Needs Attention.
- **Version Compliance** reported `Platform % 100.0%` next to a chart showing four of seven devices
  as `N/A`. The percentage only covers devices that report the component; the subtitle now states
  the denominator rather than letting 100% read as whole-estate coverage.
- **OS Posture** now states that posture is assessed for onboarded devices only, since its
  `Total Devices` card counts the whole estate.
- The **Legacy AV** empty-state note was shortened so it no longer overflows its box.

## [2026.08.20.15] - 2026-08-20

### Fixed - the trend double-counted every day after the first deploy
`ConvertFrom-Json` re-hydrates an ISO date string into a `[datetime]`, so a row read back from the
history store stringified as `08/25/2026 00:00:00` and keyed differently from the freshly generated
`2026-08-25T00:00:00Z` - the same day was kept twice and the trend reported 14 onboarded / 26
remaining against an estate of 20. `Get-TrendHistoryKey` now normalises either form to `yyyy-MM-dd`,
and `Merge-TrendHistory` rewrites `Date` to one canonical format so the store, the embedded seed and
the next merge all agree.

### Fixed - `Active Devices` rendered blank instead of 0
It lacked the `+ 0` guard that its sibling `Stale Devices` already had, so a tenant with no active
onboarded devices got an empty card rather than a zero.

### Fixed - OS Posture detail table contradicted its own KPI cards
The table listed all devices while `OSSupportState`, `OSPatchCurrency` and `OSPatchUBR` are only
computed for onboarded ones, so every visible row read `N/A` while the cards above reported 3
supported / 2 unsupported. The table is now filtered to onboarded devices and titled accordingly.

### Changed - clearer labels, fewer redundant columns
- "Active vs stale" is now "Seen in last 7 days", which is what `DeviceStatus` actually measures -
  a 7-day last-seen window, not Defender's `healthStatus`. The old label read as onboarding health.
- Device Inventory drops `MigrationStatus` and `OnboardingStatus`: the page is filtered to
  `OnboardingStatus = 'Onboarded'`, so both were constant on every row (15 columns, was 17).
- The Mobile empty-state note was shortened so it no longer overflows its box.

## [2026.08.20.14] - 2026-08-20

### Fixed - the trend chart drew from a different device population than the cards beside it
`DeploymentTrend` was built from the advanced-hunting `DeviceInfo` table while every KPI card on
the same page came from `GET /api/machines`. Those two sources answer different questions:
`DeviceInfo` reports devices that have produced telemetry and its `OnboardingStatus` reflects
discovery state, so it returned *all* devices as `Can be onboarded` (0 onboarded) while the machines
API returned 7 onboarded of 20. The two disagreed side by side on one page.

The trend is now derived from `GET /api/machines` via `Get-DefenderTrendSnapshot`, applying the same
merged / excluded / blank-hostname filtering as the `DeviceHealth` table, so the trend and the cards
are guaranteed to reconcile. Verified live: the trend totals 7 onboarded / 13 remaining / 20 total,
matching the cards exactly.

Consequences:
- `deploy/assets/DeploymentTrend.kql` is no longer used and has been removed, along with its
  preflight check. The trend no longer needs the `AdvancedQuery.Read.All` permission — only
  `Machine.Read.All`, which the dashboard already required.
- The retained history was hunting-derived and asserted 0 onboarded devices, which is provably
  wrong, so it was discarded rather than migrated. History now rebuilds from the machines API and
  accumulates one snapshot per deploy.
- The trend line chart now draws point markers, so the first snapshot is visible before enough days
  have accumulated for a line to render, and carries an explicit title.

## [2026.08.20.13] - 2026-08-20

### Fixed - trend history was silently discarded on every deploy
The local history store had been written as a collection *envelope*
(`{"value":[...],"Count":125}`) rather than a bare array: under Windows PowerShell 5.1
`ConvertTo-Json` serialises an ordered-dictionary value collection's own properties
instead of enumerating it. Reading it back produced a single object with no `Date`,
which threw under `Set-StrictMode` and aborted the merge — while the error handler read
`.Count` *off the envelope* and reported a convincing "re-pushing 125 rows". The trend
chart was therefore drawing stale figures that contradicted the cards beside it. The
store is now unwrapped on read, always written as an array, and a malformed row is
skipped instead of aborting the whole merge.

### Fixed - "Migration %" showed N/A beside a populated Total and Onboarded
The measure divided by the legacy AV/EDR CSV device count, so without an imported CSV it
reported N/A next to cards reading 20 and 7 — indistinguishable from a broken tile. It now
falls back to onboarded / total devices when no CSV is present, and still prefers the
legacy source estate as the denominator when one has been imported.

### Changed - device tables trimmed to a readable width
Device Inventory projected all 47 columns, led by a 64-character `DeviceId` hex GUID that
was both unreadable and the widest column on the page, forcing roughly five screens of
horizontal scrolling. It now carries 17 columns covering identity, migration state,
protection and version; the exhaustive record remains on the Device Details drill-through.
The Non-Compliant follow-up table drops two near-duplicate sensor columns.

### Changed - clearer titles and honest empty states
The sensor chart's title no longer restates its own colour legend. Truncated titles and the
Mobile and Legacy AV pages now state why they are empty, so a tenant with no mobile devices
or no imported export sees an explanation rather than blank panels.

## [2026.08.20.12] - 2026-08-20

### Fixed - "Non-Compliant" card read 0 while the table below it listed devices
The page states its scope as devices "behind on versions, impaired sensors, or not
reporting to Defender", but the headline measure tested version state only. Any
estate whose problem was connectivity rather than versions saw a reassuring 0
above a list of machines that plainly needed attention. Sensor connectivity is
now part of the test, so the card agrees with the table beneath it — a device
that has stopped reporting cannot be shown to be compliant at all.

## [2026.08.20.11] - 2026-08-20

### Fixed - "Total" row would not switch off on any table
Every table carried a grand-total row that was always blank, because the tables
list text and version strings rather than additive numbers. The setting to hide
it had been written as `total.show`, but the table visual reads `total.totals` —
so the instruction was silently discarded and the row kept rendering. Corrected
across all nine tables.

### Changed - KPI Guide version marker is now visible
The marker sat in the 34px subtitle band behind a scrollbar, so the one detail
support needs first could not actually be read. It moves to the "Good to know"
panel, and the subtitle trims to the single line that fits.

## [2026.08.20.10] - 2026-08-20

### Fixed - overlapping visuals on Legacy AV Migration
A leftover section-label textbox sat directly on top of the migration-status
chart, so its caption was sliced in half by the chart beneath it. The label was
redundant — the chart already carries the same title — so it is removed and the
chart reflows into the space, aligning with the mapping table beside it.

### Fixed - dates rendered with a meaningless midnight timestamp
`LastSeen`, `EOS`, `OSEolDate` and `AVSigLastUpdateTime` displayed as
"11/12/2019 12:00:00 AM". The query layer already casts all four to date-only,
so the time was formatting noise that widened every table it appeared in. They
now use `yyyy-mm-dd`, which is unambiguous across locales and sorts correctly.

### Changed - KPI Guide rebalanced and de-instructed
The intro told readers to use "the tabs along the bottom", which stopped being
true when the left navigation rail replaced the page tabs. Column one overflowed
into a scrollbar and clipped the Legacy AV section mid-sentence while columns two
and three ended a third empty; that section moves across to balance them.
Release-note "(new)" markers are dropped — a customer reading the guide has no
previous version to compare against.

### Removed - last operating instruction
The Device Inventory caption explained how to right-click for drill-through.
Every caption in the report now describes its content rather than the tool.

## [2026.08.20.09] - 2026-08-20

### Removed - operating instructions from the report surface
Four table captions told the reader how to drive Power BI rather than what the table held
("right-click → Export data for all columns", "click donut slice to filter, then Export
data"). A customer-facing dashboard should describe its content; the captions now do.

### Added - "Latest published by Microsoft" reference table
The model already carried Microsoft's published AV signature, AV engine, Defender platform
and MDE sensor versions, but no visual had ever surfaced them — so Version Compliance
showed what the estate is running with nothing to compare it against. The reference table
now sits beside the per-OS-build posture table, which narrows to make room.

### Changed - Overview readability
The configuration-state legend moves beneath the donut, where the state names fit instead
of truncating mid-word, and the raw column name is dropped as its heading. The OS
distribution chart becomes a column chart; as a horizontal bar chart eleven distributions
in a 148px band rendered as a single row plus a scrollbar.

## [2026.08.20.08] - 2026-08-20

### Fixed - every chart was showing a machine-generated caption
Thirty-three visuals carried a hand-written title that never reached the screen. The text
was stored under `visual.objects.title`, but with no container title present Power BI
ignores it and falls back to an auto-generated caption built from the field names — which
is why pages read "AV Sig Up To Date, AV Sig Behind and AV Sig Out Of Date by DeviceType"
instead of the intended "AV signature currency by device type". All titles were promoted
to `visualContainerObjects.title`, the slot the renderer actually reads, and given
consistent styling with wrapping disabled so a caption no longer steals two lines of plot
area from the short charts.

### Fixed - three KPI cards read "- -" instead of a number
`Fully Migrated %`, `Legacy Migration %` and `Platform Outdated` still returned BLANK on an
estate where the numerator is legitimately zero. They now return 0 (and `Platform Outdated`
keeps its "N/A" answer for the separate case where no device can be graded at all).

### Fixed - Overview rendered three empty white boxes
The device-type, cloud-location and OS-distribution charts plotted only an achievement
measure, so at the start of a migration — exactly when a customer first opens the
dashboard — they had nothing to draw. Each now plots estate size alongside the achievement
measure, so there is always a bar and the gap between the two series is the point.

### Changed - tables and rail
Table headers wrap instead of truncating mid-word, body text is 9pt with row wrapping off,
and the permanently empty "Total" row is gone. Two rail captions are abbreviated so they
fit the 160px rail without clipping.


### Fixed - navigation rail labels, definitively
2026.08.20.06 corrected the formatting-payload *shape* for the rail buttons and the result was
still an empty rail — worse, in fact: the outline disappeared but no text arrived. Rendering the
published report twice isolated the real rule. On an `actionButton`, entries that carry a
`selector` are silently discarded by the service, and every styled property (the caption text,
its colour, the fill) lived in exactly such an entry; only the selector-free `show` toggles were
ever being honoured, which is why turning the outline *off* worked while turning the text *on*
did not.

The fix stops relying on the button's own formatting cards altogether. In PBIR only
`visualContainerObjects` is schema-typed, so the caption now lives in the container `title` and
the selected-page highlight in the container `background` — both guaranteed to be parsed. Button
height dropped from 54 px to 30 px so the caption fills the item the way a normal navigation list
does, and 12 px of left padding indents it off the rail edge.


### Fixed - navigation rail labels were invisible
The 2026.08.20.05 rail replaced the page-navigator visual with one action button per page,
which fixed the layout — but the buttons rendered as empty outlined rectangles with no text.
The cause was the shape of the formatting payload rather than the values in it. Power BI
requires a state-based formatting card (`text`, `fill`, `outline`, `icon`) to carry its `show`
toggle in its **own entry with no selector**, and the styled properties in a **second entry**
carrying `selector: { "id": "default" }`. Both had been written into a single selector-scoped
entry, so the service discarded every one of them: the label never appeared, and the outline
that was explicitly switched off stayed on. All 110 buttons have been regenerated with the
correct two-entry shape and now render as a legible vertical rail with the current page
highlighted.

### Fixed - KPI cards ignored every font setting
All eight KPI card visuals in the report are `cardVisual` (the modern card), but their
formatting objects were named `calloutValue` and `categoryLabel` — the names used by the
**legacy** `card` visual. The names did not match, so the service dropped them and every card
had been rendering at its default size rather than the intended 19-20 pt. The most visible
symptom was the Configuration Drill-down "Weakest Control" card, whose text value was
truncated to `Tamper |`. The objects are now `value` and `label` with the correct `fontColor`
property, and the layout uses `columnCount` rather than the non-existent `cardsPerRow`.

### Changed
- Card callout on Configuration Drill-down set to 17 pt so the longest control name fits
  without truncation.

## [2026.08.20.05] - 2026-08-20

### Fixed - navigation rail rendered unusable
The 2026.08.20.04 navigation rail used the built-in **page navigator** visual inside a
160 px column. That visual only lays its buttons out horizontally, so eleven buttons were
compressed to roughly 14 px each and their labels rendered as unreadable vertical stripes on
every page. The page navigator has been replaced with explicit navigation buttons - one per
visible page, stacked vertically, with the current page highlighted. Navigation is now
legible, keyboard-reachable and shows you where you are.

### Fixed - page titles and subtitles were clipped
Page titles were set in 20 pt inside a 38 px band, which cut the tops and descenders off
every heading and produced a scrollbar in the header. Titles are now 19 pt in a 46 px band.
Five subtitles overflowed their band - the Legacy AV/EDR subtitle ran to 423 characters -
and have been rewritten concisely. Content placement is unchanged.

### Fixed - KPI cards showed "- -" instead of 0
Counting measures built on CALCULATE(COUNTROWS(...), <filter>) return BLANK when no rows
match, which a card renders as "- -". On a security dashboard that is actively misleading:
"0 devices with an end-of-life OS" is good news, but "- -" reads as a broken report. The 24
count measures bound to KPI cards now return 0 when the estate genuinely has none. BLANK is
reserved for "not applicable". Measures used only in charts are unchanged, so charts keep
omitting empty categories rather than drawing rows of zeros.

### Changed - Configuration Drill-down and chart legibility
- The control detail table was too narrow for its numeric columns; the ranked bar chart now
  takes 640 px and the table 544 px, with wrapped column headers.
- The KPI callout was reduced to 19 pt so long control names are no longer truncated.
- Redundant axis titles were removed from 23 charts. The visual title already names the
  field, so "DeviceType" repeated beneath the axis was noise.

## [2026.08.20.04] — 2026-08-20

### Changed
- **Full UX revamp of the report.** The dashboard was rebuilt around an explicit design system
  instead of eleven independently laid-out pages:
  - **Canvas rebased to 1440×810** (from 1280×720). The extra width pays for the navigation rail
    without shrinking the content area — content is 1200px wide versus 1240px before — and the extra
    height gives every page 688px of usable content band instead of ~610px.
  - **Persistent left navigation rail on every page.** A page navigator in a 200px rail replaces
    reliance on the Power BI tab strip, so all eleven pages are reachable in one click from anywhere.
    Previously there was no in-report navigation at all.
  - **Standardised vertical rhythm.** Page title now always sits at y=16 (h=38) and the subtitle at
    y=54 (h=32), with content starting at y=98 and ending at y=786 on every page. Content start
    positions previously varied between 58px and 214px across pages.
  - **Device Inventory gained a page title and subtitle**; it previously rendered a bare table with
    no heading. **Non-Compliant Devices** and **OS Posture** gained the subtitles they were missing.
  - **Type scale rebalanced** for the larger canvas (page titles 18pt→20pt, visual titles 12→13,
    labels/axes/legends 9→10) so effective on-screen text size is preserved, not reduced.
  - **Theme extended** with table, matrix and slicer styling (header fill, row banding, 4px row
    padding, hairline horizontal gridlines only) and softer, more diffuse card shadows.

### Fixed
- **Configuration Drill-down rebuilt — the twelve pie charts were reporting misleading numbers.**
  Each pie plotted `Total Devices` split by a control's raw state, which meant devices reporting
  `N/A` for a control were counted in that control's denominator. Tamper Protection, for example,
  is not applicable on Linux, and no control reports for a device that is not onboarded — so every
  pie understated true coverage by an amount that varied per control and per estate mix.
  - Added a disconnected **`SecurityControl`** dimension (12 rows) plus measures that compute
    coverage as *healthy ÷ applicable*, explicitly excluding `N/A` from the denominator. The table
    carries no relationship by design: every measure evaluates against `DeviceHealth` inside
    `CALCULATE`, so all fourteen page filters continue to apply exactly as before.
  - `Antivirus mode` is now scored correctly against `Active` rather than `GOOD`, and `Unknown` is
    excluded from its denominator — the previous pie treated `Unknown` as a real state.
  - The twelve pies are replaced by a **single ranked bar chart** (worst control first), a **KPI
    strip** (devices in scope, average coverage, controls below the 90% target, weakest control and
    its coverage) and a **detail table** giving applicable / healthy / gap counts per control.
    Twelve pies could show twelve values but could not rank them; ranking is the entire question
    this page exists to answer.
- Corrected overlapping visuals on **Legacy AV Migration** (2px) and **KPI Guide** (6px), and
  aligned the Legacy AV Migration table to the section label beside it.

## [2026.08.20.03] — 2026-08-20

### Fixed
- **Deep audit of all KQL queries and KPI measures.** Comprehensive review identified and fixed 35 performance and clarity issues:
  - Removed 31 redundant `+ 0` arithmetic operations from DeviceHealth measures (cleaner DAX for maintainability)
  - Removed 3 redundant `+ 0` operations from EstateConfigState measures
  - Added missing `formatString` to 'Legacy Slowest Product' measure in LegacyAvMigration table
  - Removed meta-version references from DeploymentTrend.kql (improved documentation clarity)
- **Removed all instructional content from production code and GUI.** Replaced `[SETUP]`/`[DATA]` tags in Test-UpgradeIntegration.ps1 with proper logging helpers; verified all 11 report pages clean of customer-unfriendly instructional text.
- **Verified all KPI measures for business logic correctness.** Confirmed 90 total measures across all tables align with Defender lifecycle semantics (MDAV versioning, MDE EDR versioning, OS EOL, legacy AV EOL).
- **Live data validation passed.** Spot-checked all major pages in MCAPS workspace; all KPIs render with correct data, Arc/AMA coverage accurate, legacy vendor names preserved, Version Compliance split (MDAV/MDE) correct.

### Changed
- All report visual titles, descriptions, and tooltips reviewed and confirmed professional (no meta-instructions).

## [2026.08.20.01] — 2026-08-20

### Fixed
- **Upgrading a pre-2.x deployment no longer empties the migration table (data loss).**
  Releases before the vendor-neutral rename stored ingested devices in
  `deploy/trend-inventory.local.csv`; the current release reads
  `deploy/legacy-inventory.local.csv`. The interactive wizard and `Import-LegacyAvInventory.ps1`
  already handled the old filename, but `New-LegacyMigrationSeedOverride` — the function the
  non-interactive `Deploy-Dashboard.ps1` path actually uses to build the published seed — did not.
  Re-deploying over an existing workspace therefore republished the semantic model with an EMPTY
  `LegacyAvMigration` table, silently discarding every previously ingested device. The seed builder
  now adopts the pre-2.x store automatically (copying it to the new name, or reading it in place if
  the copy fails).
- **A failed Defender lookup can no longer overwrite live migration data.** If the Defender API call
  failed mid-deploy (expired secret, missing permissions, transient outage) the mapping was skipped
  and an empty table was published over a workspace that already held data, because
  `updateDefinition` REPLACES the table rather than merging it. The deploy now fails with an
  explanatory error whenever devices are already ingested, leaving the live table untouched.

### Added
- `-AllowEmptyLegacyTable` on `Deploy-Dashboard.ps1`, to publish an empty migration table
  deliberately (the previous, implicit behaviour) when that is genuinely intended.
- `deploy/Test-UpgradePath.ps1` — an offline, Windows PowerShell 5.1 compatible regression suite
  (33 assertions) proving a pre-2.x deployment upgrades in place without losing data, that
  multi-vendor rows keep their originating product, and that no model or report binding still
  references the pre-2.x `TrendMigration` table.
## [2026.08.19.01] — 2026-08-19

### Added
- **Vendor-neutral legacy AV/EDR ingest.** The migration mapping is no longer Trend-Micro-specific.
  A built-in catalog auto-detects 21 products across ~20 vendors (Trend Micro, Symantec/Broadcom,
  McAfee/Trellix, Sophos, CrowdStrike, SentinelOne, Kaspersky, ESET, Bitdefender, Carbon Black,
  Cortex XDR, Cybereason, Cylance, and more) from the CSV header signature. Unrecognised exports are
  ingested and labelled `Legacy AV/EDR` rather than failing.
- **Per-row product and vendor labels.** Every ingested device row carries its own `LegacyProduct`
  and `LegacyVendor` for its entire life, so an estate migrating off SEVERAL tools at once is
  tracked correctly. Resolution order: `-SourceProduct` override -> per-row CSV column -> header
  auto-detection.
- **Multi-product reporting.** New `LegacyVendor` column; new measures `Legacy Products In Scope`,
  `Legacy Products Not Complete`, `Legacy Slowest Product` and `Legacy Slowest Product %`. The
  **Legacy AV Migration** page gains a *Migration progress by legacy product* bar chart, legacy
  product/vendor page filters, a products-in-scope KPI, and product/vendor as the leading columns of
  the detail table.
- **Multi-vendor on-box detection.** `DeviceHealth` and `templates/defender-kql-pack.kql` now
  recognise ~45 product marks across ~25 vendors (was Trend-only), driving `LegacyAvInstalled` /
  `LegacyAvProduct` and the **Legacy Remaining** measure. Defender's own components are excluded.
- **`Test-ConfigSecurity`** — warns (never blocks) when `config.json` sits in a cloud-synced
  folder, inside a non-git-ignored work tree, or carries an over-broad ACL.
- **Regression suites.** `deploy/Test-LegacyIngest.ps1` (40 assertions over the ingest engine) and
  `deploy/Test-PbipIntegrity.ps1` (validates every report binding against the model).

### Changed
- **Windows PowerShell 5.1 compatibility across every script.** Removed PS7-only syntax, added a
  `Test-PowerShellBaseline` guard, and raised the TLS floor to 1.2 (1.3 when available) — .NET
  Framework's SSL3/TLS1.0 default otherwise fails Entra/Fabric/Defender calls with a misleading
  "connection was closed unexpectedly".
- **Renames.** `Import-TrendInventory.ps1` -> `Import-LegacyAvInventory.ps1`; `TrendMigration`
  table -> `LegacyAvMigration`; `TrendId`/`TrendSource` -> `LegacyId`/`LegacyProduct`;
  `DeviceHealth[TrendInstalled|TrendProduct|TrendAgentPresent]` ->
  `[LegacyAvInstalled|LegacyAvProduct|LegacyAvAgentPresent]`; "Trend Migration" page ->
  "Legacy AV Migration". The time-series `DeploymentTrend` table and its trend history are
  unchanged — "trend" there means trend-over-time.
- **`Replace` now warns** when it would discard devices belonging to a different product, and the
  import prints a per-product breakdown.
- **Documentation restructured.** `README.md` cut from 509 to ~100 lines (overview, screenshots,
  quick start, doc index). Detail moved to `docs/multi-vendor-ingest.md`, `docs/deployment.md`,
  `docs/architecture.md`, `docs/security.md`, `docs/troubleshooting.md`, plus a screenshot
  capture guide at `docs/images/README.md`.

### Fixed
- **Broken model reference** — `EstateConfigState` referenced `DeviceHealth[TrendInstalled]`,
  which did not resolve; it is now correctly bound.
- `_Common.ps1` contained a PowerShell 7-only null-coalescing operator that prevented the whole
  toolkit from parsing under Windows PowerShell 5.1.

### Compatibility
- All 1.x parameter names, config keys and function names remain as aliases
  (`-TrendCsv`, `-TrendMode`, `-TrendSource`, `trendCsv`, `Get-Trend*`, ...), old config
  keys are read as a fallback, and a pre-existing `deploy/trend-inventory.local.csv` is adopted
  automatically on first run.
## [2026.07.18.03] — 2026-07-18

### Added
- **Guided interactive wizard.** Running `Deploy-Dashboard.ps1` with no parameters now starts a
  step-by-step wizard (config path, action menu, workspace selection, Trend-CSV import, force,
  confirmation) so the script is usable without memorising switches. Any explicitly supplied
  parameter skips the wizard.
- **GitHub self-heal for missing or corrupt local content.** Preflight now runs a deep
  `Test-ProjectIntegrity` check (model/report TMDL, seed placeholders, `definition.pbir`, ≥1 report
  page, non-empty KQL assets). When content is missing or invalid it automatically re-downloads the
  `DefenderMigrationDashboard` folder from GitHub and re-validates. The restore is EOL-insensitive and
  selective — only genuinely missing/different files are replaced, so it never causes CRLF/LF churn.
  Suppress with **`-SkipGitHubRestore`** (or `skipGitHubRestore` in config.json).
- **Ingested-data preservation across updates.** The previously imported **Trend device list** is now
  reused automatically when a deploy runs without `-TrendCsv` (instead of being emptied), and the
  **DeploymentTrend history** accumulates across deploys (beyond the 30-day query window) so trend
  charts keep their history. Both stores are **backed up** (timestamped, last 15 kept) before every
  overwrite, and the last-known history is re-pushed if a live hunting query transiently returns zero
  rows.

### Changed
- **More resilient uninstall (`Remove-Dashboard.ps1`).** Item removals now retry transient failures
  (3 attempts, backoff), missing items are skipped cleanly, a partial teardown never blocks the rest,
  workspace deletion is skipped when any item failed, and the script exits with a clear summary/exit
  code so it is safe to re-run. `-WorkspaceId` is now optional when supplied via `-ConfigPath`.

## [2026.07.18.02] — 2026-07-18

### Added
- **Update-in-place with a version preflight built into `Deploy-Dashboard.ps1`.** Every deploy now
  first compares three versions — the **local** content (the KPI Guide version marker), the latest
  released on **GitHub** (top of `CHANGELOG.md`, fetched over an unauthenticated raw URL), and what
  is **live in the workspace** — and only republishes when the workspace is behind.
  - The live version is read from the semantic-model item's **description** via a read-only Fabric
    `GET item` call, so an update check needs only `Item.Read.All` / workspace **Viewer** — the
    least privilege possible. The version is stamped onto that description after each successful
    publish.
  - New switches: **`-CheckVersionOnly`** (read-only; report versions and whether an update is
    available, then exit), **`-Force`** (deploy even when already current — e.g. to refresh live
    data or re-seed trend/AV tables), **`-SkipVersionCheck`** (offline/air-gapped), and
    **`-SkipGitHubCheck`** (also `skipGitHubVersionCheck` / `githubRawChangelogUrl` in config.json).
  - A `git pull` reminder is printed when the local clone is behind GitHub, and a rollback guard
    blocks (without `-Force`) when the workspace is newer than the local content.

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


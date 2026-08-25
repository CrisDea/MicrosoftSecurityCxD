# Architecture & data model

[← Back to the README](../README.md)

How the dashboard gets its data, what each page shows, and the design rules behind the KPIs.

---

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
3. **Baselines (what Microsoft currently publishes)** — read live on every refresh from
   `learn.microsoft.com` and `www.microsoft.com`, both bound **Anonymous / Public**. See
   ["Latest version" baselines](#latest-version-baselines) below.
4. No secret is ever written to the committed project files. The DeviceHealth query carries no
   credentials, and the trend table carries only a base64 placeholder that the deploy script fills.

## Third-party AV / EDR classification

The two histograms count machines by the third-party product detected in `DeviceTvmSoftwareInventory`.
Product matching uses a **hardcoded catalogue** of enterprise antivirus and EDR/XDR vendors (Trend
Micro, Sophos, McAfee/Trellix, Symantec, Kaspersky, ESET, Bitdefender, and more for AV; CrowdStrike
Falcon, SentinelOne, Carbon Black, Cortex XDR, Cybereason, Tanium, and more for EDR), so the graphs are
generic across estates. Machines with none detected fall into a **None** bucket so the bars total the
full estate.

## "Latest version" baselines

Two different questions get asked about versions, and the dashboard answers both:

| Question | Where it comes from |
|---|---|
| Is this device on the newest version *anyone in this estate* is running? | Derived from the estate itself at refresh — the per-OS-build maximum observed across your own devices. This is the marker that grades every device green / amber / red. |
| Is that estate-wide newest version actually *current with Microsoft*? | The **Baselines** table, read live from Microsoft's own pages. |

The second is what stops a fleet that is uniformly six months behind from reporting itself 100% compliant.

**Baselines refreshes itself.** It is not a hand-maintained list — it re-reads two public,
unauthenticated Microsoft pages on **every dataset refresh**:

- [Defender for Endpoint release notes](https://learn.microsoft.com/en-us/defender-endpoint/microsoft-defender-endpoint-releases)
  — the Windows AV engine and platform, the Windows EDR sensor build, and the current macOS, Linux,
  Android and iOS builds.
- [WDSI security intelligence updates](https://www.microsoft.com/en-us/wdsi/defenderupdates)
  — the AV signature version. It changes several times a day and is deliberately not carried on the
  release-notes page, so it has to come from here.

Both are plain GETs bound **Anonymous / Public**, and neither response is used to build the other's
request, so the pair satisfies the Power Query data-combination firewall on cloud refresh. The deploy
script also captures a snapshot of the same values and embeds it as a per-row fallback: if a page is
unreachable or is restructured, that row degrades to last-known-good rather than failing the refresh.
The `Source` and `RetrievedUtc` columns record which page each value came from and when, so a stale
value is visible rather than silent.

**Platform version namespaces are not interchangeable.** This is the part that most often gets
reported wrongly. Defender on macOS and Linux does not use the Windows version series, and the
number a device reports as its *EDR version* is not its app build:

| Platform | Device reports as… | Namespace | Published reference |
|---|---|---|---|
| Windows | `AVProductVersion` | `4.18.x` | AV platform |
| Windows | `AVEngineVersion` | `1.1.x` (short last segment) | AV engine |
| Windows | `EDRVersion` | `10.8xxx` | EDR sensor |
| macOS | `AVProductVersion` | `101.x` | App build |
| macOS | `EDRVersion` | `20.x` | EDR release |
| Linux | `AVProductVersion` | `101.x` | App build |
| Linux | `EDRVersion` | `30.x` | EDR release |
| Android / iOS | app version | `1.0.x` / `1.1.x` | App build |

So a Linux device reporting `30.126052` is **not** comparable to the `101.26062.0007` app build,
even though both describe the same release. The Baselines table therefore carries the app build and
the EDR release as separate rows per platform, taken from the `Release version` field the release
notes publish alongside each build.

Two further caveats the table encodes:

- **Security intelligence is shared across platforms**, so it is listed once as *All platforms*
  rather than repeated per OS.
- **The macOS/Linux engine is labelled *in-box***: it is the engine that shipped with that release,
  but the running engine advances independently through the signature channel and is routinely
  *newer* than the released value. A device ahead of this number is healthy, not stale.

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
- **`Migration %` measures legacy-AV-list coverage.** The headline `Migration %` is *healthy, onboarded MDE
  devices ÷ the ingested legacy AV asset list* (`Legacy Source Devices`) — i.e. how much of the legacy AV estate
  is now protected by a healthy Defender sensor. It requires a legacy AV list (`-LegacyCsv`); with no legacy AV
  list ingested the card shows **N/A** rather than a misleading 0%. The older onboarded-÷-all-Defender-
  devices ratio is retained separately as `MDE Onboarding Coverage %`.

## Pages
1. **Overview** — migration & configuration summary: fully-migrated KPIs, estate configuration state, client-vs-server and cloud/on-prem splits, healthy-by-OS, and the third-party AV / EDR histograms. The **estate configuration-state donut** spans the whole estate: green = fully migrated & configured, amber = onboarded but needs attention, **red = not onboarded but discovered and on the ingested legacy AV list**, **grey = on the legacy AV list only (never discovered by Defender)**. It is driven by the `EstateConfigState` table, which unions MDE-discovered devices with legacy-AV-only devices so blind spots are visible.
2. **Configuration Drill-down** — per-check RAG posture (sensor, AV mode/signature/engine/platform, real-time, cloud, behaviour, tamper, network, PUA, OS), each drillable to device. The per-check pies use the full page width; slicing is via the native **Filters pane** (friendly-named filter cards), not an on-canvas rail.
3. **Device Inventory** — the full onboarded-device results table on its own full-page layout (moved off the drill-down page). Columns follow the **MDE Major Health Check (v2.9.5)** order and include the AV platform / engine / signature **update rings**, the AV signature version, and the OS update-currency columns (OS product, build/UBR, support state, EOL date, patch currency, months behind, EDR platform).
4. **Migration Overview** — active vs stale/removed trend by client/server (migration maturity).
5. **Legacy AV Migration** — maps each device in your **third-party AV/EDR export** (Trend Micro, Symantec, CrowdStrike, SentinelOne, ...) to the current Defender inventory: Legacy Source Devices, Legacy Migrated, Legacy Migration % and Legacy Not In Defender KPI cards, a migration-status donut, and the full per-device mapping table (legacy product, legacy vendor, legacy name → Defender name, match type, score, onboarding status). Populated with `-LegacyCsv` at deploy time — see *Legacy AV/EDR migration mapping*.
6. **Version Compliance** — KPIs and "devices not on latest" by component and OS.
7. **Non-Compliant Devices** — device-level triage table.
8. **OS Posture** — OS update-currency view: KPI cards (supported / EOL-imminent / unsupported, EDR legacy platform, monthly coverage), OS lifecycle-support and monthly patch-currency charts (Windows with UBR, fleet-relative), devices by OS product, and a detail table (product, build/UBR, support state, EOL date, patch currency, EDR platform, last seen).
9. **Mobile (MDE)** — mobile-device management state.
10. **Device Details** — a hidden drill-through page: right-click any chart element → *Drill through* to see the full per-device record, then **Export data**.
11. **KPI Guide** — a plain-language reference page explaining what every headline metric means, organised by the report page it appears on (no technical knowledge required).

Every visible page carries the same filters: Client/Server, OS platform,
OS version, Healthy, Managed by / onboarding, Legacy AV installed, AD domain, Cloud/on-prem, Citrix VDI,
Onboarding status, Active/Stale, Sensor connectivity, **MDE tags**, and Last seen. These are now
presented consistently as cards in the native **Filters pane** on the right of every page (open it
with the filter icon); the previous on-canvas slicer rail has been removed.



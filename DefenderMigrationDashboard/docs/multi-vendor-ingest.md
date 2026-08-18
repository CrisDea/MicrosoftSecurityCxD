# Legacy AV/EDR → Defender migration mapping

[← Back to the README](../README.md)

The **Legacy AV Migration** page answers *"which of the devices in my third-party AV/EDR estate are
now in Defender, and which still need migrating?"* — using your legacy console export as the source
of truth.

It is **vendor-neutral**. Trend Micro, Symantec, McAfee/Trellix, Sophos, CrowdStrike, SentinelOne,
Kaspersky, ESET, Bitdefender, Carbon Black, Cortex XDR and others are all first-class, and a single
deployment can track **several products at once**.

---

## Multi-product estates

Most real migrations are not "one tool → Defender". A customer typically runs Apex One on clients,
Deep Security on servers, and a CrowdStrike pilot in one business unit — all at the same time.

**Every ingested row carries its own `LegacyProduct` and `LegacyVendor` label**, on every line, for
the entire life of the record. Nothing is flattened into a single global "source" value. That means:

- The **Legacy AV Migration** page can be sliced by product or vendor (page filters are provided).
- The **"Migration progress by legacy product"** bar chart shows Migrated / Onboarding pending /
  Not in Defender per product, so you can see which console is lagging.
- The KPI row includes **Legacy Products In Scope**, and the model exposes
  `Legacy Products Not Complete`, `Legacy Slowest Product` and `Legacy Slowest Product %`.
- The detail table leads with **Legacy product** and **Legacy vendor** columns.

### Building one estate view from several exports

Use `-LegacyMode Append`. Run the import **once per console export**; each run stamps its own rows
and merges them into the local master store.

```powershell
# 1st console
pwsh ./deploy/Import-LegacyAvInventory.ps1 -LegacyCsv .\apex-one.csv       -ConfigPath .\deploy\config.json -LegacyMode Append
# 2nd console
pwsh ./deploy/Import-LegacyAvInventory.ps1 -LegacyCsv .\deep-security.csv  -ConfigPath .\deploy\config.json -LegacyMode Append
# 3rd console
pwsh ./deploy/Import-LegacyAvInventory.ps1 -LegacyCsv .\falcon-hosts.csv   -ConfigPath .\deploy\config.json -LegacyMode Append -Materialize
```

> **`Replace` wipes the other vendors.** `Replace` (the default) makes the supplied export the
> *entire* legacy list. If you have already ingested another product, use `Append` — the script
> warns you when a `Replace` is about to discard devices belonging to a different product.

**A device found in two consoles counts twice — deliberately.** Two agents are installed, so there
are two removals to perform. The de-duplication fallback key includes the product, so the same host
under Apex One and under Falcon remains two distinct migration facts.

---

## Supported products (auto-detection)

The header signature of the CSV is scored against a built-in catalog. Recognised out of the box:

| Vendor | Products |
|--------|----------|
| Trend Micro | Apex One, OfficeScan, Deep Security, Worry-Free, Vision One |
| Broadcom / Symantec | Symantec Endpoint Protection (SEP), SEP Cloud |
| Trellix / McAfee | ENS, ePO-managed endpoints, MVISION |
| Sophos | Intercept X, Sophos Central |
| CrowdStrike | Falcon |
| SentinelOne | Singularity |
| Kaspersky | Kaspersky Endpoint Security |
| ESET | ESET PROTECT / Endpoint |
| Bitdefender | GravityZone |
| VMware / Broadcom | Carbon Black Cloud, Cb Response |
| Palo Alto Networks | Cortex XDR, Traps |
| Cybereason | Cybereason EDR |
| BlackBerry | CylancePROTECT / OPTICS |
| Others | Webroot, Malwarebytes, Check Point Harmony, WithSecure/F-Secure, Fortinet FortiClient, Cisco Secure Endpoint |

**Anything not in the catalog still works.** An unrecognised export is ingested and labelled
`Legacy AV/EDR` rather than failing. To label it properly, pass the name yourself:

```powershell
pwsh ./deploy/Import-LegacyAvInventory.ps1 -LegacyCsv .\acme-export.csv `
     -SourceProduct "Acme Shield 7" -SourceVendor "Acme Security" -LegacyMode Append
```

Resolution order is: **`-SourceProduct` override** → **a per-row `LegacyProduct` column in the CSV**
→ **header auto-detection** → `Legacy AV/EDR`.

---

## CSV format

The ingest needs only two things per device — a **unique id** and a **host name** — so a raw console
export or a minimal hand-built list both work.

| Field | Purpose | Auto-detected from |
|-------|---------|--------------------|
| **Legacy id** (recommended) | The source tool's own unique device identifier — the de-duplication key across imports | Apex One `GUID`; Deep Security `Host GUID` / `Agent GUID`; CrowdStrike `Device ID` / `AID`; SentinelOne `Agent ID`; Carbon Black `Device Id`; or a `LegacyId` / `TrendId` column |
| **Device name** (required) | Host/endpoint name — matched against the Defender inventory | `Endpoint`, `Endpoint Name`, `Host Name`, `Hostname`, `Computer Name`, `Device Name`, `Machine Name`, `Name`, `DeviceName` |
| **Legacy product** (optional) | Which product the row came from | A `LegacyProduct` / `TrendSource` column, header signature, or `-SourceProduct` |
| **Legacy vendor** (optional) | Vendor label | A `LegacyVendor` column, inferred from the product, or `-SourceVendor` |

Everything else in the export is ignored.

Minimal hand-built list (matches the starter template):

```csv
LegacyId,DeviceName,LegacyProduct,LegacyVendor
11111111-1111-1111-1111-111111111111,WS01.contoso.com,Trend Micro Apex One,Trend Micro
22222222-2222-2222-2222-222222222222,FILESERVER01,Trend Micro Deep Security,Trend Micro
33333333-3333-3333-3333-333333333333,WS02.contoso.com,CrowdStrike Falcon,CrowdStrike
```

A blank, header-only starter is at
[`templates/legacy-inventory-template.csv`](../templates/legacy-inventory-template.csv). It ships
with **no rows** — the repository never contains real or sample device data.

**Notes**

- **FQDN or short hostname both accepted.** `WS01`, `WS01.contoso.com` and the AD form `WS01$` all
  resolve to the same host. Only the part **before the first dot** is the hostname; the rest is the
  domain suffix used for the domain-only fuzzy step.
- **Encoding/quoting** — a standard comma-separated, UTF-8 CSV with a header row. Values may be quoted.
- **`.xls`/`.xlsx` exports must be saved as CSV first.** Many consoles (and sensitivity-label /
  IRM-protected exports) produce `.xls`; open it and *Save As → CSV UTF-8* before ingesting.
- **Upgrading from 1.x** — a pre-existing `deploy/trend-inventory.local.csv` is detected and adopted
  automatically; its rows are labelled with their original Trend product.

---

## Matching algorithm

- **Matched against the same inventory as the dashboard** — the current Defender device list is read
  from the paged `GET /api/machines` export endpoint (the same source as DeviceHealth), so the
  mapping never disagrees with the rest of the report. Only `Machine.Read.All` is required.
- **Exact hostname, domain-tolerant matching** — the **short hostname must match exactly** (after
  normalising case, a trailing `$`, and punctuation), so two different machines are never conflated.
  Fuzzy tolerance applies **only to the DNS domain suffix**: a device whose hostname matches is still
  accepted when its domain differs but scores at or above `-MatchThreshold` (default 82) — e.g.
  `ws01.contoso.com` vs `ws01.contoso.local` — and is classified as a **Fuzzy** match. A hostname
  with no domain matches any domain for that host, preferring an onboarded record on ties.
- Each row is classified **Migrated to Defender** (matched + onboarded), **Matched — not onboarded**,
  or **Not found in Defender**. A same-host / very-different-domain pair (`ws09.contoso.com` vs
  `ws09.fabrikam.com`) is **rejected**.

---

## Why it is a deploy-time ingest, not an in-report upload

The model refreshes in the Power BI service as a Service Principal with no on-premises data gateway,
so a locally uploaded file cannot be re-read on a cloud refresh. The mapping is therefore computed at
deploy time and embedded in the **LegacyAvMigration** table (the same deploy-time seed pattern as the
trend history). Re-run the deploy — or `Import-LegacyAvInventory.ps1 -Materialize` — whenever an
export changes. See [architecture.md](architecture.md).

---

## Recommended workflow

**Option A — preview first, then deploy (recommended).**

```powershell
# 1. Preview the mapping without touching the model.
#    Prints a per-product breakdown and writes legacy-migration-mapping.csv for review.
pwsh ./deploy/Import-LegacyAvInventory.ps1 -LegacyCsv .\export.csv -ConfigPath .\deploy\config.json

# 2. (Optional) tune domain tolerance, or append another product, then re-preview.
pwsh ./deploy/Import-LegacyAvInventory.ps1 -LegacyCsv .\export.csv -ConfigPath .\deploy\config.json -MatchThreshold 90
pwsh ./deploy/Import-LegacyAvInventory.ps1 -LegacyCsv .\falcon.csv -ConfigPath .\deploy\config.json -LegacyMode Append

# 3. Embed the reviewed mapping into the LegacyAvMigration table.
pwsh ./deploy/Import-LegacyAvInventory.ps1 -LegacyCsv .\export.csv -ConfigPath .\deploy\config.json -Materialize

# 4. Deploy.
pwsh ./deploy/Deploy-Dashboard.ps1 -ConfigPath .\deploy\config.json -Wait
```

**Option B — one shot (ingest + deploy in a single command).**

```powershell
pwsh ./deploy/Deploy-Dashboard.ps1 -ConfigPath .\deploy\config.json -LegacyCsv .\export.csv -Wait
# Append a second product on a later deploy:
pwsh ./deploy/Deploy-Dashboard.ps1 -ConfigPath .\deploy\config.json -LegacyCsv .\falcon.csv -LegacyMode Append -Wait
```

To start over, delete `deploy/legacy-inventory.local.csv` (or run any `-LegacyMode Replace` import),
and use `Import-LegacyAvInventory.ps1 -RestorePlaceholder` to clear the model table before
committing.

You can also set `"legacyCsv"`, `"legacyMode"`, `"legacyProduct"` and `"legacyVendor"` in
`config.json` so the export is picked up automatically on every deploy.

---

## On-box detection (independent of the CSV)

Separately from the ingested list, the **DeviceHealth** table detects a legacy agent that is *still
installed* on a Defender-onboarded device, using the Defender TVM software inventory. This is what
drives `LegacyAvInstalled`, `LegacyAvProduct` and the **Legacy Remaining** measure — it catches
devices the console export missed, and confirms the old agent was actually removed. Roughly 45
product marks across ~25 vendors are recognised; see
`pbip-project/Defender-Migration.SemanticModel/definition/tables/DeviceHealth.tmdl` and
`templates/defender-kql-pack.kql`.

---

## Backward compatibility

All 1.x parameter names still work as aliases, so existing scripts and pipelines keep running:

| Old | New |
|-----|-----|
| `-TrendCsv` | `-LegacyCsv` |
| `-TrendMode` / `-Mode` | `-LegacyMode` |
| `-TrendSource` / `-Source` | `-SourceProduct` |
| `-TrendInventoryStore` | `-InventoryStore` |
| `trendCsv`, `trendMode`, `trendSource`, `trendInventoryStore` (config.json) | `legacyCsv`, `legacyMode`, `legacyProduct`, `legacyVendor`, `legacyInventoryStore` |
| `Import-TrendInventory.ps1` | `Import-LegacyAvInventory.ps1` |

Old config keys are read as a fallback, and `Get-Trend*` function aliases are retained.

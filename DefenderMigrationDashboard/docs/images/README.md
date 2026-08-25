# Dashboard screenshots

The images referenced by the [README](../README.md) live in this folder.

Four **aggregate-only** pages are committed. They report counts, percentages, control names and
OS build strings — never an individual machine. The pages that do list machines (Device Inventory,
Device Details, Non-Compliant Devices, OS Posture) are deliberately **not** shipped, because a
screenshot of a real tenant exposes device names, domains and estate size.

If you replace these with captures of your own, use a **demo or anonymised** tenant.

## What is committed

| File | Page | Why it is safe |
|------|------|----------------|
| `overview.png` | Overview | Counts and the estate configuration-state donut only |
| `configuration-drilldown.png` | Configuration Drill-down | Control names and coverage percentages |
| `version-compliance.png` | Version Compliance | OS builds and component versions, no device names |
| `kpi-guide.png` | KPI Guide | Pure documentation, no data at all |

## How to capture

1. Open the published report in the Power BI service (or the `.pbip` in Power BI Desktop).
2. Set the browser to **100% zoom** and a **1920×1080** window so page proportions match.
3. Use **View → Full screen** (`Ctrl`+`F11` in the service) to drop the chrome.
4. Screenshot the canvas only, save as PNG into this folder using the names above.

`deploy/Export-Report.ps1` renders the whole report to PDF, which is the easiest way to get clean,
chrome-free page images at a consistent size.

## Before committing

- Confirm no real hostnames, domains, user names, IP addresses, tenant ids or workspace GUIDs are
  legible. Blur anything that is.
- Prefer a demo tenant over redacting a production one.
- Keep each file under ~500 KB so the repository stays light.

# Dashboard screenshots

The images referenced by the [README](../README.md) live in this folder. They are **not** committed
by default — a screenshot of a real tenant contains customer device names, domains and estate size.

Capture your own from a **demo or anonymised** tenant.

## What to capture

| File | Page | Frame |
|------|------|-------|
| `overview.png` | Overview | Whole canvas, including the estate configuration-state donut |
| `legacy-av-migration.png` | Legacy AV Migration | Whole canvas — KPI row, status donut, **Migration progress by legacy product** bar chart, detail table |
| `migration-overview.png` | Migration Overview | Whole canvas |
| `device-health.png` | Device Health | Whole canvas |

## How to capture

1. Open the published report in the Power BI service (or the `.pbip` in Power BI Desktop).
2. Set the browser to **100% zoom** and a **1920×1080** window so page proportions match.
3. Use **View → Full screen** (`Ctrl`+`F11` in the service) to drop the chrome.
4. Screenshot the canvas only, save as PNG into this folder using the names above.

## Before committing

- Confirm no real hostnames, domains, user names, IP addresses, tenant ids or workspace GUIDs are
  legible. Blur anything that is.
- Prefer a demo tenant over redacting a production one.
- Keep each file under ~500 KB so the repository stays light.

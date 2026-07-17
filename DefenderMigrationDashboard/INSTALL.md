# Install Guide

Step-by-step deployment of the Defender Migration Dashboard. Every script checks its prerequisites
before it runs and is safe to run again — if a step fails it stops with a clear message so you can
fix the cause and re-run.

> The dashboard queries **your live Microsoft Defender for Endpoint tenant** via the export-assessment
> REST APIs (`api.securitycenter.microsoft.com`). You need an Entra app registration with the four
> WindowsDefenderATP application permissions (`Machine.Read.All`, `Software.Read.All`,
> `Vulnerability.Read.All`, `AdvancedQuery.Read.All`, admin-consented). `Bootstrap-Deployment.ps1`
> creates or reuses one and writes a git-ignored `config.json` for you.

---

## Prerequisites

| Requirement | Notes |
|---|---|
| PowerShell 5.1+ or 7.x | `pwsh` recommended. Preflight blocks older versions. |
| Azure CLI (`az`) | For **interactive** publish auth. Not needed if you publish with the app (service principal). Install: https://aka.ms/installazurecli |
| Entra app + WindowsDefenderATP perms | `Machine.Read.All`, `Software.Read.All`, `Vulnerability.Read.All`, `AdvancedQuery.Read.All` — Application, admin-consented. Used by the model to query Defender and build the trend seed. Run `Bootstrap-Deployment.ps1` to set it up. |
| A capacity-backed workspace | Fabric / Premium / PPU. The semantic model needs a capacity to host it. |
| Workspace Admin/Member | On the target workspace (see `PERMISSIONS.md`). |

No Power BI Desktop required — everything is headless via REST.

---

## Decision tree

```
How are you publishing?
├── Interactive (you, at a terminal, az login)   → Option A  (still supply the app creds for the query)
└── Service principal (automation / CI)           → Option B

Which workspace?
├── Let me pick from a list                       → -SelectWorkspace
├── I know its GUID                               → -WorkspaceId <guid>
└── Create a new one on a capacity                → -WorkspaceName <name> -CapacityId <guid>

Data (always live):
└── Bootstrap once to grant the WindowsDefenderATP permissions (see PERMISSIONS.md), then deploy.
```

---

## Step 0 — Bootstrap the app (once)

Create or reuse an Entra app and grant it the WindowsDefenderATP permissions the model uses to read
Defender. Run this as an admin who can grant consent:

```powershell
# Create a new app
pwsh ./deploy/Bootstrap-Deployment.ps1 -Mode CreateNew -DisplayName "defender-migration-dashboard"

# …or reuse an existing app (and add it to the workspace for SP publishing)
pwsh ./deploy/Bootstrap-Deployment.ps1 -Mode UseExisting -AppId <app-guid> -WorkspaceId <ws-guid>
```

This writes a git-ignored `deploy/config.json` (tenant id, client id, secret, workspace id), grants
the **four WindowsDefenderATP permissions** with admin consent, and verifies a token can be acquired.
Keep `config.json` local — never commit it or place it in a cloud-synced folder.

---

## Option A — Interactive publish (you sign in)

1. Sign in to the target tenant (for the Fabric publish):
   ```powershell
   az login --tenant <tenant-guid>
   ```
2. Deploy, picking the workspace from a list. The app credentials from `config.json` are bound to the
   dataset as a Service Principal so it can query Defender:
   ```powershell
   pwsh ./deploy/Deploy-Dashboard.ps1 -ConfigPath ./deploy/config.json -SelectWorkspace -Wait
   ```
   Or into a named workspace, creating it if needed:
   ```powershell
   pwsh ./deploy/Deploy-Dashboard.ps1 -ConfigPath ./deploy/config.json -WorkspaceName "Security" -CapacityId <capacity-guid> -Wait
   ```

### Expected output
```
==> Preflight checks
    PowerShell 7.x
    Azure CLI present
    PBIP project found (…SemanticModel + …Report)
    Signed in as <you> (tenant …)
==> Resolving workspace
    Using workspace '…' (…) on capacity …
==> Publishing semantic model 'Defender Migration'
    Trend history generated: 97 day/group rows
    Live model: DeviceHealth binds to Defender via a Service Principal; trend history materialised at deploy
    Creating new SemanticModel 'Defender Migration'
==> Publishing report 'Defender Migration'
    Creating new Report 'Defender Migration'
==> Validating report binding
    Report is bound to the semantic model.
==> Binding data-source credentials (Service Principal)
    Service Principal bound (https://api.securitycenter.microsoft.com/api)
==> Configuring scheduled refresh
    Scheduled refresh enabled (2x/day, UTC)
==> Refreshing dataset
    Refresh started
    Refresh completed          # only shown with -Wait
Deployment complete.
Open the report:
  https://app.powerbi.com/groups/<ws>/reports/<report>
```

Open the printed URL — the report renders with your live Defender data.

---

## Option B — Service-principal publish (automation / no interactive login)

The same app can publish to Fabric and query Defender. Ensure a Fabric admin has enabled the tenant
setting **"Service principals can use Fabric APIs"** and that the app is a workspace Admin/Member
(`Bootstrap-Deployment.ps1 -WorkspaceId <id>` adds it).

```powershell
# Verify the config authenticates
pwsh ./deploy/Bootstrap-Deployment.ps1 -Mode Verify -ConfigOut ./deploy/config.json

# Deploy using the config (no az login needed)
pwsh ./deploy/Deploy-Dashboard.ps1 -ConfigPath ./deploy/config.json -WorkspaceId <ws-guid> -Wait
```

> `-SelectWorkspace` is interactive and is rejected under service-principal auth — pass `-WorkspaceId`
> (or `-WorkspaceName` + `-CapacityId` to create one).

---

## Scheduled refresh

By default the deploy enables a native **2×/day** scheduled refresh (06:00 and 18:00, UTC) so the
report re-queries Defender with no local scheduler. The Defender Vulnerability Management assessment
tables (secure-config, software inventory, info-gathering) refresh their per-device snapshot only
about once a day, so twice daily keeps the report current without wasted refreshes. Override it:

```powershell
pwsh ./deploy/Deploy-Dashboard.ps1 -ConfigPath ./deploy/config.json -WorkspaceId <ws-guid> `
     -RefreshTimes "07:00","13:00","19:00" -RefreshTimeZone "GMT Standard Time"

# Or skip enabling a schedule
pwsh ./deploy/Deploy-Dashboard.ps1 -ConfigPath ./deploy/config.json -WorkspaceId <ws-guid> -SkipSchedule
```

---

## Export a snapshot (optional)

```powershell
pwsh ./deploy/Export-Report.ps1 -WorkspaceId <ws> -ReportId <report> -Format PDF
pwsh ./deploy/Export-Report.ps1 -WorkspaceId <ws> -ReportId <report> -Format PPTX -Pages "Non-Compliant Devices"
```
Files land in `./deploy/output/`.

---

## Remove / clean up

Teardown has two independent parts: (1) the **published items** (report + semantic model) in the
workspace, and (2) the **identity/permissions** created by the bootstrap (app registration, Defender
app-role grants, workspace membership, local `config.json`). Run both for a complete removal.

```powershell
# 1. Remove just the report + semantic model
pwsh ./deploy/Remove-Dashboard.ps1 -WorkspaceId <ws-guid>

# 1b. Full teardown of a throwaway/test workspace (requires -Force)
pwsh ./deploy/Remove-Dashboard.ps1 -WorkspaceId <ws-guid> -RemoveWorkspace -Force

# 2. Revoke the app's Defender permissions, remove it from the workspace, and delete local config
pwsh ./deploy/Bootstrap-Deployment.ps1 -Mode Uninstall -AppId <app-guid> -WorkspaceId <ws-guid>

# 2b. Also permanently delete the app registration (add -Yes for non-interactive/CI)
pwsh ./deploy/Bootstrap-Deployment.ps1 -Mode Uninstall -AppId <app-guid> -WorkspaceId <ws-guid> -DeleteApp
```
Missing items are treated as already-clean, so both are safe to re-run.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `PowerShell 5.1 or later is required` | Old Windows PowerShell | Install PowerShell 7 (`winget install Microsoft.PowerShell`). |
| `Azure CLI (az) was not found` | `az` not on PATH | Install Azure CLI, or use service-principal auth (`-ConfigPath`). |
| `This dashboard queries Microsoft Defender live and needs an Entra app registration` | No app creds supplied | Pass `-ConfigPath ./deploy/config.json` (or `-TenantId -ClientId -ClientSecret`). Run Bootstrap first. |
| `Workspace '…' has no … capacity assigned` | Workspace not on a capacity | Assign a Fabric/Premium/PPU capacity, or pass `-CapacityId` to create a new workspace. |
| `Access denied (403)` | Missing workspace role, or SP not enabled for Fabric APIs | Add the identity as workspace Admin/Member; for an SP, enable "Service principals can use Fabric APIs" and include the app. |
| `Service-principal token request failed` | Bad/expired secret or missing consent | Re-run Bootstrap; confirm admin consent; check the secret has not expired. |
| Report shows no data | Refresh not finished, data source not bound as SP, or WindowsDefenderATP perms not consented | Re-run with `-Wait`; confirm consent; open the dataset > Settings > Data source credentials and bind api.securitycenter.microsoft.com as Service principal; click Refresh. |
| `Transient error (429/5xx) … Retry …` | Throttling / transient service error | No action — the script backs off and retries automatically. |
| `Report datasetId … does not match the model` | Binding still settling | Wait a minute and run the deploy again. |

For a fix for each error code the deployment can return, see [FAILURE-CODES.md](FAILURE-CODES.md).
If a run fails it stops with a clear message and no half-finished changes, so it's always safe to
run again once you've sorted the cause.

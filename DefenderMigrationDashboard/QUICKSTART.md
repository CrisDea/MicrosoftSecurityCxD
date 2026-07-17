# Quick start

Deploy the Defender Migration Dashboard to a Power BI / Microsoft Fabric workspace and point it at
your live Microsoft Defender tenant.

## Prerequisites
- PowerShell 7.x (or Windows PowerShell 5.1)
- Azure CLI (`az`) signed in to the target tenant (for the Fabric publish)
- An Entra app with the four **WindowsDefenderATP** application permissions (`Machine.Read.All`,
  `Software.Read.All`, `Vulnerability.Read.All`, `AdvancedQuery.Read.All`, admin-consented) — the
  model uses it to query Defender and to build the trend history. `Bootstrap-Deployment.ps1` sets
  this up.
- A workspace on a capacity that supports semantic models (Fabric / Premium / PPU), and
  Workspace Admin or Member rights on it

## 1. Bootstrap the app (once)
```powershell
pwsh ./deploy/Bootstrap-Deployment.ps1 -Mode CreateNew -DisplayName "defender-migration-dashboard"
```
This grants the four WindowsDefenderATP permissions, requests admin consent, and writes a git-ignored
`deploy/config.json` with the tenant id, client id and secret.

## 2. Sign in and deploy
```powershell
az login
pwsh ./deploy/Deploy-Dashboard.ps1 -ConfigPath ./deploy/config.json -SelectWorkspace
```
The picker lists every workspace you can publish to and offers a "create new workspace" option
(which enumerates your capacities). The app credentials from `config.json` are bound to the dataset
as a Service Principal so it can query Defender, and are used to generate the trend history.

Alternatives:
```powershell
# Existing workspace by id
pwsh ./deploy/Deploy-Dashboard.ps1 -ConfigPath ./deploy/config.json -WorkspaceId <workspace-guid>

# Create a new workspace on a capacity
pwsh ./deploy/Deploy-Dashboard.ps1 -ConfigPath ./deploy/config.json -WorkspaceName "Defender Migration" -CapacityId <capacity-guid>
```

## 3. Open the report
The script prints the report URL when it finishes, for example:
```
https://app.powerbi.com/groups/<workspace-id>/reports/<report-id>
```
The report renders with your live Defender data. The deploy also enables a 2×/day scheduled refresh,
so it stays current with no local scheduler. The 30-day trend history is generated at deploy time and
advances each time you redeploy.

---

## Fully non-interactive deployment (service principal)

The same app can publish to Fabric and query Defender — no `az login` needed:

```powershell
# Verify the config authenticates, then deploy
pwsh ./deploy/Bootstrap-Deployment.ps1 -Mode Verify -ConfigOut ./deploy/config.json
pwsh ./deploy/Deploy-Dashboard.ps1 -ConfigPath ./deploy/config.json -WorkspaceId <ws-guid>
```

A Fabric admin must also enable the tenant setting **"Service principals can use Fabric APIs"** and
include the app (directly or via a security group).

## Export to PDF / PPTX
```powershell
pwsh ./deploy/Export-Report.ps1 -WorkspaceId <ws-guid> -ReportId <report-guid> -Format PDF
```

## More detail
See the main `README.md` → "How the live data path works", and `PERMISSIONS.md` for the exact
permissions each task needs.

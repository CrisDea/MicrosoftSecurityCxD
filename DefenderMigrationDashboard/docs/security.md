# Security, secrets & permissions

[← Back to the README](../README.md)

Where credentials live, what the solution can and cannot read, and the exact permission set required.

---

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



# Troubleshooting & file layout

[← Back to the README](../README.md)

Common failures and what the repository contains. See also [FAILURE-CODES.md](../FAILURE-CODES.md).

---

## Troubleshooting
- **"Workspace not found"** — pass `-SelectWorkspace` to pick from a list, `-WorkspaceId`, or
  `-CapacityId` to create it.
- **"Workspace has no capacity"** — assign a Fabric/Premium/PPU capacity, or pass `-CapacityId`.
- **Report shows no data** — the refresh needs the app credentials bound as a Service Principal and
  the consented WindowsDefenderATP permissions; re-run with `-Wait`, or open the dataset in the
  service and click Refresh. Confirm the data source is bound under Settings > Data source
  credentials (Service principal).
- **Service-principal token fails** — confirm admin consent was granted and the "Service principals
  can use Fabric APIs" tenant setting includes the app.
- **Cleanup / teardown** — two parts: `pwsh ./deploy/Remove-Dashboard.ps1 -WorkspaceId <id>` removes
  the published report + model (add `-RemoveWorkspace -Force` for a throwaway workspace); then
  `pwsh ./deploy/Bootstrap-Deployment.ps1 -Mode Uninstall -AppId <app-guid> -WorkspaceId <id>`
  revokes the app's Defender permissions, removes it from the workspace and deletes local `config.json`
  (add `-DeleteApp` to also delete the app registration). `Remove-Dashboard.ps1` retries transient
  failures, skips items that are already gone, never deletes the workspace when an item failed, and
  exits with a summary — so it is always safe to re-run. `-WorkspaceId` can also come from `-ConfigPath`.
- **Corrupt or missing local files** — the deploy script auto-detects an incomplete project and
  re-downloads it from GitHub before publishing; if you are offline, add `-SkipGitHubRestore` and
  restore the folder manually (`git pull`).

For a fix for each specific error code, see **[FAILURE-CODES.md](FAILURE-CODES.md)**.

## File layout
```
DefenderMigrationDashboard/
├─ README.md
├─ INSTALL.md               # step-by-step install guide
├─ PERMISSIONS.md           # permission reference
├─ pbip-project/            # TMDL model (Defender export-API query + deploy-time trend seed) + PBIR report
├─ deploy/
│  ├─ _Common.ps1           # shared sign-in, REST, workspace + SP-credential + trend-seed helpers
│  ├─ Deploy-Dashboard.ps1
│  ├─ Import-LegacyAvInventory.ps1  # any AV/EDR CSV -> Defender inventory mapping (ingest)
│  ├─ Remove-Dashboard.ps1  # cleanup / teardown (published report + model)
│  ├─ Export-Report.ps1
│  ├─ Bootstrap-Deployment.ps1  # app-registration setup + CheckPermissions + Uninstall
│  ├─ assets/               # DeploymentTrend.kql + DeviceAvPosture.kql (deploy-time seed queries)
│  └─ config.json.template
└─ templates/               # KQL / M / DAX for the live path
```



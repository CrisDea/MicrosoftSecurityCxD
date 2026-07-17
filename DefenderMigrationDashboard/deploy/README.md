# deploy/

Deployment and operations scripts for the Defender Migration Dashboard. Pure PowerShell — no
third-party modules. All scripts authenticate either as a service principal (via `-ConfigPath` or
`-ClientId`/`-ClientSecret`/`-TenantId`) or, if none is supplied, interactively via Azure CLI.

| Script | Purpose |
|--------|---------|
| `_Common.ps1` | Shared helpers used by the other scripts: sign-in and tokens, a single REST wrapper that retries when the service is briefly busy, prerequisite checks, and workspace/item helpers. Not run directly. |
| `Deploy-Dashboard.ps1` | Publishes the semantic model + report to a workspace, binds the report to the model, binds the Defender data source to your app as a Service Principal, generates the 30-day trend history, enables a 2×/day scheduled refresh, and runs a first refresh (poll to completion with `-Wait`). Resolves the target workspace by interactive picker (`-SelectWorkspace`), by id (`-WorkspaceId`), or by name (`-WorkspaceName`, optionally creating it with `-CapacityId`). |
| `Remove-Dashboard.ps1` | Cleanup / teardown: removes the report + semantic model by name, and optionally the workspace (`-RemoveWorkspace -Force`). Missing items are treated as already-clean. |
| `Bootstrap-Deployment.ps1` | Creates **or reuses** an Entra app registration and expands its permissions for service-principal deployment and the live data path. Reads your directory roles and gates each write on its least-privilege role; verifies every step (read-back) and pauses for manual prerequisites. Writes `config.json`. Modes: `CreateNew`, `UseExisting`, `Verify`, `CheckPermissions` (read-only, `-Fix` to grant), `Uninstall` (revoke + remove + optionally `-DeleteApp`). |
| `Export-Report.ps1` | Headless export of the published report to PDF / PPTX via the Power BI ExportTo API (validates the report exists first). |
| `config.json.template` | Copy to `config.json` (git-ignored) and fill in service-principal / live-mode settings. |

See **`../INSTALL.md`** for the full step-by-step guide and **`../PERMISSIONS.md`** for the exact
permissions each task needs.

## If something goes wrong

Each script checks its prerequisites before it starts (PowerShell version, the Azure CLI when you
sign in interactively, and that the project files are present). If the service is briefly busy the
scripts wait and try again, and they wait for longer operations to finish before moving on. When a
run does fail, it stops with a clear message and it's safe to run again once you've fixed the cause.
See [`../FAILURE-CODES.md`](../FAILURE-CODES.md) for a fix for each error you might see.

## Typical flows

Interactive:
```powershell
pwsh ./Bootstrap-Deployment.ps1 -Mode CreateNew -DisplayName "defender-migration-dashboard"
az login
pwsh ./Deploy-Dashboard.ps1 -ConfigPath ./config.json -SelectWorkspace
```

Service principal (reuse an existing app):
```powershell
pwsh ./Bootstrap-Deployment.ps1 -Mode UseExisting -AppId <app-guid> -WorkspaceId <ws-guid>
pwsh ./Deploy-Dashboard.ps1 -ConfigPath ./config.json -WorkspaceId <ws-guid>
```

Clean up (teardown — two parts: published items, then identity/permissions):
```powershell
pwsh ./Remove-Dashboard.ps1 -WorkspaceId <ws-guid>                      # remove report + model
pwsh ./Remove-Dashboard.ps1 -WorkspaceId <ws-guid> -RemoveWorkspace -Force   # full workspace teardown
pwsh ./Bootstrap-Deployment.ps1 -Mode Uninstall -AppId <app-guid> -WorkspaceId <ws-guid>  # revoke perms + remove SP + delete config
pwsh ./Bootstrap-Deployment.ps1 -Mode Uninstall -AppId <app-guid> -WorkspaceId <ws-guid> -DeleteApp -Yes  # also delete the app (CI)
```

## Security
- `config.json` holds a client secret and is **git-ignored**. Never commit it or save it to a
  cloud-synced folder (OneDrive / SharePoint).
- The bootstrap script writes secrets to a local path only.
- The repository ships no customer data and no credentials — DeviceHealth carries no credentials (the
  data source is bound to your app as a Service Principal after publish), and the trend table carries
  only a base64 placeholder the deploy script fills.

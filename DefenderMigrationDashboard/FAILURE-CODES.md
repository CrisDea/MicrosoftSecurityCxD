# Failure Codes & Remediation

A fix for every error the deployment can show you — the HTTP status codes returned by the
Fabric, Power BI and Entra ID services, and the messages the scripts print themselves.

The scripts already handle brief, temporary glitches for you by waiting and trying again, so most of
the entries below are the kind of error that needs a quick action from you. When a run does fail it
stops with a clear message and leaves nothing half-finished, so it's safe to run again once the
cause is fixed.

---

## HTTP status codes

| Code | Meaning | Auto-handled? | Remediation |
|------|---------|---------------|-------------|
| **200 / 201** | OK / Created | — | Success. No action. |
| **202** | Accepted (long-running operation) | Yes — polled to completion | None while it polls. If it throws *"Operation timed out after Ns"*, the service is slow: re-run the script (it's safe to run again), or raise the timeout. If it throws *"Operation Failed/Cancelled"*, read the returned detail — usually a bad definition or a capacity issue. |
| **400** | Bad Request | No | Malformed request. Almost always a bad parameter: check `-WorkspaceId`/`-CapacityId` are real GUIDs and the PBIP project is intact. Re-run `Test-Prereqs` implicitly by re-running the script. If it persists, the `definition.pbir`/model parts may be corrupt — re-generate the PBIP. |
| **401** | Unauthorized | Yes — token refreshed once, then retried | If it still fails: interactive — run `az login` (or `az login --tenant <id>`); service principal — the secret is wrong/expired or consent is missing. Re-run `Bootstrap-Deployment.ps1` and confirm `-Mode Verify` returns OK. |
| **403** | Forbidden | No (clear message printed) | The identity lacks access. Fixes, in order: (1) add the user/SP as **workspace Admin or Member**; (2) for a **service principal**, a Fabric admin must enable **"Service principals can use Fabric APIs"** and include the app (directly or via a group); (3) confirm the workspace is on a capacity you may use. |
| **404** | Not Found | Yes for optional reads (`-AllowNotFound` → `$null`) | If a required item is missing: check the `-WorkspaceId`/`-ReportId` are correct and in the tenant you signed into. For deploy this is normal (item doesn't exist yet → it is created). |
| **408** | Request Timeout | Yes — retried with backoff | No action. If it exhausts retries, check network/proxy connectivity to `*.fabric.microsoft.com` and `*.powerbi.com`. |
| **409** | Conflict | No | Another operation is in flight on the same item (e.g. a concurrent deploy/refresh). Wait for it to finish, then re-run. |
| **412** | Precondition Failed | No | An ETag/version mismatch — the item changed under you. Re-run the deploy (it re-reads the current state, so it's safe to run again). |
| **429** | Too Many Requests (throttled) | Yes — honours `Retry-After` | No action. The script backs off automatically. If sustained, reduce parallel deployments or wait a few minutes. |
| **500** | Internal Server Error | Yes — retried with backoff | Transient service-side error. If it exhausts retries, wait and re-run; check the Fabric service health dashboard. |
| **502 / 503 / 504** | Bad Gateway / Unavailable / Gateway Timeout | Yes — retried with backoff | Transient. The script retries; if it still fails, the service or a gateway is degraded — wait and re-run. Check https://support.fabric.microsoft.com and the M365 service health. |
| **Network / DNS / TLS (code 0)** | No HTTP response | Yes — retried with backoff | Connectivity problem. Check VPN/proxy, firewall egress to `login.microsoftonline.com`, `api.fabric.microsoft.com`, `api.powerbi.com`, and system clock skew (TLS/token failures). |

---

## Entra ID (AAD) token errors — service-principal auth

These surface as *"Service-principal token request failed"* from `Get-Token`. The AAD error code is
in the response body.

| AAD error | Meaning | Remediation |
|-----------|---------|-------------|
| **AADSTS7000215** | Invalid client secret | The secret is wrong or expired. Re-run `Bootstrap-Deployment.ps1` to mint a fresh secret; update `config.json`. |
| **AADSTS700016** | Application not found in tenant | Wrong `clientId` or wrong `tenantId`, or the app/SP was not created. Confirm the app exists in the target tenant (`az ad sp show --id <appId>`). |
| **AADSTS7000222** | Secret is expired | Rotate the secret (`Bootstrap-Deployment.ps1`). |
| **AADSTS650051 / AADSTS500011** | Resource/service principal not found for the scope | The `/.default` scope resource is wrong, or the app has no service principal. Ensure `az ad sp create --id <appId>` ran (Bootstrap does this). |
| **AADSTS900023 / invalid tenant** | Tenant id/domain invalid | Use the tenant **GUID**, not the domain, in `config.json`/`-TenantId`. |
| **consent_required / AADSTS65001** | Admin consent not granted | An admin must grant consent: `az ad app permission admin-consent --id <appId>` (Bootstrap requests this). Then `-Mode Verify`. |

---

## Dataset refresh failures

Raised by `Invoke-RefreshAndWait` (Power BI dataset refresh).

| Condition | Meaning | Remediation |
|-----------|---------|-------------|
| **Refresh could not be started** | POST /refreshes failed | Usually 403 (no dataset write access) or the capacity is paused. Confirm workspace role and that the capacity is running. The report still works after a manual refresh in the service. |
| **Refresh status = Failed** | Refresh ran but failed | Check the data-source credentials are bound as a Service Principal (the deploy does this via `Set-LiveCredentials`) and that the WindowsDefenderATP permissions (`Machine.Read.All`, `Software.Read.All`, `Vulnerability.Read.All`, `AdvancedQuery.Read.All`) are consented and the secret is valid. `serviceExceptionJson` in the output has the detail. |
| **Refresh status = Disabled** | Scheduled refresh disabled | Not a blocker for a one-off deploy — the report has data from the publish. Enable refresh in the dataset settings if you need scheduling. |
| **Did not reach a terminal state within Ns** | Poll timed out | Large model or a busy capacity. It may still complete in the service; re-check the dataset, or re-run with a longer `-TimeoutSec`. |

---

## Script-level (preflight & validation) failures

Raised by the scripts before or after the REST calls, with an actionable message.

| Message | Cause | Remediation |
|---------|-------|-------------|
| `PowerShell 5.1 or later is required` | Old Windows PowerShell | Install PowerShell 7: `winget install Microsoft.PowerShell`. |
| `Azure CLI (az) was not found on PATH` | `az` missing (interactive auth) | Install Azure CLI (https://aka.ms/installazurecli), or use service-principal auth (`-ConfigPath`). |
| `Not signed in to Azure CLI` / `az login failed` | No/invalid `az` session | Run `az login` (add `--tenant <guid>` for a specific tenant). |
| `PBIP project not found` / `Could not find a *.SemanticModel and a *.Report folder` | Wrong `-ProjectPath` or a broken checkout | Run from the repo root, or pass `-ProjectPath` pointing at `pbip-project`. Re-clone if folders are missing. |
| `config.json ... is not valid JSON` | Corrupt/edited config | Re-generate with `Bootstrap-Deployment.ps1`, or copy `config.json.template` and fill it in. |
| `Config ... is missing tenantId/clientId/clientSecret` | Incomplete config | Re-run Bootstrap, or complete the three fields. |
| `Workspace '...' has no ... capacity assigned` | Target workspace not on a capacity | Assign a Fabric/Premium/PPU capacity (Workspace settings → License info), or pass `-CapacityId` to create a new one. |
| `Workspace '...' not found` | Name/id doesn't resolve | Use `-SelectWorkspace` to pick from a list, pass the correct `-WorkspaceId`, or `-CapacityId` to create it. |
| `-SelectWorkspace is interactive and cannot be used with service-principal auth` | Picker under SP auth | Pass `-WorkspaceId` (or `-WorkspaceName` + `-CapacityId`) instead. |
| `Report datasetId ... does not match the model` (warning) | Binding still settling | Wait ~1 minute and run the deploy again. If persistent, delete the report with `Remove-Dashboard.ps1` and re-deploy. |
| `Report ... not found in workspace` (Export) | Wrong ids or no access | Confirm `-WorkspaceId`/`-ReportId`; ensure the identity can open the report. |
| `Export did not succeed (last status: ...)` | ExportTo failed/timed out | Large reports: re-run with a higher `-TimeoutSec`. Confirm the "Export reports" tenant settings are enabled. |
| `Refusing to delete the workspace without -Force` | Safety guard in cleanup | Re-run `Remove-Dashboard.ps1 -RemoveWorkspace -Force` (only for throwaway workspaces). |

---

## First-response checklist

1. Read the printed message — it names the failing call and the fix.
2. Transient (429/5xx/network)? Just re-run; the script already retried.
3. 403? Fix workspace role / Fabric SP tenant setting (see `PERMISSIONS.md`).
4. Auth? `az login` (interactive) or `Bootstrap-Deployment.ps1 -Mode Verify` (SP).
5. Still stuck? Re-run with `-Verbose`, and check the Fabric/Power BI service health.

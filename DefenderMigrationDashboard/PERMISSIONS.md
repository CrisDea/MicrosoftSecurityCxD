# Permissions Reference

This document lists every permission the Defender Migration Dashboard needs, who grants it, and how
to verify it. Permissions are grouped by task so you only grant what you actually use.

The dashboard reads **live from Microsoft Defender for Endpoint** via the export-assessment REST APIs
(`api.securitycenter.microsoft.com`), bound to an Entra app registration (a **Service Principal**).
The 30-day deployment-trend history **and per-device AV posture** (AV mode / exact platform, engine
and signature versions and their fleet-relative currency) are generated at **deploy time** from the
same Defender API (advanced hunting), because that POST cannot run during a cloud scheduled refresh. A working deploy
therefore needs one set of data-source permissions on **WindowsDefenderATP** (Application,
admin-consented): `Machine.Read.All`, `Vulnerability.Read.All`, `Software.Read.All`, and
`AdvancedQuery.Read.All`. Everything else below is about publishing to the workspace and (optionally)
doing so from automation.

---

## 1. Deploy the dashboard (required)

Publishes the semantic model + report to a Fabric / Power BI workspace and refreshes the live
Defender data.

| Permission / role | Scope | Granted by | Why |
|---|---|---|---|
| **Workspace Admin or Member** | Target workspace | Workspace admin | Fabric REST needs write access to create/update the model and report items. |
| **Fabric or Premium/PPU capacity** | The workspace | Capacity admin | Semantic models can only live on a capacity. A pure "My workspace" or a capacity-less workspace is rejected by preflight with a clear message. |
| **Contributor** on an Azure subscription *(only if creating a brand-new workspace on a capacity you own)* | — | — | Not required if you deploy into an existing capacity-backed workspace. |

**Interactive deploy** (default) uses your signed-in Azure CLI user. No app registration needed.

### Verify
```powershell
# You are a workspace Admin/Member and it has a capacity:
az account get-access-token --resource https://api.fabric.microsoft.com --query accessToken -o tsv | Out-Null
# Then run Deploy-Dashboard.ps1 -SelectWorkspace to list only capacity-backed workspaces you can use.
```

---

## 2. Service-principal (non-interactive / CI) deploy — optional

Only needed if you deploy from automation or without an interactive sign-in.

| Permission / setting | Scope | Granted by | Why |
|---|---|---|---|
| **App registration** (client id + secret) | Entra tenant | App admin / Global admin | The identity used for client-credentials auth. Reuse an existing app or create one with `Bootstrap-Deployment.ps1`. |
| Tenant setting **"Service principals can use Fabric APIs"** | Fabric admin portal | Fabric administrator | Without it, all Fabric REST calls return 403 for the SP. Add the app directly or via a security group. |
| App added as **workspace Admin/Member** | Target workspace | Workspace admin | Same reason as interactive: write access to publish items. `Bootstrap-Deployment.ps1 -WorkspaceId <id>` adds it automatically. |

Secrets are written **only** to a local, git-ignored `config.json` — never commit it or place it in a
cloud-synced folder (OneDrive/SharePoint).

### Verify
```powershell
pwsh ./deploy/Bootstrap-Deployment.ps1 -Mode Verify -ConfigOut ./deploy/config.json
# Expect: OK token for https://api.fabric.microsoft.com  and  https://api.securitycenter.microsoft.com,
# plus "OK  Fabric API usable" (proves the tenant SP-API setting is on, and the workspace is reachable
# when a workspaceId is in the config).
```

---

## 3. Live Defender data — required

Populates the model with real Microsoft Defender data and binds it to the dataset as a **Service
Principal** (Power BI mints the app-only token internally on each refresh).

| Permission | API | Type | Granted by | Why |
|---|---|---|---|---|
| **Machine.Read.All** | WindowsDefenderATP (`fc780465-2017-40d4-a0c5-307022471b92`) | Application, **admin-consented** | Global admin / Privileged Role admin | Lists devices and reads the machine/onboarding/sensor state for the DeviceHealth table. |
| **Software.Read.All** | WindowsDefenderATP | Application, admin-consented | Global admin | Reads the software inventory used to detect third-party AV/EDR products still present. |
| **Vulnerability.Read.All** | WindowsDefenderATP | Application, admin-consented | Global admin | Reads the security-configuration / vulnerability assessment used for the compliance checks. |
| **AdvancedQuery.Read.All** | WindowsDefenderATP | Application, admin-consented | Global admin | Runs the advanced-hunting queries at deploy time to build the 30-day DeploymentTrend history seed and the per-device AV posture seed (mode / versions / currency). |

`Bootstrap-Deployment.ps1` adds all four WindowsDefenderATP permissions and requests admin consent
for you (you must still have the rights to consent). No Microsoft Graph data permission is required —
the model queries the Defender API directly.

> **Scale:** the DeviceHealth table uses the paged export/list machine APIs (not a 10,000-row-capped
> hunting query), so it scales to 100k+ device estates. The trend seed is a small day × machine-group
> aggregate.

### Verify
```powershell
# After consent, confirm a Defender API token is obtainable and the app can list machines:
pwsh ./deploy/Bootstrap-Deployment.ps1 -Mode Verify -ConfigOut ./deploy/config.json
```

---

## 4. Export to PDF / PPTX — optional

| Permission | Scope | Why |
|---|---|---|
| **Read** access to the published report | Target workspace | `Export-Report.ps1` calls the Power BI ExportTo API. Any identity that can open the report can export it. |
| Export enabled at tenant level | Fabric admin portal | The "Export reports as PDF/PPTX" tenant settings must be on. |

---

## Who grants what — quick summary

| Role | Grants |
|---|---|
| **Fabric administrator** | "Service principals can use Fabric APIs" setting; export tenant settings; capacity assignment. |
| **Workspace administrator** | Workspace Admin/Member role for you or the SP. |
| **Entra / Global administrator** | App registration creation; admin consent for Graph/Defender application permissions. |
| **You (deployer)** | Being a workspace Admin/Member on a capacity-backed workspace, plus rights to consent (or have consented) the Graph app permission. |

---

## Bootstrap least-privilege model, permission checks and uninstall

`Bootstrap-Deployment.ps1` reads your directory roles on every run and maps them to the exact role
each operation needs, so you only sign in with an elevated account at the moment a write is actually
performed. Read-only operations need no elevation.

| Operation | Mode | Least-privilege role | Gated? |
|---|---|---|---|
| Read env + which Defender perms are granted | `CheckPermissions` (no `-Fix`) | Directory Readers (or Global Reader) | No — read-only, runs unelevated |
| Grant the 4 Defender app permissions | `CheckPermissions -Fix`, `CreateNew`, `UseExisting` | **Privileged Role Administrator** (or Global Admin) — Application Administrator is **not** sufficient | Yes — stops with re-login guidance if the role is absent |
| Add / remove the SP on a Fabric workspace | `-WorkspaceId` on install / `Uninstall` | Admin of **that** workspace (or Fabric Administrator) | Warned (per-workspace roles aren't directory-readable) |
| Delete the app registration + secret | `Uninstall -DeleteApp` | Application Administrator / app Owner | Confirmed per removal |

- PIM-eligible-but-not-activated roles are not detectable; activate the role first, or pass
  `-ForceWrite` to attempt a write without the pre-check (it fails cleanly if the role is missing).
- Each install step is **verified** (read back) before the script continues; the Fabric tenant-setting
  prerequisite pauses with instructions and is re-checked. The run ends with an honest summary and a
  non-zero exit code if any item is still outstanding.

### Check what an app already has (read-only)
```powershell
pwsh ./deploy/Bootstrap-Deployment.ps1 -Mode CheckPermissions -AppId <app-guid>
# Add -Fix to grant anything missing (requires Privileged Role Administrator / Global Admin).
```

### Remove everything the script created
```powershell
# Revoke Defender app roles + remove the SP from the workspace + delete the local config:
pwsh ./deploy/Bootstrap-Deployment.ps1 -Mode Uninstall -AppId <app-guid> -WorkspaceId <ws-guid>
# Add -DeleteApp to also delete the app registration, and -Yes for non-interactive runs.
```

---

## Least-privilege recommendations

- For an **interactive deploy**, sign in with Azure CLI to publish and supply the app credentials
  (from `config.json`) for the data-source bind and trend seed. Use an existing capacity-backed
  workspace.
- Add a dedicated **service principal** for automation, and scope it to a single workspace.
- The four **WindowsDefenderATP** application permissions (Machine / Software / Vulnerability /
  AdvancedQuery `.Read.All`) are the only data-source permissions — grant them once, with admin
  consent. No Microsoft Graph data permission is needed.
- Rotate the client secret regularly and keep `config.json` local-only.

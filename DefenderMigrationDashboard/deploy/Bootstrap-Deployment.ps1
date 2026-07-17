<#
.SYNOPSIS
  Prepare an Entra app registration for non-interactive (service-principal) deployment of the
  Defender Migration Dashboard and, optionally, the live advanced-hunting data path.

.DESCRIPTION
  Sets up the app registration used for non-interactive (service principal) sign-in. Pass -AppId to
  reuse an app you already have, or use -Mode CreateNew to make one. Each write step is verified
  (read back) before the script continues, and any action that needs a tenant admin pauses with
  instructions and is re-checked before moving on.

  PERMISSIONS REQUIRED (least privilege, verified against Microsoft docs):
    Operation                                      | Least-privilege role
    -----------------------------------------------|-------------------------------------------------
    Read env + which perms are granted (read-only) | Directory Readers (or Global Reader)
    Grant the app's Defender permissions           | Privileged Role Administrator (or Global Admin)
    Add the app to a Fabric workspace              | Admin of THAT workspace (or Fabric Administrator)
    Create/delete the app registration + secret    | Application Administrator / app Owner
  Granted app permissions (WindowsDefenderATP, Application, admin-consented):
    Machine.Read.All, Vulnerability.Read.All, Software.Read.All  -> live DeviceHealth export APIs
    AdvancedQuery.Read.All                                       -> deploy-time DeploymentTrend + AV seeds
  No Microsoft Graph *data* permission is required. A tenant admin must also switch on
  "Service principals can use Fabric APIs" (the script instructs and verifies this).

  WHAT THE SCRIPT DOES, STEP BY STEP (CreateNew / UseExisting):
    0. Preflight: check az login, print tenant/user, read your directory roles and map them to the
       least-privilege table above (read-only - no elevation needed).
    1. Resolve or create the app registration; ensure its service principal exists (verified).
    2. Grant the 4 WindowsDefenderATP application permissions, then re-read appRoleAssignments to
       confirm every one is granted. Gated: stops if you lack Privileged Role Administrator.
    3. (If -WorkspaceId) add the SP to the workspace as Admin, then GET the members to confirm.
    4. Create a client secret and write the git-ignored config.json (verified on disk).
    5. Acquire an app-only token and call a Fabric API to prove sign-in works AND the tenant setting
       is on; if not, pause with admin instructions and re-check before finishing.
  -Mode Uninstall reverses this (remove from workspace -> revoke app roles -> optionally delete the
  app -> delete local config.json), confirming each removal. Add -Yes for non-interactive runs.

  The credentials are saved to a git-ignored config.json that Deploy-Dashboard.ps1 reads via
  -ConfigPath.

.NOTES
  You need to be signed in to the target tenant with the Azure CLI (az login). Least-privilege model:
    * Read-only checks (-Mode CheckPermissions without -Fix, and the access report printed on every run)
      need only a directory-read role such as Directory Readers or Global Reader - no elevation.
    * Granting the OAuth app's Defender permissions (-Fix, CreateNew, UseExisting) requires the
      Privileged Role Administrator role (least privilege) or Global Administrator. The script confirms
      the signed-in account holds it and STOPS with re-login guidance if not, so you only sign in with
      an elevated account at the moment a grant is actually performed.
    * Adding the SP to a Fabric workspace (-WorkspaceId) needs you to be an Admin of that workspace
      (or the Fabric Administrator directory role).
  PIM-eligible-but-not-activated roles are not detectable; activate the role first, or pass -ForceWrite
  to attempt a write without the pre-check.
  The client secret is written to -ConfigOut (default ./config.json). Keep it local - don't commit
  it or put it in a synced folder such as OneDrive or SharePoint.

.EXAMPLE
  # Reuse an existing app registration and expand its permissions
  pwsh ./Bootstrap-Deployment.ps1 -Mode UseExisting -AppId <app-guid> -WorkspaceId <ws-guid>

.EXAMPLE
  # Create a new app registration
  pwsh ./Bootstrap-Deployment.ps1 -Mode CreateNew -DisplayName "defender-migration-dashboard"

.EXAMPLE
  # Verify an existing config.json can acquire tokens
  pwsh ./Bootstrap-Deployment.ps1 -Mode Verify -ConfigOut ./config.json

.EXAMPLE
  # Verify which Defender application permissions a given app has actually been granted (read-only;
  # runs fine with only Directory Readers / Global Reader - no elevation needed)
  pwsh ./Bootstrap-Deployment.ps1 -Mode CheckPermissions -AppId <app-guid>

.EXAMPLE
  # Verify AND grant any missing Defender permissions on a given app
  # (requires Privileged Role Administrator or Global Administrator - the script gates this step)
  pwsh ./Bootstrap-Deployment.ps1 -Mode CheckPermissions -AppId <app-guid> -Fix

.EXAMPLE
  # Remove access created by this script (revoke app roles + remove from workspace + delete config)
  pwsh ./Bootstrap-Deployment.ps1 -Mode Uninstall -AppId <app-guid> -WorkspaceId <ws-guid>

.EXAMPLE
  # Full removal including permanently deleting the app registration, no prompts (CI)
  pwsh ./Bootstrap-Deployment.ps1 -Mode Uninstall -AppId <app-guid> -WorkspaceId <ws-guid> -DeleteApp -Yes
#>
[CmdletBinding()]
param(
    [ValidateSet("CreateNew","UseExisting","Verify","CheckPermissions","Uninstall")]
    [string]$Mode = "CreateNew",
    [string]$AppId,                                   # required for UseExisting / CheckPermissions / Uninstall
    [string]$DisplayName = "defender-migration-dashboard",
    [string]$WorkspaceId,                             # optional: add the SP to this workspace as Admin
    [string]$ConfigOut = "$PSScriptRoot/config.json",
    [int]$SecretYears = 1,
    [switch]$NoSecret,                                # UseExisting: skip creating a new secret
    [switch]$Fix,                                     # CheckPermissions: grant any missing permissions
    [switch]$ForceWrite,                              # proceed with a write even if the elevated role can't be confirmed
    [switch]$DeleteApp,                               # Uninstall: also delete the app registration + SP
    [switch]$Yes                                      # auto-confirm prompts (non-interactive / CI)
)

$ErrorActionPreference = "Stop"
$MdatpAppId = "fc780465-2017-40d4-a0c5-307022471b92"   # WindowsDefenderATP (Defender API)
# The application permissions the solution requires on WindowsDefenderATP. DeviceHealth reads the
# export-assessment APIs live (Machine/Software/Vulnerability); AdvancedQuery drives the deploy-time
# DeploymentTrend and AV-posture seeds.
$RequiredDefenderRoles = @('Machine.Read.All','Vulnerability.Read.All','Software.Read.All','AdvancedQuery.Read.All')

# Well-known Entra directory-role template ids used for least-privilege gating. Read-only checks need
# only a directory-read role; granting application permissions (app-role assignments to a service
# principal) requires Privileged Role Administrator (least privilege) or Global Administrator; adding
# the SP to a Fabric workspace needs a workspace Admin or the Fabric Administrator directory role.
$RoleTpl = @{
    GlobalAdministrator        = '62e90394-69f5-4237-9190-012177145e10'
    PrivilegedRoleAdmin        = 'e8611ab8-c189-46e8-94e1-60213ab1f814'
    ApplicationAdministrator   = '9b895d92-2cd3-44c7-9d02-a6ac2d5ea5c3'
    CloudApplicationAdmin      = '158c047a-c907-4556-b7ef-446551a6b5f7'
    DirectoryReaders           = '88d8e3e3-8f55-4a1e-953a-9b9898b8876b'
    GlobalReader               = 'f2ef992c-3afb-46b9-b7cf-a126ee74c451'
    FabricAdministrator        = 'a9ea8996-122f-4c74-9520-8edcd192826c'
}

function Say($m, $c = "Gray") { Write-Host $m -ForegroundColor $c }

# Run an az command, capture output, and throw a clear error on non-zero exit. az writes warnings
# (e.g. the cp1252 encoding notice) to stderr; under 2>&1 those arrive as ErrorRecord objects, so we
# keep only real stdout for the return value (otherwise a stray WARNING line corrupts JSON parsing).
function Invoke-Az {
    param([Parameter(Mandatory)][string[]]$AzArgs, [switch]$AllowFail)
    $raw = & az @AzArgs 2>&1
    $errLines = @($raw | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
    $out      = @($raw | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
    if ($LASTEXITCODE -ne 0 -and -not $AllowFail) {
        throw "az $($AzArgs -join ' ') failed: $(($out + $errLines) -join "`n")"
    }
    return $out
}

# Poll a client-credentials token until it succeeds (consent/replication can lag by minutes).
function Wait-ForToken {
    param([string]$TenantId, [string]$ClientId, [string]$ClientSecret, [string]$Resource, [int]$TimeoutSec = 180)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $attempt = 0
    while ((Get-Date) -lt $deadline) {
        $attempt++
        $body = @{ client_id = $ClientId; client_secret = $ClientSecret; grant_type = "client_credentials"; scope = "$Resource/.default" }
        try {
            $r = Invoke-RestMethod -Method POST -ContentType "application/x-www-form-urlencoded" `
                    -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body $body
            if ($r.access_token) { return $true }
        } catch { Write-Verbose "token attempt $attempt not ready: $($_.Exception.Message)" }
        Start-Sleep -Seconds ([Math]::Min(20, 5 * $attempt))
    }
    return $false
}

# --------------------------------------------------------------------- Graph helpers (permissions)
# GET a Graph URL via the az CLI login, following @odata.nextLink paging. Returns the combined
# 'value' array (or the raw object for single-item responses).
function Get-GraphAll {
    param([Parameter(Mandatory)][string]$Uri)
    $items = @()
    $next = $Uri
    while ($next) {
        $raw = Invoke-Az -AzArgs @('rest','--method','GET','--uri',$next,'--headers','ConsistencyLevel=eventual')
        $obj = ($raw -join "`n") | ConvertFrom-Json
        if ($null -ne $obj.value) { $items += $obj.value; $next = $obj.'@odata.nextLink' }
        else { return $obj }
    }
    return $items
}

# Resolve the WindowsDefenderATP service principal and its Application app-roles (value <-> id maps).
function Resolve-MdatpRoles {
    $sp = az ad sp show --id $MdatpAppId | ConvertFrom-Json
    if (-not $sp) { throw "WindowsDefenderATP service principal ($MdatpAppId) not found in this tenant." }
    $valueToId = @{}; $idToValue = @{}
    foreach ($r in $sp.appRoles) {
        if ($r.allowedMemberTypes -contains 'Application') { $valueToId[$r.value] = $r.id; $idToValue[$r.id] = $r.value }
    }
    return [pscustomobject]@{ SpObjectId = $sp.id; ValueToId = $valueToId; IdToValue = $idToValue }
}

# The set of Defender application permissions ACTUALLY granted (admin-consented) to an app's SP,
# read from its appRoleAssignments (the source of truth - not the app's *requested* permission list).
function Get-GrantedDefenderRoles {
    param([Parameter(Mandatory)][string]$SpObjectId, [Parameter(Mandatory)]$Mdatp)
    $assignments = Get-GraphAll -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$SpObjectId/appRoleAssignments"
    $granted = @()
    foreach ($a in @($assignments)) {
        if ($a.resourceId -eq $Mdatp.SpObjectId -and $Mdatp.IdToValue.ContainsKey($a.appRoleId)) {
            $granted += $Mdatp.IdToValue[$a.appRoleId]
        }
    }
    return ($granted | Sort-Object -Unique)
}

# Print a required-vs-granted status table; returns the list of missing role values.
function Show-DefenderPermissionStatus {
    param([Parameter(Mandatory)][string[]]$Granted)
    $missing = @()
    Say ""
    Say "  Permission (WindowsDefenderATP, Application)   Status" "Cyan"
    Say "  ---------------------------------------------  ----------------" "Cyan"
    foreach ($role in $RequiredDefenderRoles) {
        if ($Granted -contains $role) { Say ("  {0,-45}  GRANTED" -f $role) "Green" }
        else { $missing += $role; Say ("  {0,-45}  MISSING" -f $role) "Red" }
    }
    Say ""
    return $missing
}

# Grant a set of Defender application permissions to an app's SP by creating appRoleAssignments
# directly (creating the assignment IS the admin consent for an application permission). Idempotent:
# an existing assignment (HTTP 409) is treated as success. Also mirrors the grant into the app's
# requested-permission manifest so it shows up in the portal. Requires the signed-in user to be a
# Global Administrator or Privileged Role Administrator.
function Grant-DefenderRoles {
    param([Parameter(Mandatory)][string]$AppId, [Parameter(Mandatory)][string]$SpObjectId,
          [Parameter(Mandatory)]$Mdatp, [Parameter(Mandatory)][string[]]$Roles)
    foreach ($role in $Roles) {
        $roleId = $Mdatp.ValueToId[$role]
        if (-not $roleId) { Say "  WARNING: unknown Defender role '$role' - skipping." "Yellow"; continue }
        # keep the app manifest in sync (portal visibility) - harmless if already present
        az ad app permission add --id $AppId --api $MdatpAppId --api-permissions "$roleId=Role" 2>$null | Out-Null
        $body = @{ principalId = $SpObjectId; resourceId = $Mdatp.SpObjectId; appRoleId = $roleId } | ConvertTo-Json -Compress
        $tmp = New-TemporaryFile
        Set-Content -LiteralPath $tmp -Value $body -Encoding UTF8
        $out = Invoke-Az -AllowFail -AzArgs @('rest','--method','POST',
                    '--uri',"https://graph.microsoft.com/v1.0/servicePrincipals/$SpObjectId/appRoleAssignments",
                    '--headers','Content-Type=application/json','--body',"@$tmp")
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
        if ($LASTEXITCODE -eq 0) { Say "  Granted $role" "Green" }
        elseif ("$out" -match 'Permission being assigned already exists|409') { Say "  $role already granted" "Green" }
        else { Say "  FAILED to grant $role : $out" "Red" }
    }
}

# Verify (and with -DoFix, repair) the Defender application permissions for a resolved app + SP.
# Returns $true when every required permission is granted.
function Confirm-DefenderPermissions {
    param([Parameter(Mandatory)][string]$AppId, [Parameter(Mandatory)][string]$SpObjectId, [switch]$DoFix)
    $mdatp = Resolve-MdatpRoles
    $granted = @(Get-GrantedDefenderRoles -SpObjectId $SpObjectId -Mdatp $mdatp)
    $missing = @(Show-DefenderPermissionStatus -Granted $granted)
    if ($missing.Count -eq 0) { Say "All required Defender permissions are granted." "Green"; return $true }
    if (-not $DoFix) {
        Say ("$($missing.Count) permission(s) missing. Re-run with -Fix to grant them.") "Yellow"
        return $false
    }
    Say "Granting missing permission(s)..." "Cyan"
    Grant-DefenderRoles -AppId $AppId -SpObjectId $SpObjectId -Mdatp $mdatp -Roles $missing
    # consent/replication can lag; re-check for up to ~60s
    for ($i = 0; $i -lt 6; $i++) {
        Start-Sleep -Seconds 10
        $granted = @(Get-GrantedDefenderRoles -SpObjectId $SpObjectId -Mdatp $mdatp)
        if (-not (@($RequiredDefenderRoles | Where-Object { $granted -notcontains $_ }))) { break }
    }
    $missing = @(Show-DefenderPermissionStatus -Granted $granted)
    if ($missing.Count -eq 0) { Say "All required Defender permissions are now granted." "Green"; return $true }
    Say "Some permissions are still not visible (directory replication can take a few minutes). Re-run -Mode CheckPermissions to confirm." "Yellow"
    return $false
}

# ------------------------------------------------------------- least-privilege / access reporting
# Read the signed-in user's ACTIVE directory roles (delegated /me call - a normal member can read
# their own membership, so this needs no elevation). Returns a capability object, or $null if the
# roles couldn't be read (e.g. restricted directory, or PIM-eligible-but-not-activated roles which
# do NOT appear here). Fails soft so read-only flows are never blocked.
function Get-SignedInRoles {
    try {
        # /me/memberOf returns groups + directory roles; directory-role membership is not nested, so a
        # direct memberOf is sufficient and avoids the advanced-query params the type-cast form needs.
        $all   = Get-GraphAll -Uri "https://graph.microsoft.com/v1.0/me/memberOf"
        $roles = @(@($all) | Where-Object { $_.'@odata.type' -eq '#microsoft.graph.directoryRole' })
        $ids   = @($roles | ForEach-Object { $_.roleTemplateId })
        $names = @($roles | ForEach-Object { $_.displayName } | Where-Object { $_ } | Sort-Object -Unique)
        $has   = { param($tpl) $ids -contains $tpl }
        $isGA  = & $has $RoleTpl.GlobalAdministrator
        return [pscustomobject]@{
            RoleNames        = $names
            IsGlobalAdmin    = $isGA
            CanGrantAppPerms = ($isGA -or (& $has $RoleTpl.PrivilegedRoleAdmin))
            IsFabricAdmin    = ($isGA -or (& $has $RoleTpl.FabricAdministrator))
            CanReadDirectory = ($isGA -or (& $has $RoleTpl.PrivilegedRoleAdmin) -or (& $has $RoleTpl.GlobalReader) `
                                     -or (& $has $RoleTpl.DirectoryReaders) -or (& $has $RoleTpl.ApplicationAdministrator) `
                                     -or (& $has $RoleTpl.CloudApplicationAdmin))
        }
    } catch { Write-Verbose "Could not read directory roles: $($_.Exception.Message)"; return $null }
}

# Print the environment / access context and map the signed-in account's roles to each operation's
# verified least-privilege requirement. Read-only; safe to call in every mode.
function Show-AccessContext {
    param($Caps)
    Say ""
    Say "== Access (least-privilege) ==" "Cyan"
    if ($null -eq $Caps) {
        Say "  Could not read your directory roles (restricted directory, or PIM-eligible roles are not" "Yellow"
        Say "  activated - eligible roles do not show until activated). Read-only checks still work;" "Yellow"
        Say "  a write will be attempted and will fail cleanly if you lack the role. Use -ForceWrite to skip this notice." "Yellow"
        return
    }
    if ($Caps.RoleNames.Count -gt 0) { Say ("  Signed-in roles : {0}" -f ($Caps.RoleNames -join ', ')) }
    else { Say "  Signed-in roles : (none active - standard member)" }
    $fmt = { param($ok,$okMsg,$noMsg) if ($ok) { Say ("    {0}" -f $okMsg) "Green" } else { Say ("    {0}" -f $noMsg) "Yellow" } }
    Say "  Operation -> least-privilege role:"
    & $fmt $Caps.CanReadDirectory `
        "Read env + app permissions (CheckPermissions)  : OK  (Directory Readers / Global Reader)" `
        "Read env + app permissions (CheckPermissions)  : may be limited - least priv is Directory Readers"
    & $fmt $Caps.CanGrantAppPerms `
        "Grant Defender app permissions (-Fix)           : OK  (Privileged Role Administrator)" `
        "Grant Defender app permissions (-Fix)           : BLOCKED - sign in with Privileged Role Administrator (least priv) or Global Administrator"
    & $fmt $Caps.IsFabricAdmin `
        "Add SP to Fabric workspace (-WorkspaceId)       : OK  (Fabric Administrator)" `
        "Add SP to Fabric workspace (-WorkspaceId)       : needs workspace Admin (per-workspace) or Fabric Administrator - cannot verify at directory level"
    Say ""
}

# Gate a write operation behind its verified least-privilege role. If the account is confirmed to
# lack the role, STOP with precise re-login guidance rather than blindly failing later. If the role
# can't be confirmed (roles unreadable / PIM-eligible), proceed unless the caller demands certainty.
function Assert-WriteCapability {
    param([ValidateSet('GrantAppPermissions','WorkspaceAdmin')][string]$Capability, $Caps, [string]$TenantId, [switch]$AllowUnconfirmed)
    switch ($Capability) {
        'GrantAppPermissions' {
            if ($null -ne $Caps -and -not $Caps.CanGrantAppPerms) {
                throw ("This step GRANTS application permissions to the OAuth app, which requires the " +
                       "'Privileged Role Administrator' role (least privilege) or 'Global Administrator'. " +
                       "Your account does not hold it. Sign in with an eligible account only for this step:`n" +
                       "  az login --tenant $TenantId --allow-no-subscriptions`n" +
                       "then re-run. Read-only checks (CheckPermissions without -Fix) need no elevation. " +
                       "If you hold the role via PIM, activate it first, or pass -ForceWrite.")
            }
            if ($null -eq $Caps -and -not $AllowUnconfirmed) {
                throw ("Could not confirm you hold 'Privileged Role Administrator' / 'Global Administrator' " +
                       "(needed to grant app permissions). Activate the role via PIM, or re-run with -ForceWrite " +
                       "to attempt anyway (the grant will fail cleanly if you lack the role).")
            }
        }
        'WorkspaceAdmin' {
            # Workspace Admin is a per-workspace Fabric role that can't be read from directory roles;
            # only warn (never hard-block) - the API call surfaces a clear error if unauthorized.
            if ($null -ne $Caps -and -not $Caps.IsFabricAdmin) {
                Say "  Note: adding the SP to the workspace needs you to be an Admin of THAT workspace (or Fabric Administrator)." "Yellow"
            }
        }
    }
}

# ------------------------------------------------------------- step / confirmation / verification
$script:StepNo = 0; $script:StepTotal = 0
function Set-StepTotal([int]$n) { $script:StepTotal = $n; $script:StepNo = 0 }
function Step([string]$msg) {
    $script:StepNo++
    Say ""
    Say ("== Step {0}/{1}: {2} ==" -f $script:StepNo, $script:StepTotal, $msg) "Cyan"
}

# Ask a yes/no question. Auto-yes when -Yes was passed; assume NO on a non-interactive host.
function Confirm-Action([string]$question) {
    if ($Yes) { Say "  (auto-confirmed via -Yes) $question" "Yellow"; return $true }
    if (-not [Environment]::UserInteractive) {
        Say "  Non-interactive host; skipping (pass -Yes to proceed): $question" "Yellow"; return $false
    }
    return ((Read-Host ("  {0} [y/N]" -f $question)) -match '^(y|yes)$')
}

# Print a REQUIRED manual action, then re-verify with $Verify (returns $true when satisfied). Loops
# until satisfied or the operator chooses to continue. Never proceeds silently past a failed check.
function Wait-ForManualStep {
    param([Parameter(Mandatory)][string]$Instruction, [Parameter(Mandatory)][scriptblock]$Verify, [int]$MaxTries = 20)
    Say "  ACTION REQUIRED (manual - a tenant admin may be needed):" "Magenta"
    foreach ($line in ($Instruction -split "`n")) { Say "    $line" "Magenta" }
    for ($i = 0; $i -lt $MaxTries; $i++) {
        if (& $Verify) { Say "  Verified: prerequisite satisfied." "Green"; return $true }
        if ($Yes) { Say "  -Yes set but prerequisite not yet satisfied; continue and re-run -Mode Verify later." "Yellow"; return $false }
        if (-not [Environment]::UserInteractive) { Say "  Non-interactive; complete this later then re-run -Mode Verify." "Yellow"; return $false }
        if (-not (Confirm-Action "Done - re-check now? (n = skip and continue)")) { Say "  Skipped - complete later, then re-run -Mode Verify." "Yellow"; return $false }
    }
    Say "  Still not satisfied after $MaxTries checks - continue later." "Yellow"; return $false
}

# --------------------------------------------------------------------- Fabric / workspace helpers
function Get-PbiToken { az account get-access-token --resource "https://analysis.windows.net/powerbi/api" --query accessToken -o tsv }

# Add the app's SP to a Fabric/Power BI workspace as Admin, then VERIFY the membership landed with
# the requested access right. NOTE: the Power BI API requires the service-principal OBJECT ID
# (principalType App), NOT the app/client id. Returns $true only on a confirmed Admin membership.
function Add-SpToWorkspace {
    param([Parameter(Mandatory)][string]$WorkspaceId, [Parameter(Mandatory)][string]$PrincipalId, [Parameter(Mandatory)][string]$Token)
    $body = @{ identifier = $PrincipalId; principalType = "App"; groupUserAccessRight = "Admin" } | ConvertTo-Json
    try {
        Invoke-RestMethod -Method POST -Uri "https://api.powerbi.com/v1.0/myorg/groups/$WorkspaceId/users" `
            -Headers @{ Authorization = "Bearer $Token" } -ContentType "application/json" -Body $body | Out-Null
    } catch {
        if ("$($_.Exception.Message)" -notmatch 'already') { Say "  add-user returned: $($_.Exception.Message)" "Yellow" }
    }
    try {
        $users = Invoke-RestMethod -Method GET -Uri "https://api.powerbi.com/v1.0/myorg/groups/$WorkspaceId/users" -Headers @{ Authorization = "Bearer $Token" }
        return (@($users.value | Where-Object { $_.identifier -eq $PrincipalId -and $_.groupUserAccessRight -eq 'Admin' }).Count -gt 0)
    } catch { Say "  Could not read workspace members to verify: $($_.Exception.Message)" "Yellow"; return $false }
}

# Remove the app's SP from a workspace, then VERIFY it is gone. Uses the SP OBJECT ID. Returns
# $false if the removal cannot be confirmed (e.g. the read-back itself fails).
function Remove-SpFromWorkspace {
    param([Parameter(Mandatory)][string]$WorkspaceId, [Parameter(Mandatory)][string]$PrincipalId, [Parameter(Mandatory)][string]$Token)
    try {
        Invoke-RestMethod -Method DELETE -Uri "https://api.powerbi.com/v1.0/myorg/groups/$WorkspaceId/users/$PrincipalId" -Headers @{ Authorization = "Bearer $Token" } | Out-Null
    } catch {
        if ("$($_.Exception.Message)" -notmatch '404|[Nn]ot [Ff]ound') { Say "  DELETE returned: $($_.Exception.Message)" "Yellow" }
    }
    try {
        $users = Invoke-RestMethod -Method GET -Uri "https://api.powerbi.com/v1.0/myorg/groups/$WorkspaceId/users" -Headers @{ Authorization = "Bearer $Token" }
        return (@($users.value | Where-Object { $_.identifier -eq $PrincipalId }).Count -eq 0)
    } catch { Say "  Could not read workspace members to verify removal: $($_.Exception.Message)" "Yellow"; return $false }
}

# Confirm the SP can actually use the Fabric APIs - proves BOTH the 'Service principals can use Fabric
# APIs' tenant setting is on AND (if given) the SP is in the workspace. Returns $true on HTTP 200.
function Test-FabricSpAccess {
    param([Parameter(Mandatory)][string]$TenantId, [Parameter(Mandatory)][string]$ClientId,
          [Parameter(Mandatory)][string]$ClientSecret, [string]$WorkspaceId)
    $body = @{ client_id = $ClientId; client_secret = $ClientSecret; grant_type = "client_credentials"; scope = "https://api.fabric.microsoft.com/.default" }
    try { $tok = (Invoke-RestMethod -Method POST -ContentType "application/x-www-form-urlencoded" -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body $body).access_token }
    catch { return $false }
    $uri = if ($WorkspaceId) { "https://api.fabric.microsoft.com/v1/workspaces/$WorkspaceId" } else { "https://api.fabric.microsoft.com/v1/workspaces" }
    try { Invoke-RestMethod -Method GET -Uri $uri -Headers @{ Authorization = "Bearer $tok" } | Out-Null; return $true }
    catch { return $false }
}

# Revoke the Defender app-role assignments from an app's SP, then VERIFY none remain.
function Remove-DefenderRoles {
    param([Parameter(Mandatory)][string]$SpObjectId, [Parameter(Mandatory)]$Mdatp)
    $assignments = Get-GraphAll -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$SpObjectId/appRoleAssignments"
    foreach ($a in @($assignments)) {
        if ($a.resourceId -eq $Mdatp.SpObjectId -and $Mdatp.IdToValue.ContainsKey($a.appRoleId)) {
            $val = $Mdatp.IdToValue[$a.appRoleId]
            $out = Invoke-Az -AllowFail -AzArgs @('rest','--method','DELETE','--uri',"https://graph.microsoft.com/v1.0/servicePrincipals/$SpObjectId/appRoleAssignments/$($a.id)")
            if ($LASTEXITCODE -eq 0) { Say "  Revoked $val" "Green" } else { Say "  FAILED to revoke $val : $out" "Red" }
        }
    }
    return ((@(Get-GrantedDefenderRoles -SpObjectId $SpObjectId -Mdatp $Mdatp)).Count -eq 0)
}

# --------------------------------------------------------------------- Verify mode
if ($Mode -eq "Verify") {
    if (-not (Test-Path -LiteralPath $ConfigOut)) { throw "Config not found: $ConfigOut" }
    $cfg = Get-Content -LiteralPath $ConfigOut -Raw | ConvertFrom-Json
    if (-not $cfg.clientId -or -not $cfg.clientSecret -or -not $cfg.tenantId) {
        throw "Config at $ConfigOut is missing tenantId/clientId/clientSecret."
    }
    $allOk = $true
    foreach ($res in @("https://api.fabric.microsoft.com","https://api.securitycenter.microsoft.com")) {
        $body = @{ client_id = $cfg.clientId; client_secret = $cfg.clientSecret
                   grant_type = "client_credentials"; scope = "$res/.default" }
        try {
            $r = Invoke-RestMethod -Method POST -ContentType "application/x-www-form-urlencoded" `
                    -Uri "https://login.microsoftonline.com/$($cfg.tenantId)/oauth2/v2.0/token" -Body $body
            Say ("  OK  token for {0} (len {1})" -f $res, $r.access_token.Length) "Green"
        } catch { $allOk = $false; Say ("  FAIL token for {0}: {1}" -f $res, $_.Exception.Message) "Red" }
    }
    if (-not $allOk) { exit 1 }

    # Beyond raw tokens: confirm the SP can actually USE Fabric (validates the tenant SP-API setting,
    # and workspace membership when the config carries a workspaceId).
    $wsId = if ($WorkspaceId) { $WorkspaceId } else { $cfg.workspaceId }
    if (Test-FabricSpAccess -TenantId $cfg.tenantId -ClientId $cfg.clientId -ClientSecret $cfg.clientSecret -WorkspaceId $wsId) {
        Say ("  OK  Fabric API usable{0}." -f $(if ($wsId) { " and workspace $wsId reachable" } else { "" })) "Green"
    } else {
        Say "  WARN Fabric API not usable yet - enable 'Service principals can use Fabric APIs' (and add the app to the workspace)." "Yellow"
    }
    Say ""
    Say "Token + Fabric check. To verify the app's granted Defender permissions, run:" "Cyan"
    Say "  pwsh ./Bootstrap-Deployment.ps1 -Mode CheckPermissions -ConfigOut `"$ConfigOut`"" "Cyan"
    return
}

# --------------------------------------------------------------------- preflight
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI (az) not found on PATH. Install from https://aka.ms/installazurecli and run 'az login' in the TARGET tenant."
}
az account show 1>$null 2>$null
if ($LASTEXITCODE -ne 0) {
    throw "Not signed in to Azure CLI. Run 'az login' (in the tenant where the app should live) and re-run this script."
}

Say "== Context ==" "Cyan"
$ctx = az account show | ConvertFrom-Json
Say ("Tenant : {0} ({1})" -f $ctx.tenantId, $ctx.tenantDefaultDomain)
Say ("User   : {0}" -f $ctx.user.name)

# Read-only least-privilege reporting (needs no elevation). $Caps drives the write-gates below.
$Caps = Get-SignedInRoles
Show-AccessContext -Caps $Caps

# --------------------------------------------------------------------- resolve app
if ($Mode -in @("UseExisting","CheckPermissions","Uninstall")) {
    if (-not $AppId -and $Mode -in @("CheckPermissions","Uninstall") -and (Test-Path -LiteralPath $ConfigOut)) {
        $cfgFile = Get-Content -LiteralPath $ConfigOut -Raw | ConvertFrom-Json
        $AppId = $cfgFile.clientId
        if (-not $WorkspaceId -and $cfgFile.workspaceId) { $WorkspaceId = $cfgFile.workspaceId }
        if ($AppId) { Say "Using clientId from $ConfigOut : $AppId" "Yellow" }
    }
    if (-not $AppId) { throw "-Mode $Mode requires -AppId <app-guid> (or a config.json with a clientId)." }
    $app = az ad app show --id $AppId 2>$null | ConvertFrom-Json
    if (-not $app) {
        if ($Mode -eq "Uninstall") { Say "App $AppId not found (already deleted?). Will still clean up local config." "Yellow" }
        else { throw "App registration $AppId not found in this tenant." }
    } else { Say "Target app: $($app.appId) ($($app.displayName))" "Yellow" }
} else {
    $existing = az ad app list --display-name $DisplayName | ConvertFrom-Json
    if ($existing -and $existing.Count -gt 0) {
        Say "An app named '$DisplayName' already exists: $($existing[0].appId)" "Yellow"
        if (Confirm-Action "Reuse this existing app? (n = create a brand-new registration)") {
            $app = $existing[0]; Say "Reusing existing app: $($app.appId)" "Yellow"
        } else {
            $app = az ad app create --display-name $DisplayName --sign-in-audience AzureADMyOrg | ConvertFrom-Json
            Say "Created new app: $($app.appId)" "Green"
        }
    } else {
        $app = az ad app create --display-name $DisplayName --sign-in-audience AzureADMyOrg | ConvertFrom-Json
        Say "Created app: $($app.appId)" "Green"
    }
}
$appId = if ($app) { $app.appId } else { $AppId }

# --------------------------------------------------------------------- service principal
# The SP (enterprise application) is the object that actually holds granted app permissions
# (appRoleAssignments), so it must exist before we can verify or grant anything.
$spId = $null
$sp = if ($app) { az ad sp list --filter "appId eq '$appId'" | ConvertFrom-Json } else { @() }
if (-not $sp -or $sp.Count -eq 0) {
    if ($Mode -eq "CheckPermissions") { throw "No service principal exists for app $appId. Run -Mode UseExisting -AppId $appId first." }
    elseif ($Mode -eq "Uninstall") { Say "No service principal for $appId - nothing to revoke there." "Yellow" }
    else { $sp = @(az ad sp create --id $appId | ConvertFrom-Json); Say "Created service principal" "Green"; Start-Sleep -Seconds 5; $spId = $sp[0].id }
} else { $spId = $sp[0].id }

# --------------------------------------------------------------------- CheckPermissions: verify (+ -Fix) then exit
if ($Mode -eq "CheckPermissions") {
    Say "== Verifying WindowsDefenderATP application permissions for $appId ==" "Cyan"
    # Read-only verify needs no elevation; only gate the write when -Fix is requested.
    if ($Fix) { Assert-WriteCapability -Capability GrantAppPermissions -Caps $Caps -TenantId $ctx.tenantId -AllowUnconfirmed:$ForceWrite }
    $ok = Confirm-DefenderPermissions -AppId $appId -SpObjectId $spId -DoFix:$Fix
    if (-not $ok) { exit 1 }
    return
}

# --------------------------------------------------------------------- Uninstall: remove access then exit
if ($Mode -eq "Uninstall") {
    Say "== Uninstall / removal ==" "Cyan"
    Say "This REMOVES the dashboard's service-principal access. It does NOT delete the published" "Yellow"
    Say "dataset/report - remove those from the workspace separately if no longer needed." "Yellow"
    Set-StepTotal (([int][bool]$WorkspaceId) + ([int][bool]$spId) + ([int]($DeleteApp -and $null -ne $app)) + 1)

    if ($WorkspaceId) {
        Step "Remove service principal from Fabric workspace $WorkspaceId"
        if (-not $spId) {
            Say "  No service principal object id available - if a membership remains, remove it via the workspace Access pane." "Yellow"
        } elseif (Confirm-Action "Remove the service principal from workspace $WorkspaceId?") {
            if (Remove-SpFromWorkspace -WorkspaceId $WorkspaceId -PrincipalId $spId -Token (Get-PbiToken)) { Say "  Verified: removed from workspace." "Green" }
            else { Say "  Could not confirm removal - remove manually via the workspace Access pane." "Yellow" }
        } else { Say "  Skipped." "Yellow" }
    }

    if ($spId) {
        Step "Revoke Defender application permissions (app-role assignments)"
        if (Confirm-Action "Revoke all Defender app-role grants from the SP?") {
            $mdatp   = Resolve-MdatpRoles
            $granted = @(Get-GrantedDefenderRoles -SpObjectId $spId -Mdatp $mdatp)
            if ($granted.Count -eq 0) {
                Say "  Nothing to revoke - no Defender grants present." "Green"
            } else {
                # Only NOW do we need the elevated role (an actual revoke will occur).
                Assert-WriteCapability -Capability GrantAppPermissions -Caps $Caps -TenantId $ctx.tenantId -AllowUnconfirmed:$ForceWrite
                if (Remove-DefenderRoles -SpObjectId $spId -Mdatp $mdatp) { Say "  Verified: no Defender grants remain." "Green" }
                else { Say "  Some grants still present (replication lag) - re-run -Mode CheckPermissions to confirm." "Yellow" }
            }
        } else { Say "  Skipped." "Yellow" }
    }

    if ($DeleteApp -and $null -ne $app) {
        Step "Delete the app registration (also removes its service principal)"
        if (Confirm-Action "PERMANENTLY delete app registration $appId?") {
            az ad app delete --id $appId 2>$null | Out-Null
            Start-Sleep -Seconds 3
            $stillThere = az ad app show --id $appId 2>$null | ConvertFrom-Json
            if (-not $stillThere) { Say "  Verified: app registration deleted." "Green" }
            else { Say "  App still present - delete manually in Entra > App registrations." "Yellow" }
        } else { Say "  Skipped." "Yellow" }
    }

    Step "Remove local config.json (contains the client secret)"
    if (Test-Path -LiteralPath $ConfigOut) {
        if (Confirm-Action "Delete local secret file $ConfigOut?") {
            Remove-Item -LiteralPath $ConfigOut -Force
            if (-not (Test-Path -LiteralPath $ConfigOut)) { Say "  Verified: config removed." "Green" }
        } else { Say "  Left in place: $ConfigOut (still contains a secret)." "Yellow" }
    } else { Say "  No config file at $ConfigOut." "Gray" }

    Say ""
    Say "Uninstall complete." "Green"
    return
}

# --------------------------------------------------------------------- INSTALL (CreateNew / UseExisting)
# Numbered, self-verifying steps. Each write is followed by a read-back that confirms it applied;
# manual prerequisites pause and are re-checked before the script continues.
Set-StepTotal (3 + ([int][bool]$WorkspaceId))
$issues = @()   # outstanding items -> drives an honest final summary (never a false "complete")

# Step: grant + verify Defender application permissions. Read state first; only require the elevated
# role (and attempt a write) when something is actually missing.
Step "Grant WindowsDefenderATP application permissions (Machine/Software/Vulnerability/AdvancedQuery .Read.All)"
$mdatp   = Resolve-MdatpRoles
$granted = @(Get-GrantedDefenderRoles -SpObjectId $spId -Mdatp $mdatp)
$missing = @($RequiredDefenderRoles | Where-Object { $granted -notcontains $_ })
if ($missing.Count -eq 0) {
    [void](Show-DefenderPermissionStatus -Granted $granted)
    Say "  Already granted - no change needed." "Green"
} else {
    Assert-WriteCapability -Capability GrantAppPermissions -Caps $Caps -TenantId $ctx.tenantId -AllowUnconfirmed:$ForceWrite
    $permsOk = Confirm-DefenderPermissions -AppId $appId -SpObjectId $spId -DoFix   # grants missing + re-verifies
    if (-not $permsOk) { $issues += "Defender permissions not fully confirmed (directory replication can lag; re-run -Mode CheckPermissions -AppId $appId)." }
}

# Step: add SP to the workspace (+ verify) - only when -WorkspaceId is supplied. Uses the SP object id.
if ($WorkspaceId) {
    Step "Add the service principal to Fabric workspace $WorkspaceId as Admin"
    Assert-WriteCapability -Capability WorkspaceAdmin -Caps $Caps -TenantId $ctx.tenantId
    if (Add-SpToWorkspace -WorkspaceId $WorkspaceId -PrincipalId $spId -Token (Get-PbiToken)) { Say "  Verified: SP is a workspace Admin." "Green" }
    else { Say "  Could not confirm workspace membership - add the app as a workspace Admin/Member manually, then re-run." "Yellow"; $issues += "Service principal not confirmed as a member of workspace $WorkspaceId." }
}

# Step: create secret + write the git-ignored config.json. With -NoSecret we must find a usable,
# matching secret already on disk - never write a null/mismatched secret over the config.
Step "Create client secret and write config.json"
$secret = $null
if ($NoSecret) {
    if (-not (Test-Path -LiteralPath $ConfigOut)) { throw "-NoSecret requires an existing $ConfigOut with a stored secret. Omit -NoSecret to create one." }
    $prev = Get-Content -LiteralPath $ConfigOut -Raw | ConvertFrom-Json
    if (-not $prev.clientSecret) { throw "-NoSecret: $ConfigOut has no clientSecret. Omit -NoSecret to create one." }
    if ($prev.clientId -and $prev.clientId -ne $appId) { throw "-NoSecret: $ConfigOut is for a different app ($($prev.clientId)); refusing to reuse its secret for $appId." }
    if ($prev.tenantId -and $prev.tenantId -ne $ctx.tenantId) { throw "-NoSecret: $ConfigOut is for a different tenant; refusing to reuse its secret." }
    $secret = $prev.clientSecret
    Say "  -NoSecret: reusing the matching secret already stored in $ConfigOut." "Yellow"
} else {
    $cred = az ad app credential reset --id $appId --display-name "defender-dashboard" --years $SecretYears --append | ConvertFrom-Json
    $secret = $cred.password
    Say "  Secret created (expires in $SecretYears year(s))." "Green"
}
$cfg = [ordered]@{
    tenantId      = $ctx.tenantId
    clientId      = $appId
    clientSecret  = $secret
    workspaceId   = $WorkspaceId
}
$dir = Split-Path -Parent $ConfigOut
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
$cfg | ConvertTo-Json | Set-Content -LiteralPath $ConfigOut -Encoding UTF8
if (Test-Path -LiteralPath $ConfigOut) { Say "  Verified: config written to $ConfigOut (git-ignored - DO NOT COMMIT / sync)." "Green" }

# Step: prove the SP can actually authenticate AND use Fabric. The Fabric call also validates the
# manual tenant prerequisite, so instruct + re-check here rather than just printing a reminder.
Step "Verify the service principal can sign in and use the Fabric APIs"
$verifySecret = $cfg.clientSecret
if (-not $verifySecret) {
    Say "  No secret available to test with." "Yellow"; $issues += "No secret available to verify sign-in."
} else {
    if (Wait-ForToken -TenantId $ctx.tenantId -ClientId $appId -ClientSecret $verifySecret -Resource "https://api.securitycenter.microsoft.com") {
        Say "  Verified: Defender (securitycenter) token acquired." "Green"
    } else { Say "  Defender token not yet available (consent still propagating)." "Yellow"; $issues += "Defender token not yet acquired (re-run -Mode Verify shortly)." }

    $fabricInstruction = @"
A Fabric admin must enable service-principal API access before deployment can publish:
  1. https://app.powerbi.com  ->  Settings (gear)  ->  Admin portal  ->  Tenant settings
  2. Developer settings  ->  'Service principals can use Fabric APIs'  ->  Enabled
  3. Apply to the whole org OR a security group that CONTAINS this app ($appId)
  4. If deploying to a specific workspace, also ensure the app is a workspace Admin/Member.
"@
    if (-not (Wait-ForManualStep -Instruction $fabricInstruction -Verify {
                Test-FabricSpAccess -TenantId $ctx.tenantId -ClientId $appId -ClientSecret $verifySecret -WorkspaceId $WorkspaceId
            })) {
        $issues += "Fabric SP access not confirmed - enable 'Service principals can use Fabric APIs', then re-run -Mode Verify."
    }
}

Say ""
if ($issues.Count -eq 0) {
    Say "Bootstrap complete - every step verified." "Green"
} else {
    Say "Bootstrap finished with OUTSTANDING items (address these before/at deploy):" "Yellow"
    $issues | ForEach-Object { Say "  - $_" "Yellow" }
}
Say ("AppId={0}  Tenant={1}" -f $appId, $ctx.tenantId) "Green"
Say ""
Say "Next step -> deploy the dashboard:" "White"
Say ("  pwsh ./Deploy-Dashboard.ps1 -ConfigPath `"{0}`"{1}" -f $ConfigOut, $(if ($WorkspaceId) { " -WorkspaceId $WorkspaceId" } else { " -WorkspaceId <ws-guid>" })) "White"
Say ""
Say "To remove everything later:  pwsh ./Bootstrap-Deployment.ps1 -Mode Uninstall -AppId $appId -WorkspaceId <ws-guid> [-DeleteApp]" "Gray"
if ($issues.Count -gt 0) { exit 2 }
return

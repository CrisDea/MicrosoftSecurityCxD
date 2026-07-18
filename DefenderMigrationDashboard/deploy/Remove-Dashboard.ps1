<#
.SYNOPSIS
    Remove the Defender Migration Dashboard (report + semantic model) from a Fabric workspace,
    and optionally delete the workspace itself. Doubles as a teardown for test deployments.

.DESCRIPTION
    Removes the report first, then the semantic model. With -RemoveWorkspace it also deletes the
    workspace, which is handy for tidying up a test run.

    If an item is already gone it's simply skipped. Deleting anything asks for confirmation first
    unless you pass -Force, and deleting a whole workspace always needs -Force as a safety net.

.PARAMETER WorkspaceId
    The workspace to clean (required).

.PARAMETER ModelName / ReportName
    Item names to remove. Defaults match Deploy-Dashboard.ps1.

.PARAMETER RemoveWorkspace
    Also delete the workspace after removing the items. Requires -Force.

.PARAMETER Force
    Skip the confirmation prompts.

.PARAMETER TenantId / ConfigPath / ClientId / ClientSecret
    Same sign-in options as Deploy-Dashboard.ps1 (Azure CLI by default; service principal when
    those credentials are supplied).

.EXAMPLE
    .\Remove-Dashboard.ps1 -WorkspaceId <guid>

.EXAMPLE
    # Tidy up a test workspace completely
    .\Remove-Dashboard.ps1 -WorkspaceId <guid> -RemoveWorkspace -Force

.NOTES
    Licensed under the MIT License. Provided as-is, without warranty.
#>
[CmdletBinding()]
param(
    [string]$WorkspaceId,
    [string]$ModelName  = "Defender Migration",
    [string]$ReportName = "Defender Migration",
    [switch]$RemoveWorkspace,
    [switch]$Force,
    [string]$TenantId,
    [string]$ConfigPath,
    [string]$ClientId,
    [string]$ClientSecret
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\_Common.ps1"

function Confirm-Action([string]$Message) {
    if ($Force) { return $true }
    $ans = Read-Host "$Message  [y/N]"
    return ($ans -match '^[Yy]')
}

try {
    if ($ConfigPath) {
        $cfg = Import-DeployConfig -ConfigPath $ConfigPath
        if (-not $TenantId     -and $cfg.ContainsKey('tenantId'))     { $TenantId     = $cfg.tenantId }
        if (-not $ClientId     -and $cfg.ContainsKey('clientId'))     { $ClientId     = $cfg.clientId }
        if (-not $ClientSecret -and $cfg.ContainsKey('clientSecret')) { $ClientSecret = $cfg.clientSecret }
        if (-not $WorkspaceId  -and $cfg.ContainsKey('workspaceId'))  { $WorkspaceId  = $cfg.workspaceId }
        # Match Deploy-Dashboard: an explicit -ModelName/-ReportName wins, else config.json can
        # override the default so teardown targets whatever the customer named the items.
        if (-not $PSBoundParameters.ContainsKey('ModelName')  -and $cfg.ContainsKey('modelName'))  { $ModelName  = $cfg.modelName }
        if (-not $PSBoundParameters.ContainsKey('ReportName') -and $cfg.ContainsKey('reportName')) { $ReportName = $cfg.reportName }
    }
    Initialize-Auth -ClientId $ClientId -ClientSecret $ClientSecret -TenantId $TenantId
    Test-Prereqs
    if (-not $WorkspaceId) {
        throw "No workspace specified. Pass -WorkspaceId <guid>, or supply it via -ConfigPath config.json (workspaceId)."
    }
    Ensure-SignedIn -TenantId $TenantId

    $ws = Get-WorkspaceById $WorkspaceId
    if (-not $ws) { throw "Workspace $WorkspaceId not found or not accessible." }
    Write-Step "Target workspace '$($ws.displayName)' ($WorkspaceId)"

    if (-not (Confirm-Action "Remove report '$ReportName' and model '$ModelName' from this workspace?")) {
        Write-Warn2 "Cancelled by user."; exit 0
    }

    # Remove the report first, then the model, but keep going if one step fails so a partial
    # teardown never blocks the rest. Each removal is retried a couple of times on transient errors.
    $failures = 0
    function Remove-WithRetry([string]$Type, [string]$Name) {
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try { Remove-ItemFabric -WsId $WorkspaceId -Type $Type -DisplayName $Name | Out-Null; return $true }
            catch {
                if ($attempt -lt 3) {
                    Write-Warn2 "Could not remove $Type '$Name' (attempt $attempt/3): $($_.Exception.Message). Retrying..."
                    Start-Sleep -Seconds ([int][Math]::Min(15, [Math]::Pow(2, $attempt)))
                } else {
                    Write-Err "Failed to remove $Type '$Name' after 3 attempts: $($_.Exception.Message)"
                    return $false
                }
            }
        }
        return $false
    }

    Write-Step "Removing report"
    if (-not (Remove-WithRetry -Type "Report" -Name $ReportName)) { $failures++ }

    Write-Step "Removing semantic model"
    if (-not (Remove-WithRetry -Type "SemanticModel" -Name $ModelName)) { $failures++ }

    if ($RemoveWorkspace) {
        if (-not $Force) { throw "Refusing to delete the workspace without -Force. Re-run with -RemoveWorkspace -Force." }
        if ($failures -gt 0) {
            Write-Warn2 "Skipping workspace deletion because $failures item(s) could not be removed. Resolve those first, then re-run with -RemoveWorkspace -Force."
        } else {
            Write-Step "Deleting workspace '$($ws.displayName)'"
            try { Invoke-Http -Method DELETE -Url "$script:FabricBase/workspaces/$WorkspaceId" -AllowNotFound | Out-Null; Write-Ok "Workspace deleted." }
            catch { Write-Err "Failed to delete workspace: $($_.Exception.Message)"; $failures++ }
        }
    }

    Write-Host ""
    if ($failures -gt 0) {
        Write-Warn2 "Cleanup finished with $failures problem(s). It is safe to re-run this script to retry the remaining item(s)."
        exit 1
    }
    Write-Host "Cleanup complete." -ForegroundColor Green
}
catch {
    Write-Host ""
    Write-Err "Cleanup failed: $($_.Exception.Message)"
    exit 1
}

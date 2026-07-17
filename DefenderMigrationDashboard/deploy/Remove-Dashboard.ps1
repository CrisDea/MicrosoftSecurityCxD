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
    [Parameter(Mandatory)][string]$WorkspaceId,
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
    Ensure-SignedIn -TenantId $TenantId

    $ws = Get-WorkspaceById $WorkspaceId
    if (-not $ws) { throw "Workspace $WorkspaceId not found or not accessible." }
    Write-Step "Target workspace '$($ws.displayName)' ($WorkspaceId)"

    if (-not (Confirm-Action "Remove report '$ReportName' and model '$ModelName' from this workspace?")) {
        Write-Warn2 "Cancelled by user."; exit 0
    }

    Write-Step "Removing report"
    Remove-ItemFabric -WsId $WorkspaceId -Type "Report" -DisplayName $ReportName | Out-Null

    Write-Step "Removing semantic model"
    Remove-ItemFabric -WsId $WorkspaceId -Type "SemanticModel" -DisplayName $ModelName | Out-Null

    if ($RemoveWorkspace) {
        if (-not $Force) { throw "Refusing to delete the workspace without -Force. Re-run with -RemoveWorkspace -Force." }
        Write-Step "Deleting workspace '$($ws.displayName)'"
        Invoke-Http -Method DELETE -Url "$script:FabricBase/workspaces/$WorkspaceId" -AllowNotFound | Out-Null
        Write-Ok "Workspace deleted."
    }

    Write-Host ""
    Write-Host "Cleanup complete." -ForegroundColor Green
}
catch {
    Write-Host ""
    Write-Err "Cleanup failed: $($_.Exception.Message)"
    exit 1
}

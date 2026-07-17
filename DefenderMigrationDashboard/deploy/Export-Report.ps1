<#
.SYNOPSIS
  Headless export of the published Defender Migration Dashboard report to PDF or PPTX.

.DESCRIPTION
  Asks Power BI to render the report and waits until the file is ready, then saves it locally.
  Sign in with a service principal (via -ConfigPath / -ClientId+-ClientSecret+-TenantId) or, by
  default, interactively with the Azure CLI (az login).

.EXAMPLE
  pwsh ./Export-Report.ps1 -WorkspaceId <ws-guid> -ReportId <report-guid> -Format PDF
  pwsh ./Export-Report.ps1 -WorkspaceId <ws> -ReportId <r> -Format PPTX -Pages "Non-Compliant Devices" -ConfigPath ./config.json

.NOTES
  Licensed under the MIT License. Provided as-is, without warranty.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$WorkspaceId,
    [Parameter(Mandatory)][string]$ReportId,
    [ValidateSet("PDF","PPTX")][string]$Format = "PDF",
    [string]$Pages,                                   # comma-separated page display names or internal names (optional)
    [string]$OutDir = "$PSScriptRoot/output",
    [string]$ConfigPath,
    [string]$ClientId,
    [string]$ClientSecret,
    [string]$TenantId,
    [int]$TimeoutSec = 600
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\_Common.ps1"

try {
    if ($ConfigPath) {
        $cfg = Import-DeployConfig -ConfigPath $ConfigPath
        if (-not $TenantId     -and $cfg.ContainsKey('tenantId'))     { $TenantId     = $cfg.tenantId }
        if (-not $ClientId     -and $cfg.ContainsKey('clientId'))     { $ClientId     = $cfg.clientId }
        if (-not $ClientSecret -and $cfg.ContainsKey('clientSecret')) { $ClientSecret = $cfg.clientSecret }
    }
    Initialize-Auth -ClientId $ClientId -ClientSecret $ClientSecret -TenantId $TenantId
    Test-Prereqs
    Ensure-SignedIn -TenantId $TenantId

    # Validate the report exists before requesting an export.
    Write-Step "Validating report $ReportId"
    $report = Invoke-Http -Method GET -Resource $script:PowerBIRes -Url "$script:PowerBIBase/groups/$WorkspaceId/reports/$ReportId" -AllowNotFound
    if (-not $report) { throw "Report $ReportId not found in workspace $WorkspaceId (check the ids, and that the identity has access)." }
    Write-Ok "Report '$($report.name)'"

    $req = @{ format = $Format }
    if ($Pages) {
        # ExportTo expects each pages[].pageName to be the page's INTERNAL name (e.g. ReportSection0),
        # not its visible display name. Resolve the user-supplied display names to internal names.
        $wanted = @($Pages.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $allPages = (Invoke-Http -Method GET -Resource $script:PowerBIRes `
                        -Url "$script:PowerBIBase/groups/$WorkspaceId/reports/$ReportId/pages").value
        $resolved = foreach ($name in $wanted) {
            $match = $allPages | Where-Object { $_.displayName -eq $name -or $_.name -eq $name } | Select-Object -First 1
            if (-not $match) { throw "Page '$name' not found in the report. Available: $(( $allPages | ForEach-Object { $_.displayName }) -join ', ')." }
            @{ pageName = $match.name }
        }
        $req.powerBIReportConfiguration = @{ pages = @($resolved) }
    }
    Write-Step "Requesting $Format export"
    $export = Invoke-Http -Method POST -Resource $script:PowerBIRes `
                -Url "$script:PowerBIBase/groups/$WorkspaceId/reports/$ReportId/ExportTo" -Body $req
    $exportId = $export.id
    Write-Ok "Export id: $exportId"

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $status = $null
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 4
        try {
            $status = Invoke-Http -Method GET -Resource $script:PowerBIRes `
                        -Url "$script:PowerBIBase/groups/$WorkspaceId/reports/$ReportId/exports/$exportId"
        } catch { continue }   # transient - keep polling
        Write-Ok ("{0} {1}%" -f $status.status, $status.percentComplete)
        if ($status.status -notin @("Running","NotStarted")) { break }
    }
    if (-not $status -or $status.status -ne "Succeeded") {
        throw "Export did not succeed (last status: $($status.status)). Large reports can exceed the timeout - re-run with a higher -TimeoutSec."
    }

    if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
    $ext  = if ($Format -eq "PPTX") { "pptx" } else { "pdf" }
    $file = Join-Path $OutDir ("DefenderMigrationDashboard-{0:yyyyMMdd-HHmmss}.{1}" -f (Get-Date), $ext)
    $tok  = Get-Token -Resource $script:PowerBIRes
    Invoke-WebRequest -Method GET -Uri "$script:PowerBIBase/groups/$WorkspaceId/reports/$ReportId/exports/$exportId/file" `
        -Headers @{ Authorization = "Bearer $tok" } -OutFile $file -UseBasicParsing
    Write-Host ""
    Write-Host "Saved: $file" -ForegroundColor Green
}
catch {
    Write-Host ""
    Write-Err "Export failed: $($_.Exception.Message)"
    exit 1
}

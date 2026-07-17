<#
.SYNOPSIS
    Ingests a Trend Micro device export (CSV) into the dashboard's local TrendMigration table by
    matching each Trend device to the current Microsoft Defender inventory on an exact short
    hostname, with fuzzy tolerance applied only to the DNS domain suffix.

.DESCRIPTION
    This is the standalone companion to Deploy-Dashboard.ps1 -TrendCsv. It:

      1. Reads the Trend Micro CSV export and auto-detects the host-name column.
      2. Pulls the current Defender device inventory from the paged GET /api/machines export endpoint
         (the same source that feeds the dashboard's DeviceHealth table), using an app-only token.
      3. Matches Trend devices to Defender devices on an EXACT normalised short hostname, applying
         fuzzy tolerance (>= -MatchThreshold) ONLY to the DNS domain suffix. So 'host.contoso.com'
         still matches 'host.contoso.local', a short 'host' matches any 'host.<domain>', but two
         different hostnames are never fuzzy-matched to each other.
      4. Classifies each device: "Migrated to Defender" (matched + onboarded), "Matched - not
         onboarded", or "Not found in Defender".
      5. Writes a preview mapping CSV you can review, and (with -Materialize) embeds the mapping into
         the local semantic model's TrendMigration.tmdl so the table is populated when you open the
         PBIP in Power BI Desktop or publish it.

    Credentials: supply the Entra app (Service Principal) that can read Defender - via -ConfigPath
    config.json (tenantId/clientId/clientSecret or graphTenantId/graphClientId/graphClientSecret) or
    via -TenantId -ClientId -ClientSecret. The app needs WindowsDefenderATP Machine.Read.All
    (app-only), admin-consented.

    NOTE ON REFRESH: the published model refreshes in the Power BI service via a Service Principal
    with no on-premises data gateway, so a live local-file source could never refresh in the service.
    The mapping is therefore materialised at ingest/deploy time (identical to the DeploymentTrend and
    AV-posture seeds). Re-run this script (or re-deploy with -TrendCsv) whenever the Trend export or
    the Defender inventory changes.

.PARAMETER TrendCsv
    Path to the Trend Micro device export CSV. Required unless -RestorePlaceholder is used (it may
    also be supplied via -ConfigPath config.json 'trendCsv').

.PARAMETER ConfigPath
    Path to config.json supplying the Entra app credentials (and optionally trendCsv).

.PARAMETER TenantId / ClientId / ClientSecret
    Entra app credentials, as an alternative to -ConfigPath.

.PARAMETER ProjectPath
    Path to the PBIP project folder. Default: ..\pbip-project relative to this script.

.PARAMETER OutCsv
    Where to write the preview mapping CSV. Default: .\trend-migration-mapping.csv next to this script.

.PARAMETER MatchThreshold
    Similarity score (0-100) at or above which a differing DNS domain suffix is still accepted for a
    device whose short hostname already matches exactly. The hostname itself must always match
    exactly; this threshold governs the domain only. Default 82.

.PARAMETER Materialize
    Embed the mapping into the local TrendMigration.tmdl (populates the local table). Without this
    switch the script only writes the preview CSV and prints a summary.

.PARAMETER RestorePlaceholder
    Reset TrendMigration.tmdl back to the empty __TRENDMIGRATION_SEED_B64__ placeholder and exit
    (undoes a previous -Materialize so the file is clean to commit).

.EXAMPLE
    .\Import-TrendInventory.ps1 -TrendCsv .\trend-export.csv -ConfigPath .\config.json

.EXAMPLE
    .\Import-TrendInventory.ps1 -TrendCsv .\trend-export.csv -ConfigPath .\config.json -Materialize

.NOTES
    Licensed under the MIT License. Provided as-is, without warranty.
#>
[CmdletBinding()]
param(
    [string]$TrendCsv,
    [string]$ConfigPath,
    [string]$TenantId,
    [string]$ClientId,
    [string]$ClientSecret,
    [string]$ProjectPath,
    [string]$OutCsv,
    [ValidateRange(0, 100)][int]$MatchThreshold = 82,
    [switch]$Materialize,
    [switch]$RestorePlaceholder
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\_Common.ps1"

$PLACEHOLDER = "__TRENDMIGRATION_SEED_B64__"

# ---- resolve the model's TrendMigration.tmdl --------------------------------
if (-not $ProjectPath) { $ProjectPath = Join-Path $PSScriptRoot "..\pbip-project" }
$ProjectPath = (Resolve-Path $ProjectPath).Path
$modelDir = (Get-ChildItem -LiteralPath $ProjectPath -Directory -Filter "*.SemanticModel" | Select-Object -First 1).FullName
if (-not $modelDir) { throw "No *.SemanticModel folder found under $ProjectPath" }
$tmdlPath = Join-Path $modelDir "definition\tables\TrendMigration.tmdl"
if (-not (Test-Path -LiteralPath $tmdlPath)) { throw "TrendMigration.tmdl not found: $tmdlPath" }

function Set-SeedLiteral {
    <# Replaces the SeedB64 = "..." literal in TrendMigration.tmdl with the given value, whether the
       current value is the placeholder or a previously materialised base64. Idempotent. #>
    param([string]$Value)
    $raw = Get-Content -LiteralPath $tmdlPath -Raw
    $new = [System.Text.RegularExpressions.Regex]::Replace(
        $raw, 'SeedB64 = "[^"]*"', ('SeedB64 = "' + $Value + '"'))
    Set-Content -LiteralPath $tmdlPath -Value $new -NoNewline -Encoding UTF8
}

if ($RestorePlaceholder) {
    Set-SeedLiteral -Value $PLACEHOLDER
    Write-Ok "TrendMigration.tmdl reset to the empty placeholder."
    return
}

# ---- credentials ------------------------------------------------------------
if ($ConfigPath) {
    $cfg = Import-DeployConfig -ConfigPath $ConfigPath
    if (-not $TenantId     -and $cfg.ContainsKey('graphTenantId'))     { $TenantId     = $cfg.graphTenantId }
    if (-not $TenantId     -and $cfg.ContainsKey('tenantId'))          { $TenantId     = $cfg.tenantId }
    if (-not $ClientId     -and $cfg.ContainsKey('graphClientId'))     { $ClientId     = $cfg.graphClientId }
    if (-not $ClientId     -and $cfg.ContainsKey('clientId'))          { $ClientId     = $cfg.clientId }
    if (-not $ClientSecret -and $cfg.ContainsKey('graphClientSecret')) { $ClientSecret = $cfg.graphClientSecret }
    if (-not $ClientSecret -and $cfg.ContainsKey('clientSecret'))      { $ClientSecret = $cfg.clientSecret }
    if (-not $TrendCsv     -and $cfg.ContainsKey('trendCsv'))          { $TrendCsv     = $cfg.trendCsv }
}

if (-not $TrendCsv) {
    throw "No Trend CSV supplied. Pass -TrendCsv <trend-export.csv> (or set 'trendCsv' in config.json). Use -RestorePlaceholder to reset the table without a CSV."
}

# ---- ingest -----------------------------------------------------------------
Write-Step "Reading Trend export"
$names = Get-TrendDeviceNames -TrendCsv $TrendCsv
if ($names.Count -eq 0) { throw "No device names found in the Trend CSV ($TrendCsv)." }

Write-Step "Querying Defender inventory"
$inv = Get-DefenderInventory -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret
Write-Ok "Defender inventory: $($inv.Count) current devices"

Write-Step "Fuzzy-matching Trend -> Defender"
$map = Get-TrendDefenderMapping -TrendNames $names -Inventory $inv -MatchThreshold $MatchThreshold

$total = $map.Count
$migr  = @($map | Where-Object { $_.MigrationStatus -eq "Migrated to Defender" }).Count
$pend  = @($map | Where-Object { $_.MigrationStatus -eq "Matched - not onboarded" }).Count
$miss  = @($map | Where-Object { $_.MigrationStatus -eq "Not found in Defender" }).Count
$fuzz  = @($map | Where-Object { $_.MatchType -eq "Fuzzy" }).Count
$pct   = if ($total -gt 0) { [math]::Round(100.0 * $migr / $total, 1) } else { 0 }

Write-Host ""
Write-Ok "Trend devices (unique): $total"
Write-Ok "  Migrated to Defender:      $migr ($pct%)"
Write-Ok "  Matched - not onboarded:   $pend"
Write-Ok "  Not found in Defender:     $miss"
Write-Ok "  (of matched, fuzzy-matched: $fuzz)"

# ---- preview CSV ------------------------------------------------------------
if (-not $OutCsv) { $OutCsv = Join-Path $PSScriptRoot "trend-migration-mapping.csv" }
$map | Sort-Object MigrationStatus, MatchScore | Export-Csv -LiteralPath $OutCsv -NoTypeInformation -Encoding UTF8
Write-Ok "Preview mapping written: $OutCsv"

# ---- materialize into the local table ---------------------------------------
if ($Materialize) {
    $seedJson = ConvertTo-TrendMigrationSeed -Mapping $map
    $seedB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($seedJson))
    Set-SeedLiteral -Value $seedB64
    Write-Ok "TrendMigration.tmdl materialised with $total rows. Open the PBIP in Power BI Desktop or deploy to publish it."
    Write-Warn2 "The .tmdl now contains your device data. Run -RestorePlaceholder before committing this file to source control."
} else {
    Write-Host ""
    Write-Ok "Review $OutCsv, then either re-run with -Materialize to populate the local table, or deploy with:"
    Write-Ok "  .\Deploy-Dashboard.ps1 -ConfigPath <config.json> -WorkspaceId <id> -TrendCsv `"$TrendCsv`""
}

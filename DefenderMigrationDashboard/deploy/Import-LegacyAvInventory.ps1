<#
.SYNOPSIS
    Ingests one or more third-party AV/EDR device exports (CSV) into the dashboard's local
    LegacyAvMigration table by matching each legacy device to the current Microsoft Defender
    inventory on an exact short hostname, with fuzzy tolerance applied only to the DNS domain suffix.

.DESCRIPTION
    Vendor-neutral: works with any AV/EDR export (Trend Micro, Symantec, McAfee/Trellix, Sophos,
    CrowdStrike, SentinelOne, Kaspersky, ESET, Carbon Black, Cylance, Bitdefender, Cortex XDR,
    Check Point, Cisco Secure Endpoint, Webroot, Malwarebytes, WithSecure, and anything else).

    This is the standalone companion to Deploy-Dashboard.ps1 -LegacyCsv. It:

      1. Reads the legacy AV/EDR CSV export, auto-detects the host-name and unique-id columns, and
         identifies WHICH product the export came from by matching its header signature against the
         built-in catalog (see Get-LegacyAvCatalog). Unrecognised exports still ingest safely under
         the neutral label "Legacy AV/EDR"; use -SourceProduct to name them explicitly.
      2. Stamps EVERY ingested row with its own LegacyProduct and LegacyVendor, so a customer
         migrating off several tools at once can always tell which device came from which product.
      3. Pulls the current Defender device inventory from the paged GET /api/machines export endpoint
         (the same source that feeds the dashboard's DeviceHealth table), using an app-only token.
      4. Matches legacy devices to Defender devices on an EXACT normalised short hostname, applying
         fuzzy tolerance (>= -MatchThreshold) ONLY to the DNS domain suffix. So 'host.contoso.com'
         still matches 'host.contoso.local', a short 'host' matches any 'host.<domain>', but two
         different hostnames are never fuzzy-matched to each other.
      5. Classifies each device: "Migrated to Defender" (matched + onboarded), "Matched - not
         onboarded", or "Not found in Defender" - and reports those figures per legacy product.
      6. Writes a preview mapping CSV you can review, and (with -Materialize) embeds the mapping into
         the local semantic model's LegacyAvMigration.tmdl so the table is populated when you open the
         PBIP in Power BI Desktop or publish it.

    MULTI-VENDOR WORKFLOW: run this once per export with -LegacyMode Append. Each run adds its
    devices to the master store while keeping the labels of everything ingested before, so the
    dashboard can slice migration progress by product and by vendor:

        .\Import-LegacyAvInventory.ps1 -LegacyCsv .\apexone.csv  -LegacyMode Replace -ConfigPath .\config.json
        .\Import-LegacyAvInventory.ps1 -LegacyCsv .\falcon.csv   -LegacyMode Append  -ConfigPath .\config.json
        .\Import-LegacyAvInventory.ps1 -LegacyCsv .\sep.csv      -LegacyMode Append  -ConfigPath .\config.json -Materialize

    The same hostname present in two different products is intentionally kept as two rows: they are
    two separate migration facts (two agents to remove).

    Credentials: supply the Entra app (Service Principal) that can read Defender - via -ConfigPath
    config.json (tenantId/clientId/clientSecret or graphTenantId/graphClientId/graphClientSecret) or
    via -TenantId -ClientId -ClientSecret. The app needs WindowsDefenderATP Machine.Read.All
    (app-only), admin-consented.

    NOTE ON REFRESH: the published model refreshes in the Power BI service via a Service Principal
    with no on-premises data gateway, so a live local-file source could never refresh in the service.
    The mapping is therefore materialised at ingest/deploy time (identical to the DeploymentTrend and
    AV-posture seeds). Re-run this script (or re-deploy with -LegacyCsv) whenever an export or the
    Defender inventory changes.

.PARAMETER LegacyCsv
    Path to the third-party AV/EDR device export CSV. Required unless -RestorePlaceholder is used, or
    -LegacyMode Append is re-processing the existing store (it may also be supplied via -ConfigPath
    config.json 'legacyCsv'). Alias: -TrendCsv (deprecated).

.PARAMETER ConfigPath
    Path to config.json supplying the Entra app credentials (and optionally legacyCsv).

.PARAMETER TenantId / ClientId / ClientSecret
    Entra app credentials, as an alternative to -ConfigPath.

.PARAMETER ProjectPath
    Path to the PBIP project folder. Default: ..\pbip-project relative to this script.

.PARAMETER OutCsv
    Where to write the preview mapping CSV. Default: .\legacy-migration-mapping.csv next to this
    script. Git-ignored - it holds customer device data.

.PARAMETER LegacyMode
    How the export is combined with the local master store (deploy\legacy-inventory.local.csv, which
    is git-ignored):
      Replace (default) - the supplied export becomes the entire legacy list, de-duplicated on the
                          source tool's unique id. Wipes whatever was ingested before, INCLUDING
                          other vendors' devices. Use for the first import only.
      Append            - keep everything already ingested and add only the export's new devices
                          (de-duplicated on the legacy id, falling back to host|product when a row
                          has no id). This is the mode to use when migrating off several AV/EDR
                          products, or when building one list from several partial exports.
    Alias: -Mode (deprecated).

.PARAMETER InventoryStore
    Path to the local master store CSV (LegacyId,DeviceName,LegacyProduct,LegacyVendor,FirstSeen).
    Default: .\legacy-inventory.local.csv next to this script. Git-ignored - it holds customer device
    data and must never be committed.

.PARAMETER SourceProduct
    Overrides the auto-detected product label (for example "Trend Micro Apex One", "CrowdStrike
    Falcon" or "Contoso Guard") written to LegacyProduct on every row of THIS export. Omit to let the
    script infer it from the export's header signature. Alias: -Source (deprecated).

.PARAMETER SourceVendor
    Overrides the vendor label written to LegacyVendor (for example "Trend Micro", "Broadcom").
    Inferred from the catalog when the product is recognised.

.PARAMETER MatchThreshold
    Similarity score (0-100) at or above which a differing DNS domain suffix is still accepted for a
    device whose short hostname already matches exactly. The hostname itself must always match
    exactly; this threshold governs the domain only. Default 82.

.PARAMETER Materialize
    Embed the mapping into the local LegacyAvMigration.tmdl (populates the local table). Without this
    switch the script only writes the preview CSV and prints a summary.

.PARAMETER RestorePlaceholder
    Reset LegacyAvMigration.tmdl back to the empty __LEGACYMIGRATION_SEED_B64__ placeholder and exit
    (undoes a previous -Materialize so the file is clean to commit).

.EXAMPLE
    .\Import-LegacyAvInventory.ps1 -LegacyCsv .\apexone-export.csv -ConfigPath .\config.json

.EXAMPLE
    .\Import-LegacyAvInventory.ps1 -LegacyCsv .\falcon-export.csv -LegacyMode Append -ConfigPath .\config.json -Materialize

.EXAMPLE
    .\Import-LegacyAvInventory.ps1 -LegacyCsv .\inhouse.csv -SourceProduct "Contoso Guard" -SourceVendor "Contoso" -ConfigPath .\config.json

.NOTES
    Licensed under the MIT License. Provided as-is, without warranty.
    Requires Windows PowerShell 5.1 or later (also runs on PowerShell 7+).
#>
[CmdletBinding()]
param(
    [Alias('TrendCsv')][string]$LegacyCsv,
    [string]$ConfigPath,
    [string]$TenantId,
    [string]$ClientId,
    [string]$ClientSecret,
    [string]$ProjectPath,
    [string]$OutCsv,
    [Alias('Mode')][ValidateSet('Replace','Append')][string]$LegacyMode = 'Replace',
    [string]$InventoryStore,
    [Alias('Source')][string]$SourceProduct,
    [string]$SourceVendor,
    [ValidateRange(0, 100)][int]$MatchThreshold = 82,
    [switch]$Materialize,
    [switch]$RestorePlaceholder
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\_Common.ps1"
Test-PowerShellBaseline

$PLACEHOLDER = "__LEGACYMIGRATION_SEED_B64__"

# ---- resolve the model's LegacyAvMigration.tmdl -----------------------------
if (-not $ProjectPath) { $ProjectPath = Join-Path $PSScriptRoot "..\pbip-project" }
$ProjectPath = (Resolve-Path $ProjectPath).Path
$modelDir = (Get-ChildItem -LiteralPath $ProjectPath -Directory -Filter "*.SemanticModel" | Select-Object -First 1).FullName
if (-not $modelDir) { throw "No *.SemanticModel folder found under $ProjectPath" }
$tmdlPath = Join-Path $modelDir "definition\tables\LegacyAvMigration.tmdl"
if (-not (Test-Path -LiteralPath $tmdlPath)) { throw "LegacyAvMigration.tmdl not found: $tmdlPath" }

function Set-SeedLiteral {
    <# Replaces the SeedB64 = "..." literal in LegacyAvMigration.tmdl with the given value, whether
       the current value is the placeholder or a previously materialised base64. Idempotent. #>
    param([string]$Value)
    $raw = Get-Content -LiteralPath $tmdlPath -Raw
    $new = [System.Text.RegularExpressions.Regex]::Replace(
        $raw, 'SeedB64 = "[^"]*"', ('SeedB64 = "' + $Value + '"'))
    Set-Content -LiteralPath $tmdlPath -Value $new -NoNewline -Encoding UTF8
}

if ($RestorePlaceholder) {
    Set-SeedLiteral -Value $PLACEHOLDER
    Write-Ok "LegacyAvMigration.tmdl reset to the empty placeholder."
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
    # New vendor-neutral keys, then the pre-2.x trend* keys for backwards compatibility.
    if (-not $LegacyCsv    -and $cfg.ContainsKey('legacyCsv'))         { $LegacyCsv    = $cfg.legacyCsv }
    if (-not $LegacyCsv    -and $cfg.ContainsKey('trendCsv'))          { $LegacyCsv    = $cfg.trendCsv }
    if (-not $PSBoundParameters.ContainsKey('LegacyMode')) {
        if     ($cfg.ContainsKey('legacyMode')) { $LegacyMode = [string]$cfg.legacyMode }
        elseif ($cfg.ContainsKey('trendMode'))  { $LegacyMode = [string]$cfg.trendMode }
    }
    if (-not $SourceProduct -and $cfg.ContainsKey('legacyProduct'))    { $SourceProduct = $cfg.legacyProduct }
    if (-not $SourceProduct -and $cfg.ContainsKey('trendSource'))      { $SourceProduct = $cfg.trendSource }
    if (-not $SourceVendor  -and $cfg.ContainsKey('legacyVendor'))     { $SourceVendor  = $cfg.legacyVendor }
    if (-not $InventoryStore -and $cfg.ContainsKey('legacyInventoryStore')) { $InventoryStore = $cfg.legacyInventoryStore }
    if (-not $InventoryStore -and $cfg.ContainsKey('trendInventoryStore'))  { $InventoryStore = $cfg.trendInventoryStore }
}

if (-not $LegacyCsv -and $LegacyMode -ne 'Append') {
    throw "No legacy AV/EDR CSV supplied. Pass -LegacyCsv <export.csv> (or set 'legacyCsv' in config.json). Use -RestorePlaceholder to reset the table without a CSV."
}

# ---- resolve the local master store ----------------------------------------
if (-not $InventoryStore) {
    $InventoryStore = Join-Path $PSScriptRoot "legacy-inventory.local.csv"
    # Adopt a pre-2.x Trend-era store when the new one does not exist yet; Read-LegacyStore
    # upgrades its columns in place.
    $legacyStore = Join-Path $PSScriptRoot "trend-inventory.local.csv"
    if (-not (Test-Path -LiteralPath $InventoryStore) -and (Test-Path -LiteralPath $legacyStore)) {
        Write-Warn2 "Using the pre-2.x store '$legacyStore'. It will be upgraded and written to '$InventoryStore'."
        Copy-Item -LiteralPath $legacyStore -Destination $InventoryStore
    }
}

# ---- ingest -----------------------------------------------------------------
Write-Step "Reading legacy AV/EDR export"
$newRecs = @()
if ($LegacyCsv) {
    $newRecs = @(Get-LegacyDeviceRecords -CsvPath $LegacyCsv -SourceProduct $SourceProduct -SourceVendor $SourceVendor)
    if ($newRecs.Count -eq 0) { throw "No device names found in the legacy AV/EDR CSV ($LegacyCsv)." }
}

Write-Step "Merging into master store ($LegacyMode)"
$existing = @(Read-LegacyStore -Path $InventoryStore)
if ($LegacyMode -eq 'Replace' -and $existing.Count -gt 0) {
    $existingProducts = @($existing | ForEach-Object { $_.LegacyProduct } | Select-Object -Unique)
    if ($existingProducts.Count -gt 1 -or ($newRecs.Count -gt 0 -and $existingProducts -notcontains $newRecs[0].LegacyProduct)) {
        Write-Warn2 "-LegacyMode Replace will DISCARD the $($existing.Count) device(s) already ingested from: $($existingProducts -join ', '). Use -LegacyMode Append to add this export alongside them."
    }
}
$records = @(Merge-LegacyStore -Existing $existing -New $newRecs -Mode $LegacyMode)
if ($records.Count -eq 0) { throw "The legacy device list is empty. Supply -LegacyCsv, or an existing store for -LegacyMode Append." }
Write-LegacyStore -Path $InventoryStore -Records $records
$added = $records.Count - $existing.Count
if ($LegacyMode -eq 'Append') { Write-Ok "Master store: $($records.Count) unique devices ($([Math]::Max(0,$added)) new). Store: $InventoryStore" }
else                          { Write-Ok "Master store replaced: $($records.Count) unique devices. Store: $InventoryStore" }

Write-Step "Querying Defender inventory"
$inv = Get-DefenderInventory -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret
Write-Ok "Defender inventory: $($inv.Count) current devices"

Write-Step "Matching legacy AV/EDR -> Defender (hostname exact, domain fuzzy)"
$map = @(Get-LegacyDefenderMapping -LegacyRecords $records -Inventory $inv -MatchThreshold $MatchThreshold)

$total = $map.Count
$migr  = @($map | Where-Object { $_.MigrationStatus -eq "Migrated to Defender" }).Count
$pend  = @($map | Where-Object { $_.MigrationStatus -eq "Matched - not onboarded" }).Count
$miss  = @($map | Where-Object { $_.MigrationStatus -eq "Not found in Defender" }).Count
$fuzz  = @($map | Where-Object { $_.MatchType -eq "Fuzzy" }).Count
$pct   = 0
if ($total -gt 0) { $pct = [math]::Round(100.0 * $migr / $total, 1) }

Write-Host ""
Write-Ok "Legacy AV/EDR devices (unique): $total"
Write-Ok "  Migrated to Defender:      $migr ($pct%)"
Write-Ok "  Matched - not onboarded:   $pend"
Write-Ok "  Not found in Defender:     $miss"
Write-Ok "  (of matched, fuzzy-matched: $fuzz)"

# Per-product view: the reason every row is labelled in the first place.
Write-LegacyProductBreakdown -Records $map

# ---- preview CSV ------------------------------------------------------------
if (-not $OutCsv) { $OutCsv = Join-Path $PSScriptRoot "legacy-migration-mapping.csv" }
$map | Sort-Object LegacyProduct, MigrationStatus, MatchScore |
    Export-Csv -LiteralPath $OutCsv -NoTypeInformation -Encoding UTF8
Write-Ok "Preview mapping written: $OutCsv"

# ---- materialize into the local table ---------------------------------------
if ($Materialize) {
    $seedJson = ConvertTo-LegacyMigrationSeed -Mapping $map
    $seedB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($seedJson))
    Set-SeedLiteral -Value $seedB64
    Write-Ok "LegacyAvMigration.tmdl materialised with $total rows. Open the PBIP in Power BI Desktop or deploy to publish it."
    Write-Warn2 "The .tmdl now contains your device data. Run -RestorePlaceholder before committing this file to source control."
} else {
    Write-Host ""
    Write-Ok "Review $OutCsv, then either re-run with -Materialize to populate the local table, or deploy with:"
    Write-Ok "  .\Deploy-Dashboard.ps1 -ConfigPath <config.json> -WorkspaceId <id> -LegacyCsv `"$LegacyCsv`""
    if ($LegacyCsv) {
        Write-Ok "  To add another AV/EDR product, re-run with: -LegacyCsv <next-export.csv> -LegacyMode Append"
    }
}

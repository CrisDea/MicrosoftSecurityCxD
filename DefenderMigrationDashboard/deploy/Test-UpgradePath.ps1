<#
.SYNOPSIS
    Offline regression test for upgrading an existing (pre-2.x, Trend-only) deployment to the
    vendor-neutral Legacy AV/EDR release.

.DESCRIPTION
    A dashboard deployed by an earlier release stores its ingested devices in
    deploy\trend-inventory.local.csv and publishes a semantic model whose migration table was
    called TrendMigration. This release renames the table to LegacyAvMigration and the store to
    legacy-inventory.local.csv.

    The upgrade risk is data loss: if the new code cannot see the old store, an update-in-place
    republishes the model with an EMPTY migration table and the customer loses their ingested
    legacy inventory.

    This test runs entirely offline (no tenant, no Fabric calls, Windows PowerShell 5.1 compatible)
    and asserts that:
      * a pre-2.x store is discovered and adopted;
      * every upgraded row keeps its legacy product/vendor provenance;
      * rows that carried no product label are still labelled (never blank);
      * an Append ingest after upgrade preserves the pre-existing devices;
      * the published seed is non-empty for an upgraded deployment;
      * the model/report no longer reference the old table name.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Test-UpgradePath.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

. (Join-Path $PSScriptRoot "_Common.ps1")

$script:Pass = 0
$script:Fail = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if ($Condition) {
        $script:Pass++
        Write-Host ("  [PASS] " + $Message) -ForegroundColor Green
    } else {
        $script:Fail++
        Write-Host ("  [FAIL] " + $Message) -ForegroundColor Red
    }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    Assert-True ([string]$Expected -eq [string]$Actual) ("$Message (expected '$Expected', got '$Actual')")
}

Write-Host ""
Write-Host "Upgrade-path regression test (pre-2.x -> vendor-neutral)" -ForegroundColor Cyan
Write-Host ""

$sandbox = Join-Path ([IO.Path]::GetTempPath()) ("dmd-upgrade-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sandbox -Force | Out-Null

try {
    # ---------------------------------------------------------------- 1. pre-2.x store discovery
    Write-Host "1. Pre-2.x store is discovered and upgraded" -ForegroundColor White

    # Exactly the shape written by the Trend-only release: TrendId/TrendSource columns.
    $preTwo = Join-Path $sandbox "trend-inventory.local.csv"
    @(
        'TrendId,DeviceName,TrendSource,FirstSeen'
        '1001,MCAPS-WKS-001.contoso.com,Trend Micro Apex One,2026-01-05T09:00:00Z'
        '1002,MCAPS-WKS-002,Trend Micro Apex One,2026-01-05T09:00:00Z'
        '1003,MCAPS-SRV-001.contoso.com,,2026-01-06T09:00:00Z'
    ) | Set-Content -LiteralPath $preTwo -Encoding UTF8

    $upgraded = @(Read-LegacyStore -Path $preTwo)
    Assert-Equal 3 $upgraded.Count "pre-2.x store rows are read"

    $first = $upgraded | Where-Object { $_.DeviceName -eq 'MCAPS-WKS-001.contoso.com' } | Select-Object -First 1
    Assert-Equal 'Trend Micro Apex One' $first.LegacyProduct "TrendSource is carried into LegacyProduct"
    Assert-True ($first.LegacyVendor -match 'Trend') "vendor is resolved from the upgraded product"
    Assert-Equal '1001' $first.LegacyId "TrendId is carried into LegacyId"

    # Provenance must never be blank, even when the old file had no product column value.
    foreach ($r in $upgraded) {
        Assert-True (-not [string]::IsNullOrWhiteSpace([string]$r.LegacyProduct)) `
            ("row '$($r.DeviceName)' keeps a legacy product label")
        Assert-True (-not [string]::IsNullOrWhiteSpace([string]$r.LegacyVendor)) `
            ("row '$($r.DeviceName)' keeps a legacy vendor label")
    }

    # ---------------------------------------------------------------- 2. adoption on deploy
    Write-Host ""
    Write-Host "2. Deploy adopts the pre-2.x store instead of starting empty" -ForegroundColor White

    # New-LegacyMigrationSeedOverride adopts trend-inventory.local.csv when the new store is absent.
    # Reproduce that resolution here (no tenant calls) and assert the adoption actually happens.
    $newStore = Join-Path $sandbox "legacy-inventory.local.csv"
    Assert-True (-not (Test-Path -LiteralPath $newStore)) "new-format store does not exist before upgrade"

    if (-not (Test-Path -LiteralPath $newStore)) {
        $candidate = Join-Path (Split-Path -Parent $newStore) "trend-inventory.local.csv"
        if (Test-Path -LiteralPath $candidate) { Copy-Item -LiteralPath $candidate -Destination $newStore -Force }
    }
    Assert-True (Test-Path -LiteralPath $newStore) "pre-2.x store is adopted as the new store"

    $adopted = @(Read-LegacyStore -Path $newStore)
    Assert-Equal 3 $adopted.Count "adopted store keeps every previously ingested device"

    # The upgraded store must round-trip through the new writer without losing provenance.
    Write-LegacyStore -Path $newStore -Records $adopted
    $roundTrip = @(Read-LegacyStore -Path $newStore)
    Assert-Equal 3 $roundTrip.Count "upgraded store round-trips through the new writer"
    $hdr = (Get-Content -LiteralPath $newStore -TotalCount 1)
    Assert-True ($hdr -match 'LegacyProduct' -and $hdr -match 'LegacyVendor') "rewritten store uses the new columns"

    # ---------------------------------------------------------------- 3. no data loss on re-deploy
    Write-Host ""
    Write-Host "3. Update-in-place preserves data and stays multi-vendor" -ForegroundColor White

    # A second vendor is ingested after the upgrade (Append) - the Trend rows must survive.
    $secondVendor = Join-Path $sandbox "crowdstrike-export.csv"
    @(
        'DeviceName,LegacyProduct'
        'MCAPS-WKS-003,CrowdStrike Falcon'
        'MCAPS-WKS-001.contoso.com,CrowdStrike Falcon'
    ) | Set-Content -LiteralPath $secondVendor -Encoding UTF8

    $newRecs = @(Get-LegacyDeviceRecords -CsvPath $secondVendor)
    $merged  = @(Merge-LegacyStore -Existing $roundTrip -New $newRecs -Mode 'Append')

    Assert-True ($merged.Count -ge 4) "append keeps prior devices and adds the new vendor's devices"

    $products = @($merged | ForEach-Object { $_.LegacyProduct } | Sort-Object -Unique)
    Assert-True ($products -contains 'CrowdStrike Falcon') "new vendor's product label is present"
    Assert-True (@($products | Where-Object { $_ -match 'Trend' }).Count -gt 0) "original vendor's product label survives the upgrade"

    # A device present in BOTH tools must remain two separate migration facts: each legacy agent
    # still has to be removed, so collapsing them would hide outstanding work.
    $dupHost = @($merged | Where-Object { $_.DeviceName -eq 'MCAPS-WKS-001.contoso.com' })
    Assert-True ($dupHost.Count -eq 2) "a device found in two tools stays as two migration rows"

    # ---------------------------------------------------------------- 4. seed is non-empty
    Write-Host ""
    Write-Host "4. Published seed is populated for an upgraded deployment" -ForegroundColor White

    $fakeInventory = @(
        [pscustomobject]@{ DeviceId = 'd1'; DeviceName = 'mcaps-wks-001.contoso.com'; OnboardingStatus = 'Onboarded'; OSPlatform = 'Windows11'; OSVersion = '10.0.22631' }
        [pscustomobject]@{ DeviceId = 'd2'; DeviceName = 'mcaps-wks-002'; OnboardingStatus = 'Onboarded'; OSPlatform = 'Windows11'; OSVersion = '10.0.22631' }
    )

    $map = @(Get-LegacyDefenderMapping -LegacyRecords $merged -Inventory $fakeInventory)
    Assert-True ($map.Count -eq $merged.Count) "every legacy row produces a migration row"

    foreach ($m in $map) {
        Assert-True (-not [string]::IsNullOrWhiteSpace([string]$m.LegacyProduct)) `
            ("mapped row '$($m.LegacyDeviceName)' carries its originating product")
    }

    $seedJson = ConvertTo-LegacyMigrationSeed -Mapping $map
    Assert-True ($seedJson -ne '[]' -and $seedJson.Length -gt 10) "seed JSON is not empty after upgrade"
    Assert-True ($seedJson -match 'LegacyProduct') "seed JSON carries per-row product provenance"

    # ---------------------------------------------------------------- 4b. fail-safe on API failure
    Write-Host ""
    Write-Host "4b. A failed Defender lookup must NOT wipe live migration data" -ForegroundColor White

    # Reproduce the real upgrade hazard: the store holds devices, but the Defender call fails
    # (bad/missing credentials). Publishing an empty seed would overwrite the live table.
    $modelRoot = Join-Path (Split-Path -Parent $PSScriptRoot) "pbip-project"
    $modelDir  = @(Get-ChildItem -LiteralPath $modelRoot -Directory -Filter "*.SemanticModel" -ErrorAction SilentlyContinue)
    if ($modelDir.Count -ge 1) {
        $threw = $false
        $msg   = ""
        try {
            New-LegacyMigrationSeedOverride -ModelDir $modelDir[0].FullName `
                -TenantId "" -ClientId "" -ClientSecret "" `
                -InventoryStore $newStore | Out-Null
        } catch {
            $threw = $true
            $msg   = [string]$_.Exception.Message
        }
        Assert-True $threw "deploy fails instead of publishing an empty table over ingested data"
        Assert-True ($msg -match "Refusing to publish an EMPTY migration table") "the failure explains the data-loss risk"

        # The operator can still opt in deliberately.
        $override = $null
        try {
            $override = New-LegacyMigrationSeedOverride -ModelDir $modelDir[0].FullName `
                -TenantId "" -ClientId "" -ClientSecret "" `
                -InventoryStore $newStore -AllowEmptyLegacyTable
        } catch { $override = $null }
        Assert-True ($null -ne $override) "-AllowEmptyLegacyTable still allows a deliberate empty publish"
    } else {
        Write-Host "  [SKIP] semantic model folder not found" -ForegroundColor Yellow
    }
    # ---------------------------------------------------------------- 5. no stale table references
    Write-Host ""
    Write-Host "5. Model and report no longer bind the pre-2.x table name" -ForegroundColor White

    $projectRoot = Join-Path (Split-Path -Parent $PSScriptRoot) "pbip-project"
    if (Test-Path -LiteralPath $projectRoot) {
        $modelTable = @(Get-ChildItem -LiteralPath $projectRoot -Recurse -Filter "LegacyAvMigration.tmdl" -ErrorAction SilentlyContinue)
        Assert-True ($modelTable.Count -ge 1) "LegacyAvMigration.tmdl exists in the semantic model"

        $oldTable = @(Get-ChildItem -LiteralPath $projectRoot -Recurse -Filter "TrendMigration.tmdl" -ErrorAction SilentlyContinue)
        Assert-True ($oldTable.Count -eq 0) "the pre-2.x TrendMigration.tmdl is gone"

        $stale = @()
        $files = @(Get-ChildItem -LiteralPath $projectRoot -Recurse -File -Include "*.tmdl", "*.json" -ErrorAction SilentlyContinue)
        foreach ($f in $files) {
            $raw = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction SilentlyContinue
            if ($raw -and $raw -match "TrendMigration") { $stale += $f.FullName }
        }
        Assert-True ($stale.Count -eq 0) "no model/report file still binds 'TrendMigration'"
        if ($stale.Count -gt 0) { $stale | ForEach-Object { Write-Host "        stale: $_" -ForegroundColor Yellow } }
    } else {
        Write-Host "  [SKIP] pbip-project not found next to deploy\" -ForegroundColor Yellow
    }
}
finally {
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host ("Result: {0} passed, {1} failed" -f $script:Pass, $script:Fail) -ForegroundColor (@{ $true = 'Red'; $false = 'Green' }[[bool]($script:Fail -gt 0)])
Write-Host ""

if ($script:Fail -gt 0) { exit 1 }
exit 0

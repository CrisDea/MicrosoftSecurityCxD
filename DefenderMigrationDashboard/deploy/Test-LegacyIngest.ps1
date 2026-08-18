# Smoke test for the vendor-neutral legacy AV/EDR ingest engine (run under Windows PowerShell 5.1).
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\_Common.ps1"

$tmp = Join-Path $env:TEMP ("avtest-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$fail = 0
function Assert($cond, $msg) {
    if ($cond) { Write-Host "  PASS $msg" -ForegroundColor Green }
    else { Write-Host "  FAIL $msg" -ForegroundColor Red; $script:fail++ }
}

Write-Host "PowerShell $($PSVersionTable.PSVersion)"

# --- 1. Trend Micro Apex One style export
$apex = Join-Path $tmp 'apex.csv'
@"
Endpoint,GUID,Scan Method,IP Address
WKS-001.contoso.com,{AAA-111},Smart Scan,10.0.0.1
WKS-002.contoso.com,{AAA-222},Smart Scan,10.0.0.2
"@ | Set-Content $apex -Encoding UTF8
$r1 = @(Get-LegacyDeviceRecords -CsvPath $apex)
Assert ($r1.Count -eq 2) "Apex One: 2 rows"
Assert ($r1[0].LegacyProduct -eq 'Trend Micro Apex One') "Apex One auto-detected (got '$($r1[0].LegacyProduct)')"
Assert ($r1[0].LegacyVendor -eq 'Trend Micro') "Apex One vendor = Trend Micro"
Assert ($r1[0].LegacyId -eq '{AAA-111}') "Apex One id column picked"
Assert (@($r1 | Where-Object { [string]::IsNullOrWhiteSpace($_.LegacyProduct) }).Count -eq 0) "every Apex row labelled"

# --- 2. CrowdStrike Falcon style export
$cs = Join-Path $tmp 'falcon.csv'
@"
Hostname,aid,cid,Reduced Functionality Mode,Agent Version
SRV-010.contoso.com,abc123,cid9,No,7.11
SRV-011.fabrikam.local,abc124,cid9,No,7.11
"@ | Set-Content $cs -Encoding UTF8
$r2 = @(Get-LegacyDeviceRecords -CsvPath $cs)
Assert ($r2[0].LegacyProduct -eq 'CrowdStrike Falcon') "Falcon auto-detected (got '$($r2[0].LegacyProduct)')"
Assert ($r2[0].LegacyId -eq 'abc123') "Falcon aid used as id"

# --- 3. Symantec style export
$sep = Join-Path $tmp 'sep.csv'
@"
Computer Name,Computer ID,SEP Version,Group
LAP-500,CID-500,14.3,Default
"@ | Set-Content $sep -Encoding UTF8
$r3 = @(Get-LegacyDeviceRecords -CsvPath $sep)
Assert ($r3[0].LegacyProduct -eq 'Symantec Endpoint Protection') "SEP auto-detected (got '$($r3[0].LegacyProduct)')"
Assert ($r3[0].LegacyVendor -eq 'Broadcom') "SEP vendor = Broadcom"

# --- 4. Unknown vendor still ingests with a label
$unk = Join-Path $tmp 'unknown.csv'
@"
Machine,Serial
BOX-1,S1
"@ | Set-Content $unk -Encoding UTF8
$r4 = @(Get-LegacyDeviceRecords -CsvPath $unk)
Assert ($r4[0].LegacyProduct -eq 'Legacy AV/EDR') "unknown vendor gets neutral label"
$r4b = @(Get-LegacyDeviceRecords -CsvPath $unk -SourceProduct 'Contoso Guard')
Assert ($r4b[0].LegacyProduct -eq 'Contoso Guard') "-SourceProduct override honoured"

# --- 5. Multi-product Append: labels must survive the merge
$store = Join-Path $tmp 'store.csv'
$m1 = Merge-LegacyStore -Existing @() -New $r1 -Mode 'Replace'
Write-LegacyStore -Path $store -Records $m1
$back = Read-LegacyStore -Path $store
$m2 = Merge-LegacyStore -Existing $back -New $r2 -Mode 'Append'
$m3 = Merge-LegacyStore -Existing $m2 -New $r3 -Mode 'Append'
Assert ($m3.Count -eq 5) "3 products merged -> 5 devices (got $($m3.Count))"
$prods = @($m3 | ForEach-Object { $_.LegacyProduct } | Select-Object -Unique)
Assert ($prods.Count -eq 3) "3 distinct product labels retained (got $($prods -join '; '))"
Assert (@($m3 | Where-Object { [string]::IsNullOrWhiteSpace($_.LegacyProduct) }).Count -eq 0) "EVERY merged row carries its product"

# --- 6. Round-trip through the CSV store keeps labels
Write-LegacyStore -Path $store -Records $m3
$rt = Read-LegacyStore -Path $store
Assert ($rt.Count -eq 5) "store round-trip keeps 5 rows"
Assert ((@($rt | ForEach-Object { $_.LegacyProduct } | Select-Object -Unique)).Count -eq 3) "store round-trip keeps 3 labels"

# --- 7. Backwards compatibility with an old Trend-only store
$old = Join-Path $tmp 'old-trend.csv'
@"
TrendId,DeviceName,TrendSource,FirstSeen
{OLD-1},LEGACY-01.contoso.com,Apex One,2024-01-01
"@ | Set-Content $old -Encoding UTF8
$r7 = @(Read-LegacyStore -Path $old)
Assert ($r7[0].LegacyProduct -eq 'Apex One') "old TrendSource column upgraded to LegacyProduct"
Assert ($r7[0].LegacyId -eq '{OLD-1}') "old TrendId column upgraded to LegacyId"
Assert ($r7[0].FirstSeen -eq '2024-01-01') "old FirstSeen preserved"

# --- 8. Matching keeps the product on every mapped row
$inv = @(
    [pscustomobject]@{ DeviceId='d1'; DeviceName='wks-001.contoso.com'; OnboardingStatus='Onboarded'; OSPlatform='Windows11'; OSVersion='23H2' }
    [pscustomobject]@{ DeviceId='d2'; DeviceName='srv-010.contoso.local'; OnboardingStatus='Onboarded'; OSPlatform='WindowsServer2022'; OSVersion='21H2' }
    [pscustomobject]@{ DeviceId='d3'; DeviceName='lap-500'; OnboardingStatus='Can be onboarded'; OSPlatform='Windows10'; OSVersion='22H2' }
)
# 'contoso.com' vs 'contoso.local' scores ~69%, so the default 82 threshold rejects it by design.
# Drop to 65 here to exercise the fuzzy-domain path; hostnames must still match exactly.
$map = @(Get-LegacyDefenderMapping -LegacyRecords $m3 -Inventory $inv -MatchThreshold 65)
$strict = @(Get-LegacyDefenderMapping -LegacyRecords $m3 -Inventory $inv -MatchThreshold 82)
$srvStrict = $strict | Where-Object { $_.LegacyDeviceName -like 'SRV-010*' }
Assert ($srvStrict.MigrationStatus -eq 'Not found in Defender') "default threshold 82 rejects the weak domain match"
Assert ($map.Count -eq 5) "mapping returns 5 rows"
Assert (@($map | Where-Object { [string]::IsNullOrWhiteSpace($_.LegacyProduct) }).Count -eq 0) "EVERY mapped row carries its product"
Assert (@($map | Where-Object { [string]::IsNullOrWhiteSpace($_.LegacyVendor) }).Count -eq 0) "EVERY mapped row carries its vendor"
$wks = $map | Where-Object { $_.LegacyDeviceName -like 'WKS-001*' }
Assert ($wks.MigrationStatus -eq 'Migrated to Defender') "exact host match -> migrated"
Assert ($wks.LegacyProduct -eq 'Trend Micro Apex One') "migrated row keeps Apex One label"
$srv = $map | Where-Object { $_.LegacyDeviceName -like 'SRV-010*' }
Assert ($srv.MigrationStatus -eq 'Migrated to Defender') "fuzzy domain (contoso.com vs contoso.local) matched"
Assert ($srv.MatchType -eq 'Fuzzy') "fuzzy match flagged as Fuzzy"
$lap = $map | Where-Object { $_.LegacyDeviceName -eq 'LAP-500' }
Assert ($lap.MigrationStatus -eq 'Matched - not onboarded') "matched but not onboarded"
$miss = $map | Where-Object { $_.LegacyDeviceName -like 'SRV-011*' }
Assert ($miss.MigrationStatus -eq 'Not found in Defender') "unmatched -> not found"

# --- 9. Different hostnames must never fuzzy-match each other
$inv2 = @([pscustomobject]@{ DeviceId='x'; DeviceName='wks-009.contoso.com'; OnboardingStatus='Onboarded'; OSPlatform='Windows11'; OSVersion='23H2' })
$map2 = @(Get-LegacyDefenderMapping -LegacyRecords $r1 -Inventory $inv2 -MatchThreshold 50)
Assert (@($map2 | Where-Object { $_.MigrationStatus -ne 'Not found in Defender' }).Count -eq 0) "WKS-001/002 never fuzzy-match WKS-009"

# --- 10. Breakdown reporting
$bd = @(Get-LegacyProductBreakdown -Records $map)
Assert ($bd.Count -eq 3) "breakdown lists 3 products"
Assert ((($bd | Measure-Object -Property Devices -Sum).Sum) -eq 5) "breakdown device counts sum to 5"
Assert ((($bd | Measure-Object -Property Migrated -Sum).Sum) -eq 2) "breakdown migrated counts sum to 2"

# --- 11. Seed serialisation
$seed = ConvertTo-LegacyMigrationSeed -Mapping $map
$parsed = $seed | ConvertFrom-Json
Assert (@($parsed).Count -eq 5) "seed JSON round-trips 5 records"
Assert ($null -ne $parsed[0].LegacyProduct) "seed JSON carries LegacyProduct"
Assert ((ConvertTo-LegacyMigrationSeed -Mapping @()) -eq '[]') "empty mapping -> []"
$one = ConvertTo-LegacyMigrationSeed -Mapping @($map[0])
Assert ((@($one | ConvertFrom-Json)).Count -eq 1) "single record stays an array"

# --- 12. Backwards-compatible aliases still resolve
Assert ($null -ne (Get-Command Read-TrendStore -ErrorAction SilentlyContinue)) "Read-TrendStore alias present"
Assert ($null -ne (Get-Command Get-TrendDedupKey -ErrorAction SilentlyContinue)) "Get-TrendDedupKey alias present"

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
Write-Host ""
if ($fail -eq 0) { Write-Host "ALL TESTS PASSED" -ForegroundColor Green; exit 0 }
else { Write-Host "$fail TEST(S) FAILED" -ForegroundColor Red; exit 1 }

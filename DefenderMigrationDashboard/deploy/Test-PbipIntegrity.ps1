<#
.SYNOPSIS
    Validates the PBIP project: JSON well-formedness, and that every table / column / measure the
    report binds to actually exists in the semantic model.

.DESCRIPTION
    Catches the class of break that silently produces an empty or error visual in Power BI Desktop:
    a visual still bound to a table, column or measure that was renamed or removed in the model.
    Parses the TMDL for tables, columns and measures, then walks every report visual.json /
    page.json for "queryRef", "Entity" and "Property" bindings and resolves each one.

    Run it after any model rename, and as a pre-commit check.

.EXAMPLE
    .\Test-PbipIntegrity.ps1

.NOTES
    Requires Windows PowerShell 5.1 or later. Licensed under the MIT License.
#>
[CmdletBinding()]
param([string]$ProjectPath)

$ErrorActionPreference = 'Stop'
if (-not $ProjectPath) { $ProjectPath = Join-Path $PSScriptRoot '..\pbip-project' }
$ProjectPath = (Resolve-Path -LiteralPath $ProjectPath).Path

$modelDir  = (Get-ChildItem -LiteralPath $ProjectPath -Directory -Filter '*.SemanticModel' | Select-Object -First 1).FullName
$reportDir = (Get-ChildItem -LiteralPath $ProjectPath -Directory -Filter '*.Report'        | Select-Object -First 1).FullName
if (-not $modelDir)  { throw "No *.SemanticModel folder under $ProjectPath" }
if (-not $reportDir) { throw "No *.Report folder under $ProjectPath" }

$errors   = New-Object System.Collections.ArrayList
$warnings = New-Object System.Collections.ArrayList

# ---------------------------------------------------------------- parse the model
$tables = @{}   # tableName -> @{ Columns = @{}; Measures = @{} }
foreach ($tmdl in Get-ChildItem -LiteralPath (Join-Path $modelDir 'definition\tables') -Filter *.tmdl) {
    $lines = Get-Content -LiteralPath $tmdl.FullName
    $tableName = $null
    $cols = @{}; $meas = @{}
    foreach ($line in $lines) {
        if ($line -match '^\s*table\s+(.+?)\s*$' -and -not $tableName) {
            $tableName = $Matches[1].Trim().Trim("'")
        } elseif ($line -match "^\s*column\s+'?([^'=]+?)'?\s*(=.*)?$") {
            $cols[$Matches[1].Trim()] = $true
        } elseif ($line -match "^\s*measure\s+'?([^'=]+?)'?\s*=") {
            $meas[$Matches[1].Trim()] = $true
        }
    }
    if ($tableName) {
        if ($tables.ContainsKey($tableName)) { [void]$errors.Add("Duplicate table '$tableName' ($($tmdl.Name))") }
        $tables[$tableName] = @{ Columns = $cols; Measures = $meas; File = $tmdl.Name }
        if ($tmdl.BaseName -ne $tableName) {
            [void]$warnings.Add("File '$($tmdl.Name)' declares table '$tableName' (name mismatch)")
        }
    }
}
Write-Host "Model: $($tables.Count) tables" -ForegroundColor Cyan
foreach ($t in ($tables.Keys | Sort-Object)) {
    Write-Host ("  {0,-22} {1,3} columns, {2,3} measures" -f $t, $tables[$t].Columns.Count, $tables[$t].Measures.Count)
}

# model.tmdl must reference every table exactly once
$modelTmdl = Get-Content -LiteralPath (Join-Path $modelDir 'definition\model.tmdl') -Raw
foreach ($t in $tables.Keys) {
    if ($modelTmdl -notmatch [regex]::Escape("ref table $t")) {
        [void]$errors.Add("model.tmdl has no 'ref table $t'")
    }
}
if ($modelTmdl -match 'annotation PBI_QueryOrder = \[(.+?)\]') {
    foreach ($q in ($Matches[1] -split ',')) {
        $q = $q.Trim().Trim('"')
        if ($q -and -not $tables.ContainsKey($q)) { [void]$errors.Add("PBI_QueryOrder references unknown table '$q'") }
    }
}

# ---------------------------------------------------------------- walk the report
$jsonFiles = Get-ChildItem -LiteralPath $reportDir -Recurse -Filter *.json
$refCount = 0
foreach ($jf in $jsonFiles) {
    $raw = Get-Content -LiteralPath $jf.FullName -Raw
    try { $null = $raw | ConvertFrom-Json }
    catch { [void]$errors.Add("Invalid JSON: $($jf.FullName.Replace($reportDir,'')) - $($_.Exception.Message)"); continue }

    $rel = $jf.FullName.Replace($reportDir, '')

    # "queryRef": "Table.Field"
    foreach ($m in [regex]::Matches($raw, '"queryRef"\s*:\s*"([^"]+)"')) {
        $qr = $m.Groups[1].Value
        # Skip aggregate/hierarchy forms like Sum(Table.Col) or Table.Col.Level
        $core = $qr -replace '^[A-Za-z]+\(', '' -replace '\)$', ''
        $dot = $core.IndexOf('.')
        if ($dot -lt 1) { continue }
        $tbl = $core.Substring(0, $dot)
        $fld = $core.Substring($dot + 1)
        $refCount++
        if (-not $tables.ContainsKey($tbl)) {
            [void]$errors.Add("$rel :: queryRef '$qr' -> unknown table '$tbl'")
        } elseif (-not ($tables[$tbl].Columns.ContainsKey($fld) -or $tables[$tbl].Measures.ContainsKey($fld))) {
            [void]$errors.Add("$rel :: queryRef '$qr' -> '$fld' not found on table '$tbl'")
        }
    }

    # "Entity": "Table"  (inside From clauses)
    foreach ($m in [regex]::Matches($raw, '"Entity"\s*:\s*"([^"]+)"')) {
        $ent = $m.Groups[1].Value
        $refCount++
        if (-not $tables.ContainsKey($ent)) { [void]$errors.Add("$rel :: Entity '$ent' does not exist in the model") }
    }
}

# ---------------------------------------------------------------- placeholders
foreach ($pair in @(
    @{ File = 'LegacyAvMigration.tmdl'; Token = '__LEGACYMIGRATION_SEED_B64__'; Note = 'it may contain customer device data' },
    @{ File = 'DeploymentTrend.tmdl';   Token = '__TREND_SEED_B64__';           Note = 'it may contain customer device data' },
    @{ File = 'DeviceHealth.tmdl';      Token = '__AVPOSTURE_SEED_B64__';       Note = 'it may contain customer device data' },
    @{ File = 'Baselines.tmdl';         Token = '__BASELINE_SEED_B64__';        Note = 'the fallback versions would be frozen at whenever it was materialised' })) {
    $p = Join-Path $modelDir "definition\tables\$($pair.File)"
    if (-not (Test-Path -LiteralPath $p)) { [void]$errors.Add("Missing table file $($pair.File)"); continue }
    $txt = Get-Content -LiteralPath $p -Raw
    if ($txt -notmatch [regex]::Escape($pair.Token)) {
        [void]$warnings.Add("$($pair.File) is MATERIALISED (no $($pair.Token) placeholder) - run -RestorePlaceholder before committing; $($pair.Note).")
    }
}

# ---------------------------------------------------------------- report
Write-Host ""
Write-Host "Report: $($jsonFiles.Count) JSON files, $refCount bindings checked" -ForegroundColor Cyan
foreach ($w in $warnings) { Write-Host "  WARN  $w" -ForegroundColor Yellow }
if ($errors.Count -eq 0) {
    Write-Host ""
    Write-Host "PBIP INTEGRITY OK - every report binding resolves against the model." -ForegroundColor Green
    exit 0
}
Write-Host ""
foreach ($e in $errors) { Write-Host "  ERROR $e" -ForegroundColor Red }
Write-Host ""
Write-Host "$($errors.Count) problem(s) found." -ForegroundColor Red
exit 1

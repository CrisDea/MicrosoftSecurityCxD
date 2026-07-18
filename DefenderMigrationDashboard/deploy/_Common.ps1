<#
  _Common.ps1 - shared helpers for the Defender Migration Dashboard deployment scripts.

  The deploy, remove and export scripts dot-source this file so they share one copy of the
  sign-in, REST and workspace logic:

      . "$PSScriptRoot\_Common.ps1"

  What's in here:
    * Console logging helpers (Write-Step / Write-Ok / Write-Warn2 / Write-Err)
    * Sign-in and access tokens (service principal or Azure CLI), cached and refreshed as needed
    * A single REST wrapper that retries when the service is briefly busy and waits for
      long-running operations to finish
    * Prerequisite checks, and helpers for finding, creating, publishing and removing items

  The scripts are safe to run more than once - they update what already exists rather than
  creating duplicates.
#>

Set-StrictMode -Version Latest

# --------------------------------------------------------------------- endpoints
$script:FabricBase  = "https://api.fabric.microsoft.com/v1"
$script:FabricRes   = "https://api.fabric.microsoft.com"
$script:PowerBIRes  = "https://analysis.windows.net/powerbi/api"
$script:PowerBIBase = "https://api.powerbi.com/v1.0/myorg"

# --------------------------------------------------------------------- logging
function Write-Step($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok($m)   { Write-Host "    $m" -ForegroundColor Green }
function Write-Warn2($m){ Write-Host "    $m" -ForegroundColor Yellow }
function Write-Err($m)  { Write-Host "    $m" -ForegroundColor Red }

# --------------------------------------------------------------------- config + auth state
$script:Auth = @{ UseSP = $false; ClientId = $null; ClientSecret = $null; TenantId = $null }
$script:TokenCache = @{}

function Import-DeployConfig {
    <# Reads a config.json (if any) and returns a hashtable of settings. Never throws on a
       missing file - returns an empty hashtable so callers can merge defensively. #>
    param([string]$ConfigPath)
    if (-not $ConfigPath) { return @{} }
    if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "ConfigPath not found: $ConfigPath" }
    try { $cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json }
    catch { throw "config.json at '$ConfigPath' is not valid JSON: $($_.Exception.Message)" }
    $h = @{}
    foreach ($p in $cfg.PSObject.Properties) { if ($p.Value) { $h[$p.Name] = $p.Value } }
    return $h
}

function Initialize-Auth {
    param([string]$ClientId, [string]$ClientSecret, [string]$TenantId)
    $script:Auth.ClientId     = $ClientId
    $script:Auth.ClientSecret = $ClientSecret
    $script:Auth.TenantId     = $TenantId
    $script:Auth.UseSP        = [bool]($ClientId -and $ClientSecret -and $TenantId)
    $script:TokenCache = @{}
}

function Get-Token {
    <# Returns a bearer token for the given resource, cached until ~5 min before expiry.
       -Force bypasses the cache (used after a 401). Works for both SP and az. #>
    param([Parameter(Mandatory)][string]$Resource, [switch]$Force)
    $now = Get-Date
    if (-not $Force -and $script:TokenCache.ContainsKey($Resource)) {
        $e = $script:TokenCache[$Resource]
        if ($e.exp -gt $now.AddMinutes(5)) { return $e.token }
    }
    if ($script:Auth.UseSP) {
        $body = @{ client_id = $script:Auth.ClientId; client_secret = $script:Auth.ClientSecret
                   grant_type = "client_credentials"; scope = "$Resource/.default" }
        try {
            $r = Invoke-RestMethod -Method POST -ContentType "application/x-www-form-urlencoded" `
                    -Uri "https://login.microsoftonline.com/$($script:Auth.TenantId)/oauth2/v2.0/token" -Body $body
        } catch {
            throw "Service-principal token request failed for $Resource. Verify the app id/secret, that the secret has not expired, and that admin consent was granted. ($($_.Exception.Message))"
        }
        $tok = $r.access_token
        $exp = $now.AddSeconds([int]$r.expires_in)
    } else {
        $raw = az account get-access-token --resource $Resource -o json 2>$null
        if (-not $raw) { throw "Could not acquire an Azure CLI token for $Resource. Run 'az login' (or pass -ConfigPath / -ClientId -ClientSecret -TenantId for service-principal auth)." }
        $j = $raw | ConvertFrom-Json
        $tok = $j.accessToken
        try { $exp = [datetime]$j.expiresOn } catch { $exp = $now.AddMinutes(45) }
    }
    $script:TokenCache[$Resource] = @{ token = $tok; exp = $exp }
    return $tok
}

function _Parse-HttpError($err) {
    $code = 0; $body = $null; $ra = $null
    $resp = $null
    try { $resp = $err.Exception.Response } catch {}
    if ($resp) {
        try { $code = [int]$resp.StatusCode } catch {}
        if ($code -eq 0) { try { $code = [int]$resp.StatusCode.value__ } catch {} }
        try { $ra = $resp.Headers['Retry-After'] } catch {}
        if (-not $ra) { try { $ra = $resp.Headers.RetryAfter.Delta.TotalSeconds } catch {} }
    }
    if ($err.ErrorDetails -and $err.ErrorDetails.Message) { $body = $err.ErrorDetails.Message }
    elseif ($resp) {
        try { $s = $resp.GetResponseStream(); $sr = New-Object IO.StreamReader($s); $body = $sr.ReadToEnd() } catch {}
    }
    return @{ Code = $code; Body = $body; RetryAfter = $ra }
}

function Invoke-Http {
    <# Makes a REST call and returns the parsed JSON response.
       If the service is briefly busy (429 or a 5xx) or the network hiccups, it waits and tries
       again a few times. It refreshes the token once if it has expired, gives a clear message if
       access is denied, and waits for long-running operations to finish before returning. #>
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Url,
        $Body,
        [string]$Resource = $script:FabricRes,
        [switch]$AllowNotFound,
        [int]$MaxAttempts = 6,
        [int]$LroTimeoutSec = 600
    )
    $json = $null
    if ($null -ne $Body) { $json = ($Body | ConvertTo-Json -Depth 40 -Compress) }
    $attempt = 0
    while ($true) {
        $attempt++
        $tok = Get-Token -Resource $Resource
        $headers = @{ Authorization = "Bearer $tok" }
        try {
            $resp = Invoke-WebRequest -Method $Method -Uri $Url -Headers $headers `
                        -ContentType "application/json" -Body $json -UseBasicParsing -ErrorAction Stop
        } catch {
            $e = _Parse-HttpError $_
            if ($e.Code -eq 404 -and $AllowNotFound) { return $null }
            if ($e.Code -eq 401 -and $attempt -le 2) {
                Write-Warn2 "Token rejected (401) - refreshing and retrying."
                Get-Token -Resource $Resource -Force | Out-Null
                continue
            }
            if ($e.Code -eq 403) {
                throw "Access denied (403) on $Method $Url.`n" +
                      "    Fix: ensure the identity is an Admin/Member of the target workspace. For a service principal, also enable the tenant setting 'Service principals can use Fabric APIs' and include the app.`n" +
                      "    Detail: $($e.Body)"
            }
            $transient = ($e.Code -in 408,429,500,502,503,504) -or ($e.Code -eq 0)
            if ($transient -and $attempt -lt $MaxAttempts) {
                $wait = if ($e.RetryAfter) { [int]$e.RetryAfter } else { [Math]::Min(30, [Math]::Pow(2, $attempt)) }
                Write-Warn2 "Transient error ($($e.Code)) on $Method. Retry $attempt/$MaxAttempts in ${wait}s."
                Start-Sleep -Seconds $wait
                continue
            }
            throw "HTTP $($e.Code) on $Method $Url. $($e.Body)"
        }

        # ---- long-running operation ----
        if ([int]$resp.StatusCode -eq 202) {
            $loc = $resp.Headers["Location"]; if ($loc -is [array]) { $loc = $loc[0] }
            if (-not $loc) { return $null }
            $deadline = (Get-Date).AddSeconds($LroTimeoutSec)
            $interval = 3
            try { $ra = $resp.Headers["Retry-After"]; if ($ra) { $interval = [int]$ra } } catch {}
            while ((Get-Date) -lt $deadline) {
                Start-Sleep -Seconds $interval
                try {
                    $ptok = Get-Token -Resource $Resource
                    $poll = Invoke-WebRequest -Method GET -Uri $loc -Headers @{ Authorization = "Bearer $ptok" } -UseBasicParsing -ErrorAction Stop
                } catch {
                    $pe = _Parse-HttpError $_
                    if ($pe.Code -in 429,500,502,503,504,0) { continue }  # keep polling on transient
                    throw "Polling failed: HTTP $($pe.Code). $($pe.Body)"
                }
                try { $ra = $poll.Headers["Retry-After"]; if ($ra) { $interval = [int]$ra } } catch {}
                $pj = $poll.Content | ConvertFrom-Json
                if ($pj.status -in @("Succeeded","Completed")) {
                    try {
                        $res = Invoke-WebRequest -Method GET -Uri "$loc/result" -Headers @{ Authorization = "Bearer $(Get-Token -Resource $Resource)" } -UseBasicParsing -ErrorAction Stop
                        return ($res.Content | ConvertFrom-Json)
                    } catch { return $pj }
                }
                if ($pj.status -in @("Failed","Cancelled")) { throw "Operation $($pj.status): $($poll.Content)" }
            }
            throw "Operation timed out after ${LroTimeoutSec}s ($Method $Url)."
        }

        if ($resp.Content) { try { return ($resp.Content | ConvertFrom-Json) } catch { return $resp.Content } }
        return $null
    }
}

# --------------------------------------------------------------------- preflight
function Test-Prereqs {
    param([string]$ProjectPath, [hashtable]$Cfg, [switch]$SkipGitHubRestore)
    Write-Step "Preflight checks"
    if ($PSVersionTable.PSVersion.Major -lt 5) { throw "PowerShell 5.1 or later is required (found $($PSVersionTable.PSVersion))." }
    Write-Ok "PowerShell $($PSVersionTable.PSVersion)"

    if (-not $script:Auth.UseSP) {
        if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
            throw "Azure CLI (az) was not found on PATH. Install it from https://aka.ms/installazurecli, or use service-principal auth via -ConfigPath / -ClientId -ClientSecret -TenantId."
        }
        Write-Ok "Azure CLI present"
    } else {
        Write-Ok "Service-principal auth configured"
    }

    if ($ProjectPath) {
        if (-not (Test-Path -LiteralPath $ProjectPath)) { throw "PBIP project not found at '$ProjectPath'." }
        $dashRoot = Split-Path -Parent $PSScriptRoot
        $issues = @(Test-ProjectIntegrity -ProjectPath $ProjectPath)
        if ($issues.Count -gt 0 -and -not $SkipGitHubRestore) {
            Write-Warn2 "Local content is incomplete or invalid ($($issues.Count) problem(s)) - attempting to re-download it from GitHub..."
            foreach ($i in $issues) { Write-Host "    - $i" -ForegroundColor DarkYellow }
            if (Restore-DashboardFromGitHub -DashboardRoot $dashRoot -Cfg $Cfg) {
                $issues = @(Test-ProjectIntegrity -ProjectPath $ProjectPath)
            }
        }
        if ($issues.Count -gt 0) {
            throw ("Local content check failed - $($issues.Count) problem(s) remain:`n  - " + ($issues -join "`n  - ") + "`nRun 'git pull' (or re-download the DefenderMigrationDashboard folder) and try again.")
        }
    }
}

function Test-ProjectIntegrity {
    <# Deep validation of the local PBIP project + deploy assets before an install/update. Returns a
       list of problem strings (empty when everything is present and well-formed) instead of
       throwing, so the caller can attempt a GitHub re-download and re-validate. Prints non-fatal
       warnings inline. #>
    param([string]$ProjectPath)
    $issues = New-Object System.Collections.Generic.List[string]
    $pageCount = 0
    $modelDir  = (Get-ChildItem -LiteralPath $ProjectPath -Directory -Filter "*.SemanticModel" -ErrorAction SilentlyContinue | Select-Object -First 1)
    $reportDir = (Get-ChildItem -LiteralPath $ProjectPath -Directory -Filter "*.Report"        -ErrorAction SilentlyContinue | Select-Object -First 1)
    if (-not $modelDir)  { $issues.Add("No *.SemanticModel folder under '$ProjectPath'.") }
    if (-not $reportDir) { $issues.Add("No *.Report folder under '$ProjectPath'.") }

    if ($modelDir) {
        $mdef = Join-Path $modelDir.FullName "definition"
        foreach ($f in @("model.tmdl", "database.tmdl")) {
            if (-not (Test-Path -LiteralPath (Join-Path $mdef $f))) { $issues.Add("Missing semantic-model file: definition\$f") }
        }
        $needTables = [ordered]@{ "DeviceHealth.tmdl" = "__AVPOSTURE_SEED_B64__"; "DeploymentTrend.tmdl" = "__TREND_SEED_B64__"; "TrendMigration.tmdl" = "__TRENDMIGRATION_SEED_B64__" }
        foreach ($t in $needTables.Keys) {
            $tp = Join-Path $mdef "tables\$t"
            if (-not (Test-Path -LiteralPath $tp)) { $issues.Add("Missing table definition: definition\tables\$t"); continue }
            $raw = Get-Content -LiteralPath $tp -Raw
            if ([string]::IsNullOrWhiteSpace($raw)) { $issues.Add("Empty table definition: definition\tables\$t"); continue }
            $ph = [string]$needTables[$t]
            if ($ph -and $raw -notmatch [regex]::Escape($ph)) { Write-Warn2 "definition\tables\$t is missing its $ph seed placeholder - deploy-time seeding of that table will be skipped." }
        }
    }

    if ($reportDir) {
        if (-not (Test-Path -LiteralPath (Join-Path $reportDir.FullName "definition.pbir"))) { $issues.Add("Missing report file: definition.pbir") }
        $pagesDir  = Join-Path $reportDir.FullName "definition\pages"
        $pageCount = @(Get-ChildItem -LiteralPath $pagesDir -Directory -ErrorAction SilentlyContinue).Count
        if ($pageCount -lt 1) { $issues.Add("Report has no pages under definition\pages.") }
    }

    foreach ($a in @("DeploymentTrend.kql", "DeviceAvPosture.kql")) {
        $ap = Join-Path $PSScriptRoot "assets\$a"
        if (-not (Test-Path -LiteralPath $ap)) { $issues.Add("Missing deploy asset: assets\$a") }
        elseif ((Get-Item -LiteralPath $ap).Length -eq 0) { $issues.Add("Empty deploy asset: assets\$a") }
    }

    if ($issues.Count -eq 0) { Write-Ok "Local content verified: model tables, seed placeholders, report pages ($pageCount) and deploy assets present." }
    return $issues.ToArray()
}

function Read-Menu {
    <# Simple numbered-menu prompt returning the 1-based choice. Enter accepts -Default. #>
    param([string]$Title, [string[]]$Options, [int]$Default = 1)
    Write-Host ""
    Write-Host $Title -ForegroundColor Cyan
    for ($i = 0; $i -lt $Options.Count; $i++) { Write-Host ("  {0}) {1}" -f ($i + 1), $Options[$i]) }
    while ($true) {
        $ans = Read-Host ("Choose 1-{0} [default {1}]" -f $Options.Count, $Default)
        if ([string]::IsNullOrWhiteSpace($ans)) { return $Default }
        $n = 0
        if ([int]::TryParse($ans, [ref]$n) -and $n -ge 1 -and $n -le $Options.Count) { return $n }
        Write-Host "  Please enter a number between 1 and $($Options.Count)." -ForegroundColor Yellow
    }
}

function Read-YesNo {
    <# Yes/no prompt; Enter accepts -Default. #>
    param([string]$Prompt, [bool]$Default = $true)
    $suffix = if ($Default) { "[Y/n]" } else { "[y/N]" }
    while ($true) {
        $ans = Read-Host "$Prompt $suffix"
        if ([string]::IsNullOrWhiteSpace($ans)) { return $Default }
        switch -Regex ($ans.Trim()) {
            '^(y|yes)$' { return $true }
            '^(n|no)$'  { return $false }
            default     { Write-Host "  Please answer y or n." -ForegroundColor Yellow }
        }
    }
}

function Start-DeployWizard {
    <# Guided, no-arguments experience: walks a first-time user through config/auth, action,
       workspace and Trend-data choices with plain numbered menus (no Out-GridView dependency),
       then returns a hashtable the caller applies to its parameters. #>
    param([string]$ScriptRoot)
    $choices = @{ ConfigPath = $null; CheckVersionOnly = $false; Force = $false; SelectWorkspace = $false; WorkspaceId = $null; TrendCsv = $null }
    Write-Host ""
    Write-Host "==================================================================" -ForegroundColor Cyan
    Write-Host "  Defender Migration Dashboard - guided deploy" -ForegroundColor Cyan
    Write-Host "  (no parameters supplied - I'll ask a few short questions)"       -ForegroundColor DarkCyan
    Write-Host "==================================================================" -ForegroundColor Cyan

    # 1) config / auth
    $cfgCandidates = @(@(
        (Join-Path $ScriptRoot "config.json"),
        (Join-Path (Split-Path -Parent $ScriptRoot) "config.json")
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -Unique)
    $useSpConfig = $false
    if ($cfgCandidates.Count -gt 0) {
        $c = $cfgCandidates[0]
        if (Read-YesNo "Found a config.json at '$c'. Use it (service-principal auth)?" $true) { $choices.ConfigPath = $c; $useSpConfig = $true }
    }
    if (-not $choices.ConfigPath) {
        $p = Read-Host "Path to config.json (Enter to sign in interactively with Azure CLI instead)"
        if (-not [string]::IsNullOrWhiteSpace($p)) {
            if (Test-Path -LiteralPath $p) { $choices.ConfigPath = $p; $useSpConfig = $true }
            else { Write-Host "  '$p' not found - falling back to interactive sign-in." -ForegroundColor Yellow }
        }
    }

    # 2) action
    $action = Read-Menu "What would you like to do?" @(
        "Deploy / update the dashboard in place",
        "Check for updates only (read-only, no changes)"
    ) 1
    if ($action -eq 2) { $choices.CheckVersionOnly = $true }

    # 3) workspace
    if ($useSpConfig) {
        $wid = Read-Host "Target workspace GUID (Enter to use workspaceId from config.json)"
        if (-not [string]::IsNullOrWhiteSpace($wid)) { $choices.WorkspaceId = $wid.Trim() }
    } else {
        $choices.SelectWorkspace = $true   # interactive picker later in the flow
    }

    # 4) Trend data (only when actually deploying)
    if (-not $choices.CheckVersionOnly) {
        $store = Join-Path $ScriptRoot "trend-inventory.local.csv"
        $have = 0
        if (Test-Path -LiteralPath $store) { $have = @(Read-TrendStore -Path $store).Count }
        if ($have -gt 0) {
            Write-Host ""
            Write-Host "  A saved Trend list with $have device(s) was found - it will be kept and re-pushed." -ForegroundColor Green
            if (Read-YesNo "Import an additional / updated Trend CSV as well?" $false) {
                $tc = Read-Host "  Path to the Trend export CSV"
                if (-not [string]::IsNullOrWhiteSpace($tc) -and (Test-Path -LiteralPath $tc)) { $choices.TrendCsv = $tc.Trim() }
                elseif (-not [string]::IsNullOrWhiteSpace($tc)) { Write-Host "  '$tc' not found - skipping the import." -ForegroundColor Yellow }
            }
        } else {
            if (Read-YesNo "No Trend list has been ingested yet. Import a Trend export CSV now?" $false) {
                $tc = Read-Host "  Path to the Trend export CSV"
                if (-not [string]::IsNullOrWhiteSpace($tc) -and (Test-Path -LiteralPath $tc)) { $choices.TrendCsv = $tc.Trim() }
                elseif (-not [string]::IsNullOrWhiteSpace($tc)) { Write-Host "  '$tc' not found - skipping the import." -ForegroundColor Yellow }
            }
        }
        if (Read-YesNo "Force redeploy even if the workspace is already current?" $false) { $choices.Force = $true }
    }

    # summary + confirm
    Write-Host ""
    Write-Host "Summary:" -ForegroundColor Cyan
    Write-Host ("  Auth       : {0}" -f $(if ($choices.ConfigPath) { "service principal ($($choices.ConfigPath))" } else { "interactive Azure CLI" }))
    Write-Host ("  Action     : {0}" -f $(if ($choices.CheckVersionOnly) { "check for updates (read-only)" } else { "deploy / update in place" }))
    Write-Host ("  Workspace  : {0}" -f $(if ($choices.WorkspaceId) { $choices.WorkspaceId } elseif ($choices.SelectWorkspace) { "choose interactively" } else { "from config.json" }))
    if (-not $choices.CheckVersionOnly) {
        Write-Host ("  Trend data : {0}" -f $(if ($choices.TrendCsv) { "import $($choices.TrendCsv) (merged with the saved list)" } else { "keep the previously ingested list" }))
        Write-Host ("  Force      : {0}" -f $choices.Force)
    }
    if (-not (Read-YesNo "Proceed?" $true)) { Write-Host "Cancelled." -ForegroundColor Yellow; exit 0 }
    return $choices
}

function Ensure-SignedIn {
    param([string]$TenantId)
    if ($script:Auth.UseSP) {
        Write-Step "Authenticating as service principal"
        Get-Token -Resource $script:FabricRes | Out-Null
        Write-Ok "Signed in as app $($script:Auth.ClientId) (tenant $($script:Auth.TenantId))"
        return
    }
    az account show 1>$null 2>$null
    if (($LASTEXITCODE -ne 0) -or $TenantId) {
        Write-Step "Signing in with Azure CLI"
        if ($TenantId) { az login --tenant $TenantId --only-show-errors 1>$null 2>$null }
        else           { az login --only-show-errors 1>$null 2>$null }
        if ($LASTEXITCODE -ne 0) { throw "az login failed. Run 'az login' manually and re-run this script." }
    }
    $acct = az account show --query "{user:user.name, tenant:tenantId}" -o json | ConvertFrom-Json
    Write-Ok "Signed in as $($acct.user) (tenant $($acct.tenant))"
    $script:TokenCache = @{}   # ensure fresh tokens for the (possibly new) session
}

# --------------------------------------------------------------------- version / update-in-place
function Get-VersionFromText {
    <# Extracts a YYYY.MM.DD.XX calendar version from arbitrary text. Returns $null if none found. #>
    param([string]$Text)
    if (-not $Text) { return $null }
    $m = [regex]::Match($Text, '(\d{4}\.\d{2}\.\d{2}\.\d{2})')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

function Get-ChangelogVersion {
    <# Top (most recent) entry in CHANGELOG.md, e.g. '## [2026.07.18.01]'. Returns $null if absent. #>
    param([string]$DashboardRoot)
    if (-not $DashboardRoot) { return $null }
    $cl = Join-Path $DashboardRoot "CHANGELOG.md"
    if (-not (Test-Path -LiteralPath $cl)) { return $null }
    $hit = Select-String -LiteralPath $cl -Pattern '^\s*##\s*\[(\d{4}\.\d{2}\.\d{2}\.\d{2})\]' | Select-Object -First 1
    if ($hit) { return $hit.Matches[0].Groups[1].Value }
    return (Get-VersionFromText (((Get-Content -LiteralPath $cl -TotalCount 40) -join "`n")))
}

function Get-LocalDashboardVersion {
    <# The version users actually see is the 'Version YYYY.MM.DD.XX' marker on the KPI Guide page of
       the report - the definitive version of the *content* being deployed. Scans the report
       definition for that marker; falls back to the top CHANGELOG entry. Never throws: a missing
       marker must not block a deploy. #>
    param([string]$ReportDir, [string]$DashboardRoot)
    $ver = $null
    try {
        $visuals = Get-ChildItem -LiteralPath $ReportDir -Recurse -Filter "visual.json" -ErrorAction SilentlyContinue
        foreach ($v in $visuals) {
            $t = Get-Content -LiteralPath $v.FullName -Raw -ErrorAction SilentlyContinue
            $m = [regex]::Match($t, 'Version\s+(\d{4}\.\d{2}\.\d{2}\.\d{2})')
            if ($m.Success) { $ver = $m.Groups[1].Value; break }
        }
    } catch {}
    if (-not $ver) { $ver = Get-ChangelogVersion -DashboardRoot $DashboardRoot }
    return $ver
}

function Compare-AppVersion {
    <# -1 if A<B, 0 if equal, 1 if A>B. A null/empty version sorts lowest. Compares the four numeric
       YYYY.MM.DD.XX segments; falls back to a case-insensitive string compare for odd values. #>
    param([string]$A, [string]$B)
    if (-not $A -and -not $B) { return 0 }
    if (-not $A) { return -1 }
    if (-not $B) { return 1 }
    $ra = [regex]::Match($A, '^(\d{4})\.(\d{2})\.(\d{2})\.(\d{2})$')
    $rb = [regex]::Match($B, '^(\d{4})\.(\d{2})\.(\d{2})\.(\d{2})$')
    if ($ra.Success -and $rb.Success) {
        for ($i = 1; $i -le 4; $i++) {
            $x = [int]$ra.Groups[$i].Value; $y = [int]$rb.Groups[$i].Value
            if ($x -lt $y) { return -1 }
            if ($x -gt $y) { return 1 }
        }
        return 0
    }
    return [string]::Compare($A, $B, $true)
}

function Get-DeployedVersion {
    <# Reads the version stamped on the semantic-model item's description in the workspace. This is a
       read-only Fabric call (GET item) - the least-privileged way to learn what is live, so a plain
       Viewer / Item.Read.All identity can run the check with no deploy rights. Returns $null when
       the item does not exist yet (first deploy) or carries no version stamp. #>
    param([string]$WsId, [string]$ItemId)
    if (-not $ItemId) { return $null }
    $item = Invoke-Http -Method GET -Url "$script:FabricBase/workspaces/$WsId/items/$ItemId" -AllowNotFound
    if (-not $item) { return $null }
    $desc = $null
    if ($item.PSObject.Properties['description']) { $desc = $item.description }
    return (Get-VersionFromText $desc)
}

function Set-DeployedVersion {
    <# Stamps the deployed version onto the semantic-model item's description so the next run (or a
       read-only checker) can compare against it. Best-effort: a failure here must not fail an
       otherwise-successful deploy. #>
    param([string]$WsId, [string]$ItemId, [string]$Version, [string]$BaseName)
    if (-not $ItemId -or -not $Version) { return }
    $desc = "$BaseName - deployed version v$Version"
    if ($desc.Length -gt 256) { $desc = $desc.Substring(0, 256) }
    try {
        Invoke-Http -Method PATCH -Url "$script:FabricBase/workspaces/$WsId/items/$ItemId" -Body @{ description = $desc } | Out-Null
        Write-Ok "Stamped workspace version marker: v$Version"
    } catch {
        Write-Warn2 "Could not stamp the version marker (deploy still succeeded): $($_.Exception.Message)"
    }
}

function Get-GitHubVersion {
    <# Best-effort read of the latest released version from GitHub (top CHANGELOG entry on the tracked
       branch). Unauthenticated public raw fetch - needs no GitHub credentials. Resolves the raw URL
       from config (githubRawChangelogUrl), else the local git remote+branch, else a built-in
       default. Returns $null (with a warning) when offline or unresolved. #>
    param([string]$DashboardRoot, [hashtable]$Cfg)
    $url = $null
    if ($Cfg -and $Cfg.ContainsKey('githubRawChangelogUrl') -and $Cfg.githubRawChangelogUrl) {
        $url = [string]$Cfg.githubRawChangelogUrl
    }
    if (-not $url -and $DashboardRoot) {
        try {
            $remote = (& git -C $DashboardRoot remote get-url origin 2>$null)
            $branch = (& git -C $DashboardRoot rev-parse --abbrev-ref HEAD 2>$null)
            if ($remote) {
                $mm = [regex]::Match($remote, 'github\.com[:/]+([^/]+)/([^/.]+)')
                if ($mm.Success) {
                    $owner = $mm.Groups[1].Value; $repo = $mm.Groups[2].Value
                    if (-not $branch -or $branch -eq 'HEAD') { $branch = 'main' }
                    $url = "https://raw.githubusercontent.com/$owner/$repo/$branch/DefenderMigrationDashboard/CHANGELOG.md"
                }
            }
        } catch {}
    }
    if (-not $url) { $url = "https://raw.githubusercontent.com/CrisDea/MicrosoftSecurityCxD/main/DefenderMigrationDashboard/CHANGELOG.md" }
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
    $content = $null
    for ($attempt = 1; $attempt -le 2 -and -not $content; $attempt++) {
        try {
            $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
            $content = $resp.Content
        } catch {
            if ($attempt -ge 2) {
                Write-Warn2 "Could not read the GitHub version ($url): $($_.Exception.Message). Skipping the GitHub comparison."
                return $null
            }
            Start-Sleep -Seconds 2
        }
    }
    $m = [regex]::Match($content, '##\s*\[(\d{4}\.\d{2}\.\d{2}\.\d{2})\]')
    if ($m.Success) { return $m.Groups[1].Value }
    return (Get-VersionFromText $content)
}

function Resolve-GitHubRepo {
    <# Resolves owner/repo/branch for the dashboard's GitHub source: parsed from config
       githubRawChangelogUrl, else the local git remote+branch, else the built-in default
       (CrisDea/MicrosoftSecurityCxD @ main). #>
    param([string]$DashboardRoot, [hashtable]$Cfg)
    $owner = $null; $repo = $null; $branch = $null
    if ($Cfg -and $Cfg.ContainsKey('githubRawChangelogUrl') -and $Cfg.githubRawChangelogUrl) {
        $mm = [regex]::Match([string]$Cfg.githubRawChangelogUrl, 'raw\.githubusercontent\.com/([^/]+)/([^/]+)/([^/]+)/')
        if ($mm.Success) { $owner = $mm.Groups[1].Value; $repo = $mm.Groups[2].Value; $branch = $mm.Groups[3].Value }
    }
    if ((-not $owner) -and $DashboardRoot) {
        try {
            $remote = (& git -C $DashboardRoot remote get-url origin 2>$null)
            $b      = (& git -C $DashboardRoot rev-parse --abbrev-ref HEAD 2>$null)
            if ($remote) {
                $mm = [regex]::Match($remote, 'github\.com[:/]+([^/]+)/([^/.]+)')
                if ($mm.Success) { $owner = $mm.Groups[1].Value; $repo = $mm.Groups[2].Value; if ($b -and $b -ne 'HEAD') { $branch = $b } }
            }
        } catch {}
    }
    if (-not $owner)  { $owner  = 'CrisDea' }
    if (-not $repo)   { $repo   = 'MicrosoftSecurityCxD' }
    if (-not $branch) { $branch = 'main' }
    return [pscustomobject]@{ Owner = $owner; Repo = $repo; Branch = $branch }
}

function Restore-DashboardFromGitHub {
    <# Recovers a missing/incomplete local clone by downloading the public repo zip from GitHub and
       copying the dashboard CONTENT (pbip-project + deploy\assets by default) into place. It does
       NOT overwrite the running deploy scripts. Unauthenticated (public repo). Returns $true on a
       successful restore. #>
    param([string]$DashboardRoot, [hashtable]$Cfg, [string[]]$Subfolders = @('pbip-project', 'deploy\assets'))
    if (-not $DashboardRoot) { return $false }
    $gh = Resolve-GitHubRepo -DashboardRoot $DashboardRoot -Cfg $Cfg
    $zipUrl = "https://codeload.github.com/$($gh.Owner)/$($gh.Repo)/zip/refs/heads/$($gh.Branch)"
    Write-Step "Restoring dashboard content from GitHub ($($gh.Owner)/$($gh.Repo)@$($gh.Branch))"
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("dmd-restore-" + [Guid]::NewGuid().ToString('N'))
    $zip = "$tmp.zip"
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
    try {
        Invoke-WebRequest -Uri $zipUrl -OutFile $zip -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
        New-Item -ItemType Directory -Force -Path $tmp | Out-Null
        Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
        $extractedRoot = Get-ChildItem -LiteralPath $tmp -Directory | Select-Object -First 1
        if (-not $extractedRoot) { throw "the downloaded archive was empty" }
        $srcDash = Join-Path $extractedRoot.FullName "DefenderMigrationDashboard"
        if (-not (Test-Path -LiteralPath $srcDash)) { throw "DefenderMigrationDashboard was not found in the archive" }
        $restored = 0
        foreach ($sf in $Subfolders) {
            $src = Join-Path $srcDash $sf
            $dst = Join-Path $DashboardRoot $sf
            if (-not (Test-Path -LiteralPath $src)) { Write-Warn2 "  The GitHub copy has no '$sf' - skipping."; continue }
            if (-not (Test-Path -LiteralPath $dst)) { New-Item -ItemType Directory -Force -Path $dst | Out-Null }
            $copied = 0
            foreach ($file in (Get-ChildItem -LiteralPath $src -Recurse -File)) {
                $rel    = $file.FullName.Substring($src.Length).TrimStart('\', '/')
                $target = Join-Path $dst $rel
                $need = $true
                if (Test-Path -LiteralPath $target) {
                    try {
                        $a = (Get-Content -LiteralPath $file.FullName -Raw) -replace "`r", ""
                        $b = (Get-Content -LiteralPath $target -Raw) -replace "`r", ""
                        if ($a -eq $b) { $need = $false }   # identical ignoring line endings - leave it (avoids CRLF/LF churn)
                    } catch {}
                }
                if ($need) {
                    $tdir = Split-Path -Parent $target
                    if ($tdir -and -not (Test-Path -LiteralPath $tdir)) { New-Item -ItemType Directory -Force -Path $tdir | Out-Null }
                    Copy-Item -LiteralPath $file.FullName -Destination $target -Force
                    $copied++
                }
            }
            $restored++
            Write-Ok "  Restored $sf ($copied file(s) refreshed)"
        }
        if ($restored -eq 0) { throw "nothing was restored" }
        Write-Ok "GitHub restore complete ($restored folder(s))."
        return $true
    } catch {
        Write-Warn2 "GitHub restore failed ($($_.Exception.Message)). Fix your local clone manually (git pull) and re-run."
        return $false
    } finally {
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-VersionPreflight {
    <# Compares the version of the content about to be deployed (local), the latest released on GitHub,
       and what is currently live in the workspace, prints a summary and returns a decision object.
       Performs only read calls - safe for a read-only identity. #>
    param(
        [string]$WsId, [string]$ModelName, [string]$ReportDir, [string]$DashboardRoot,
        [hashtable]$Cfg, [switch]$SkipGitHubCheck
    )
    Write-Step "Version check (local vs GitHub vs workspace)"

    $local     = Get-LocalDashboardVersion -ReportDir $ReportDir -DashboardRoot $DashboardRoot
    $changelog = Get-ChangelogVersion -DashboardRoot $DashboardRoot
    if ($local -and $changelog -and (Compare-AppVersion $local $changelog) -ne 0) {
        Write-Warn2 "Report marker (v$local) and CHANGELOG (v$changelog) disagree - update both to keep versioning consistent."
    }

    $github = $null
    if (-not $SkipGitHubCheck) { $github = Get-GitHubVersion -DashboardRoot $DashboardRoot -Cfg $Cfg }

    $existing = Find-Item -WsId $WsId -Type "SemanticModel" -DisplayName $ModelName
    $itemId = $null; if ($existing) { $itemId = $existing.id }
    $deployed = Get-DeployedVersion -WsId $WsId -ItemId $itemId

    $fmt = { param($v) if ($v) { "v$v" } else { "(none)" } }
    Write-Host ("    {0,-20} {1}" -f "Local content:",   (& $fmt $local))
    Write-Host ("    {0,-20} {1}" -f "GitHub latest:",   (& $fmt $github))
    Write-Host ("    {0,-20} {1}" -f "Workspace (live):",(& $fmt $deployed))

    $localBehindGitHub = ($local -and $github -and (Compare-AppVersion $local $github) -lt 0)
    if ($localBehindGitHub) {
        Write-Warn2 "Your local content (v$local) is BEHIND GitHub (v$github). Run 'git pull' to get the latest release before deploying."
    }
    $cmp = Compare-AppVersion $deployed $local
    $isCurrent     = ($deployed -and $cmp -eq 0)
    $workspaceAhead= ($cmp -gt 0)
    if ($workspaceAhead) {
        Write-Warn2 "The workspace (v$deployed) is NEWER than your local content (v$local). Deploying would roll it back."
    }

    return [pscustomobject]@{
        Local             = $local
        GitHub            = $github
        Deployed          = $deployed
        ItemId            = $itemId
        IsCurrent         = $isCurrent
        NeedsUpdate       = (-not $isCurrent)
        LocalBehindGitHub = $localBehindGitHub
        WorkspaceAhead    = $workspaceAhead
    }
}

# --------------------------------------------------------------------- workspaces / capacities
function Get-WorkspaceById([string]$WsId) {
    return (Invoke-Http -Method GET -Url "$script:FabricBase/workspaces/$WsId" -AllowNotFound)
}

function Assert-WorkspaceUsable($ws) {
    if (-not $ws) { throw "Workspace not found or not accessible to this identity." }
    if (-not $ws.capacityId) {
        throw "Workspace '$($ws.displayName)' has no Fabric/Premium/PPU capacity assigned. Semantic models require a capacity. Assign one under Workspace settings > License info, or pass -CapacityId to create a new workspace on a capacity."
    }
}

function Select-CapacityId {
    try { $caps = Invoke-Http -Method GET -Url "$script:FabricBase/capacities" } catch { $caps = $null }
    $list = @()
    if ($caps -and $caps.value) { $list = @($caps.value | Where-Object { $_.state -eq "Active" }) }
    if ($list.Count -eq 0) { return (Read-Host "  No capacities enumerable. Enter a Capacity Id (GUID)") }
    Write-Host ""; Write-Host "  Available capacities:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $list.Count; $i++) { Write-Host ("   [{0}] {1}  ({2})" -f ($i+1), $list[$i].displayName, $list[$i].id) }
    do { $sel = Read-Host "  Select a capacity [1-$($list.Count)]" }
    while (-not ($sel -match '^\d+$') -or [int]$sel -lt 1 -or [int]$sel -gt $list.Count)
    return $list[[int]$sel - 1].id
}

function Select-Workspace {
    param([string]$CapacityId)
    $wss = Invoke-Http -Method GET -Url "$script:FabricBase/workspaces"
    $list = @()
    if ($wss -and $wss.value) { $list = @($wss.value | Where-Object { $_.type -eq "Workspace" -and $_.capacityId } | Sort-Object displayName) }
    Write-Host ""; Write-Host "  Select the target workspace:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $list.Count; $i++) { Write-Host ("   [{0}] {1}  ({2})" -f ($i+1), $list[$i].displayName, $list[$i].id) }
    Write-Host "   [N] Create a new workspace"
    while ($true) {
        $sel = Read-Host "  Choose [1-$($list.Count)] or N"
        if ($sel -match '^[Nn]$') {
            $name = Read-Host "  New workspace name"
            if (-not $name) { continue }
            $cap  = if ($CapacityId) { $CapacityId } else { Select-CapacityId }
            Write-Step "Creating workspace '$name'"
            $new = Invoke-Http -Method POST -Url "$script:FabricBase/workspaces" -Body @{ displayName = $name; capacityId = $cap }
            return @{ id = $new.id; name = $name }
        }
        if ($sel -match '^\d+$' -and [int]$sel -ge 1 -and [int]$sel -le $list.Count) {
            $w = $list[[int]$sel - 1]; return @{ id = $w.id; name = $w.displayName }
        }
    }
}

# --------------------------------------------------------------------- items
function Get-Parts([string]$Root, [hashtable]$Overrides) {
    $parts = @()
    Get-ChildItem -LiteralPath $Root -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Substring($Root.Length).TrimStart('\','/').Replace('\','/')
        if ($Overrides -and $Overrides.ContainsKey($rel)) { $bytes = [Text.Encoding]::UTF8.GetBytes($Overrides[$rel]) }
        else { $bytes = [IO.File]::ReadAllBytes($_.FullName) }
        $parts += @{ path = $rel; payload = [Convert]::ToBase64String($bytes); payloadType = "InlineBase64" }
    }
    return ,$parts
}

function Find-Item([string]$WsId, [string]$Type, [string]$DisplayName) {
    $items = Invoke-Http -Method GET -Url "$script:FabricBase/workspaces/$WsId/items?type=$Type"
    if (-not $items -or -not $items.value) { return $null }
    return ($items.value | Where-Object { $_.displayName -eq $DisplayName } | Select-Object -First 1)
}

function Publish-Item {
    param([string]$WsId, [string]$Type, [string]$DisplayName, $Parts)
    $existing = Find-Item -WsId $WsId -Type $Type -DisplayName $DisplayName
    if ($existing) {
        Write-Ok "Updating existing $Type '$DisplayName'"
        Invoke-Http -Method POST -Url "$script:FabricBase/workspaces/$WsId/items/$($existing.id)/updateDefinition" `
            -Body @{ definition = @{ parts = $Parts } } | Out-Null
        return $existing.id
    }
    Write-Ok "Creating new $Type '$DisplayName'"
    $created = Invoke-Http -Method POST -Url "$script:FabricBase/workspaces/$WsId/items" `
        -Body @{ displayName = $DisplayName; type = $Type; definition = @{ parts = $Parts } }
    return $created.id
}

function Remove-ItemFabric {
    param([string]$WsId, [string]$Type, [string]$DisplayName)
    $existing = Find-Item -WsId $WsId -Type $Type -DisplayName $DisplayName
    if (-not $existing) { Write-Warn2 "$Type '$DisplayName' not found - nothing to remove."; return $false }
    Invoke-Http -Method DELETE -Url "$script:FabricBase/workspaces/$WsId/items/$($existing.id)" -AllowNotFound | Out-Null
    Write-Ok "Removed $Type '$DisplayName' ($($existing.id))"
    return $true
}

# --------------------------------------------------------------------- refresh
function Invoke-RefreshAndWait {
    param([string]$WsId, [string]$DatasetId, [int]$TimeoutSec = 600, [switch]$Wait)
    try {
        Invoke-Http -Method POST -Resource $script:PowerBIRes `
            -Url "$script:PowerBIBase/groups/$WsId/datasets/$DatasetId/refreshes" `
            -Body @{ type = "Full"; notifyOption = "NoNotification" } | Out-Null
        Write-Ok "Refresh started"
    } catch {
        Write-Warn2 "Refresh could not be started automatically ($($_.Exception.Message)). Open the dataset in the service and click Refresh."
        return $false
    }
    if (-not $Wait) { return $true }
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        try {
            $h = Invoke-Http -Method GET -Resource $script:PowerBIRes `
                    -Url "$script:PowerBIBase/groups/$WsId/datasets/$DatasetId/refreshes?`$top=1"
        } catch { continue }
        $r = if ($h.value) { $h.value[0] } else { $null }
        if (-not $r) { continue }
        switch ($r.status) {
            "Completed" { Write-Ok "Refresh completed"; return $true }
            "Failed"    { Write-Warn2 "Refresh failed: $($r.serviceExceptionJson)"; return $false }
            "Disabled"  { Write-Warn2 "Refresh disabled on this dataset."; return $false }
            default     { }   # Unknown / InProgress - keep waiting
        }
    }
    Write-Warn2 "Refresh did not reach a terminal state within ${TimeoutSec}s; it may still complete in the service."
    return $false
}

# --------------------------------------------------------------------- live Graph binding
function Backup-LocalStore {
    <# Before a deploy overwrites a local data store (Trend list / trend history), copy the
       current file into deploy\backups\ with a timestamped name so previously-ingested data can
       always be recovered. Keeps the most recent -Keep copies per store; older ones are pruned.
       Returns the backup path, or $null when there was nothing to back up. #>
    param([string]$Path, [int]$Keep = 15)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    $backupDir = Join-Path $PSScriptRoot "backups"
    if (-not (Test-Path -LiteralPath $backupDir)) { New-Item -ItemType Directory -Force -Path $backupDir | Out-Null }
    $base  = [IO.Path]::GetFileNameWithoutExtension($Path)
    $ext   = [IO.Path]::GetExtension($Path)
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $dest  = Join-Path $backupDir "$base.$stamp$ext"
    Copy-Item -LiteralPath $Path -Destination $dest -Force
    $old = @(Get-ChildItem -LiteralPath $backupDir -File -Filter "$base.*$ext" -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -Skip $Keep)
    foreach ($f in $old) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }
    return $dest
}

function Get-TrendHistoryKey {
    <# Stable de-dup key for a DeploymentTrend row: the day (first 10 chars of Date) and group. #>
    param($Row)
    $d = [string]$Row.Date
    if ($d.Length -ge 10) { $d = $d.Substring(0, 10) }
    return "$d|$([string]$Row.MachineGroup)"
}

function Read-TrendHistoryStore {
    <# Reads the git-ignored local DeploymentTrend history store (JSON array of day/group rows).
       Returns an empty array when the store is absent or unreadable. #>
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return @() }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw
        if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
        return @($raw | ConvertFrom-Json)
    } catch {
        Write-Warn2 "Could not read the trend-history store '$Path' ($($_.Exception.Message)); starting a fresh history."
        return @()
    }
}

function Write-TrendHistoryStore {
    <# Persists the accumulated DeploymentTrend history to a JSON array. #>
    param([string]$Path, [object[]]$Rows)
    if (-not $Path) { return }
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $json = if ($Rows -and $Rows.Count -gt 0) { $Rows | ConvertTo-Json -Depth 5 } else { "[]" }
    Set-Content -LiteralPath $Path -Value $json -Encoding UTF8
}

function Merge-TrendHistory {
    <# Accumulates DeploymentTrend day/group rows across deploys so the migration trend keeps
       history beyond the 30-day advanced-hunting window. For an overlapping (Date, MachineGroup)
       the counts come from the fresh generation, but NonCompliant keeps the maximum ever recorded
       for that day (the KQL only sets NonCompliant on the latest day, so this preserves the
       point-in-time value once a day rolls out of "today"). Rows older than -RetentionDays from
       the newest day are dropped to bound the embedded seed size. Returns the merged rows sorted
       by date then group. #>
    param([object[]]$Existing, [object[]]$New, [int]$RetentionDays = 400)
    $map = [ordered]@{}
    foreach ($e in $Existing) { if ($null -ne $e) { $map[(Get-TrendHistoryKey $e)] = $e } }
    foreach ($n in $New) {
        if ($null -eq $n) { continue }
        $k = Get-TrendHistoryKey $n
        if ($map.Contains($k)) {
            $old = $map[$k]
            $oldNc = 0; if ($old.PSObject.Properties['NonCompliant']) { [void][int]::TryParse([string]$old.NonCompliant, [ref]$oldNc) }
            $newNc = 0; if ($n.PSObject.Properties['NonCompliant'])  { [void][int]::TryParse([string]$n.NonCompliant,  [ref]$newNc) }
            if ($newNc -lt $oldNc -and $n.PSObject.Properties['NonCompliant']) { $n.NonCompliant = $oldNc }
        }
        $map[$k] = $n
    }
    $rows = @($map.Values)
    if ($RetentionDays -gt 0 -and $rows.Count -gt 0) {
        $dates = New-Object System.Collections.ArrayList
        foreach ($r in $rows) { try { [void]$dates.Add([datetime]::Parse((Get-TrendHistoryKey $r).Split('|')[0])) } catch {} }
        if ($dates.Count -gt 0) {
            $cutoff = ($dates | Measure-Object -Maximum).Maximum.AddDays(-$RetentionDays)
            $rows = @($rows | Where-Object { try { [datetime]::Parse((Get-TrendHistoryKey $_).Split('|')[0]) -ge $cutoff } catch { $true } })
        }
    }
    return @($rows | Sort-Object @{ Expression = { (Get-TrendHistoryKey $_).Split('|')[0] } }, @{ Expression = { [string]$_.MachineGroup } })
}

function New-TrendSeedOverride {
    <# Generates the DeploymentTrend history at deploy time and returns a Get-Parts override
       that embeds it in the model. The advanced-hunting endpoint is POST-only and cannot run
       during a cloud scheduled refresh (a Web.Contents POST body is rejected on any non-
       Anonymous datasource -> Mashup 10347; Anonymous + an in-query token then trips the
       Power Query data-combination firewall, which has no TMDL fast-combine override). So the
       aggregated 30-day history is materialised here: the committed DeploymentTrend.tmdl carries
       a __TREND_SEED_B64__ placeholder that this fills with a base64 JSON snapshot, regenerated
       on every (re)deploy. The live current-state table (DeviceHealth) still refreshes on the
       normal cadence via its Service-Principal-bound datasource.

       Returns $null when the model has no trend placeholder (nothing to inject). On a hunting
       failure it injects an empty seed ("[]") and warns, so deployment still succeeds with an
       empty trend rather than a broken refresh. #>
    param([string]$ModelDir, [string]$TenantId, [string]$ClientId, [string]$ClientSecret)
    $trendPath = Join-Path $ModelDir "definition\tables\DeploymentTrend.tmdl"
    if (-not (Test-Path -LiteralPath $trendPath)) { return $null }
    $txt = Get-Content -LiteralPath $trendPath -Raw
    if ($txt -notmatch '__TREND_SEED_B64__') { return $null }
    if (-not ($TenantId -and $ClientId -and $ClientSecret)) {
        throw "This dashboard queries Microsoft Defender live and needs an Entra app registration. Provide graphTenantId/graphClientId/graphClientSecret (or tenantId/clientId/clientSecret) in config.json, or pass -TenantId -ClientId -ClientSecret."
    }
    $kqlPath = Join-Path $PSScriptRoot "assets\DeploymentTrend.kql"
    if (-not (Test-Path -LiteralPath $kqlPath)) { throw "Trend query asset not found: $kqlPath" }
    $kql = [IO.File]::ReadAllText($kqlPath)
    $histStore = Join-Path $PSScriptRoot "deployment-trend.local.json"
    $history = @(Read-TrendHistoryStore -Path $histStore)
    $seedJson = "[]"
    try {
        $body = @{ client_id = $ClientId; client_secret = $ClientSecret; grant_type = "client_credentials"
                   scope = "https://api.securitycenter.microsoft.com/.default" }
        $tok = (Invoke-RestMethod -Method POST -ContentType "application/x-www-form-urlencoded" `
                    -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body $body).access_token
        $resp = Invoke-RestMethod -Method POST -Uri "https://api.securitycenter.microsoft.com/api/advancedqueries/run" `
                    -Headers @{ Authorization = "Bearer $tok" } -ContentType "application/json" -Body (@{ Query = $kql } | ConvertTo-Json)
        $rows = @($resp.Results)
        if ($rows.Count -gt 0) {
            $merged = @(Merge-TrendHistory -Existing $history -New $rows)
            Backup-LocalStore -Path $histStore | Out-Null
            Write-TrendHistoryStore -Path $histStore -Rows $merged
            $seedJson = ($merged | ConvertTo-Json -Depth 5 -Compress)
            if ($merged.Count -eq 1) { $seedJson = "[$seedJson]" }   # single record -> keep it an array
            $extra = $merged.Count - $rows.Count
            if ($extra -gt 0) { Write-Ok "Trend history: $($rows.Count) fresh day/group rows + $extra retained from prior deploys = $($merged.Count) total" }
            else              { Write-Ok "Trend history generated: $($rows.Count) day/group rows" }
        } elseif ($history.Count -gt 0) {
            $seedJson = ($history | ConvertTo-Json -Depth 5 -Compress)
            if ($history.Count -eq 1) { $seedJson = "[$seedJson]" }
            Write-Warn2 "Advanced-hunting trend query returned no rows - re-pushing $($history.Count) day/group rows retained from prior deploys so the trend is preserved."
        } else {
            Write-Warn2 "Advanced-hunting trend query returned no rows - trend will be empty until more history accrues."
        }
    } catch {
        if ($history.Count -gt 0) {
            $seedJson = ($history | ConvertTo-Json -Depth 5 -Compress)
            if ($history.Count -eq 1) { $seedJson = "[$seedJson]" }
            Write-Warn2 "Could not generate fresh trend history ($($_.Exception.Message)). Re-pushing $($history.Count) day/group rows retained from prior deploys so nothing is lost."
        } else {
            Write-Warn2 "Could not generate trend history ($($_.Exception.Message)). Deploying with an empty trend; re-run once the app has WindowsDefenderATP AdvancedQuery.Read.All / Machine.Read.All consented."
        }
    }
    $seedB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($seedJson))
    return @{ "definition/tables/DeploymentTrend.tmdl" = $txt.Replace('__TREND_SEED_B64__', $seedB64) }
}

function New-AvPostureSeedOverride {
    <# Generates per-device AV posture (mode + platform/engine/signature versions and their
       fleet-relative currency grades) at deploy time and returns a Get-Parts override that
       embeds it in DeviceHealth. Same rationale as New-TrendSeedOverride: this data lives only
       in DeviceTvmInfoGathering, reachable via the POST-only advanced-hunting endpoint, which
       cannot run during a cloud scheduled refresh. The committed DeviceHealth.tmdl carries a
       __AVPOSTURE_SEED_B64__ placeholder that this fills with a base64 JSON snapshot (one record
       per DeviceId), regenerated on every (re)deploy; the rest of DeviceHealth still refreshes
       live via its Service-Principal-bound export datasource.

       Returns $null when the model has no AV placeholder. On a hunting failure it injects an
       empty seed ("[]") and warns, so deployment still succeeds (every AV field stays "N/A")
       rather than breaking refresh. #>
    param([string]$ModelDir, [string]$TenantId, [string]$ClientId, [string]$ClientSecret, [int]$RemovedAfterDays = 0)
    $dhPath = Join-Path $ModelDir "definition\tables\DeviceHealth.tmdl"
    if (-not (Test-Path -LiteralPath $dhPath)) { return $null }
    $txt = Get-Content -LiteralPath $dhPath -Raw
    if ($txt -notmatch '__AVPOSTURE_SEED_B64__') { return $null }
    if (-not ($TenantId -and $ClientId -and $ClientSecret)) {
        throw "This dashboard queries Microsoft Defender live and needs an Entra app registration. Provide graphTenantId/graphClientId/graphClientSecret (or tenantId/clientId/clientSecret) in config.json, or pass -TenantId -ClientId -ClientSecret."
    }
    $kqlPath = Join-Path $PSScriptRoot "assets\DeviceAvPosture.kql"
    if (-not (Test-Path -LiteralPath $kqlPath)) { throw "AV posture query asset not found: $kqlPath" }
    $kql = [IO.File]::ReadAllText($kqlPath)
    $seedJson = "[]"
    try {
        $body = @{ client_id = $ClientId; client_secret = $ClientSecret; grant_type = "client_credentials"
                   scope = "https://api.securitycenter.microsoft.com/.default" }
        $tok = (Invoke-RestMethod -Method POST -ContentType "application/x-www-form-urlencoded" `
                    -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body $body).access_token
        $resp = Invoke-RestMethod -Method POST -Uri "https://api.securitycenter.microsoft.com/api/advancedqueries/run" `
                    -Headers @{ Authorization = "Bearer $tok" } -ContentType "application/json" -Body (@{ Query = $kql } | ConvertTo-Json)
        $rows = @($resp.Results)
        if ($rows.Count -gt 0) {
            $seedJson = ($rows | ConvertTo-Json -Depth 5 -Compress)
            if ($rows.Count -eq 1) { $seedJson = "[$seedJson]" }   # single record -> keep it an array
            Write-Ok "AV posture generated: $($rows.Count) device rows"
        } else {
            Write-Warn2 "Advanced-hunting AV posture query returned no rows - AV mode/versions will show N/A until DeviceTvmInfoGathering telemetry accrues."
        }
    } catch {
        Write-Warn2 "Could not generate AV posture ($($_.Exception.Message)). Deploying with AV fields set to N/A; re-run once the app has WindowsDefenderATP AdvancedQuery.Read.All consented."
    }
    $seedB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($seedJson))
    $dhText = $txt.Replace('__AVPOSTURE_SEED_B64__', $seedB64)
    if ($RemovedAfterDays -gt 0) { $dhText = $dhText -replace 'RemovedAfterDaysCutoff = 0', "RemovedAfterDaysCutoff = $RemovedAfterDays" }
    return @{ "definition/tables/DeviceHealth.tmdl" = $dhText }
}

function Test-LiveModel {
    param([string]$ModelDir)
    $trendPath = Join-Path $ModelDir "definition\tables\DeploymentTrend.tmdl"
    if (Test-Path -LiteralPath $trendPath) {
        if ((Get-Content -LiteralPath $trendPath -Raw) -match '__TREND_SEED_B64__') { return $true }
    }
    # A DeviceHealth table that queries securitycenter also marks this as a live model.
    $dhPath = Join-Path $ModelDir "definition\tables\DeviceHealth.tmdl"
    if (Test-Path -LiteralPath $dhPath) {
        if ((Get-Content -LiteralPath $dhPath -Raw) -match 'api\.securitycenter\.microsoft\.com') { return $true }
    }
    return $false
}

function Set-LiveCredentials {
    <# Binds a Service Principal (app-only OAuth2 client credentials) on the model's
       api.securitycenter.microsoft.com datasource. Power BI mints and attaches the bearer
       token itself, so the query needs no in-query token and no second data source - which
       is what keeps DeviceHealth a single-source query and sidesteps the Power Query data-
       combination firewall on scheduled refresh.

       The SP is the same Entra app used to generate the trend seed and must hold application
       permissions Machine.Read.All, Vulnerability.Read.All and Software.Read.All (admin-
       consented) on WindowsDefenderATP. The bind is applied over REST and needs no manual UI
       step. It persists across model re-publishes. #>
    param([string]$WsId, [string]$DatasetId, [string]$TenantId, [string]$ClientId, [string]$ClientSecret)
    Write-Step "Binding data-source credentials (Service Principal)"
    if (-not ($TenantId -and $ClientId -and $ClientSecret)) {
        Write-Warn2 "No app credentials supplied - skipping credential bind. Set them in the Service under the dataset > Data source credentials (Service principal)."
        return
    }
    $ds = Invoke-Http -Method GET -Resource $script:PowerBIRes -AllowNotFound `
            -Url "$script:PowerBIBase/groups/$WsId/datasets/$DatasetId/datasources"
    if (-not $ds -or -not $ds.value) {
        Write-Warn2 "No data sources reported yet. If refresh prompts for credentials, open the dataset > Settings > Data source credentials and bind api.securitycenter.microsoft.com with the Service principal (tenant/client id/secret)."
        return
    }
    $credData = @{ credentialData = @(
        @{ name = "servicePrincipalClientId"; value = $ClientId },
        @{ name = "servicePrincipalSecret";   value = $ClientSecret },
        @{ name = "tenantId";                 value = $TenantId }
    ) } | ConvertTo-Json -Compress
    foreach ($d in $ds.value) {
        $gw = $d.gatewayId; $dsid = $d.datasourceId
        if (-not $gw -or -not $dsid) { continue }
        $u = $null; try { $u = $d.connectionDetails.url } catch {}
        $body = @{ credentialDetails = @{
            credentialType      = "ServicePrincipal"
            credentials         = $credData
            encryptedConnection = "NotEncrypted"
            encryptionAlgorithm = "None"
            privacyLevel        = "Organizational"
        } }
        try {
            Invoke-Http -Method PATCH -Resource $script:PowerBIRes -Body $body `
                -Url "$script:PowerBIBase/gateways/$gw/datasources/$dsid" | Out-Null
            Write-Ok "Service Principal bound ($u)"
        } catch {
            Write-Warn2 "Service Principal bind failed for $u : $($_.Exception.Message). Bind it manually in the Service (Data source credentials > Service principal)."
        }
    }
}

function Set-RefreshSchedule {
    <# Configures native scheduled refresh so the dashboard re-queries Defender on a
       cadence with no local scheduler. Defaults to 2x/day (every 12h). The underlying
       Defender Vulnerability Management assessment tables (DeviceTvmSecureConfigurationAssessment,
       DeviceTvmSoftwareInventory, DeviceTvmInfoGathering) refresh their per-device snapshot only
       about once a day, so refreshing more often yields no newer data - twice daily keeps the
       report current with headroom for time zones while staying well within the Power BI Pro limit. #>
    param([string]$WsId, [string]$DatasetId, [string[]]$Times, [string]$TimeZone = "UTC")
    if (-not $Times -or $Times.Count -eq 0) {
        $Times = @("06:00","18:00")
    }
    $body = @{ value = @{
        enabled         = $true
        days            = @("Monday","Tuesday","Wednesday","Thursday","Friday","Saturday","Sunday")
        times           = $Times
        localTimeZoneId = $TimeZone
        notifyOption    = "NoNotification"
    } }
    try {
        Invoke-Http -Method PATCH -Resource $script:PowerBIRes -Body $body `
            -Url "$script:PowerBIBase/groups/$WsId/datasets/$DatasetId/refreshSchedule" | Out-Null
        Write-Ok "Scheduled refresh enabled ($($Times.Count)x/day, $TimeZone)"
    } catch {
        Write-Warn2 "Could not set the refresh schedule automatically: $($_.Exception.Message)"
    }
}

# ===================================================================== Trend -> Defender migration
# Deploy-time ingest of a Trend Micro device export: fuzzy-match its device names against the current
# Defender inventory and materialise the mapping into the TrendMigration table (same seed pattern as
# DeploymentTrend / AV posture). Shared by Deploy-Dashboard.ps1 (-TrendCsv) and Import-TrendInventory.ps1.

function Get-SecurityCenterToken {
    <# App-only (client-credentials) token for the Defender for Endpoint API. #>
    param([string]$TenantId, [string]$ClientId, [string]$ClientSecret)
    $body = @{ client_id = $ClientId; client_secret = $ClientSecret; grant_type = "client_credentials"
               scope = "https://api.securitycenter.microsoft.com/.default" }
    (Invoke-RestMethod -Method POST -ContentType "application/x-www-form-urlencoded" `
        -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body $body).access_token
}

function Get-DefenderInventory {
    <# Returns the current Defender device inventory from the SAME paged export endpoint the
       DeviceHealth table uses (GET /api/machines), so the Trend mapping aligns exactly with what
       the dashboard shows. One row per machine: DeviceId, DeviceName, OnboardingStatus, OSPlatform,
       OSVersion. Needs only WindowsDefenderATP Machine.Read.All (app-only). #>
    param([string]$TenantId, [string]$ClientId, [string]$ClientSecret)
    if (-not ($TenantId -and $ClientId -and $ClientSecret)) {
        throw "Mapping the Trend export to Defender needs an Entra app registration. Provide graphTenantId/graphClientId/graphClientSecret (or tenantId/clientId/clientSecret) in config.json, or pass -TenantId -ClientId -ClientSecret."
    }
    $tok = Get-SecurityCenterToken -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret
    $headers = @{ Authorization = "Bearer $tok" }
    $url = 'https://api.securitycenter.microsoft.com/api/machines?$select=id,computerDnsName,onboardingStatus,osPlatform,version,osBuild,mergedIntoMachineId,isExcluded'
    $all = New-Object System.Collections.ArrayList
    while ($url) {
        $resp = Invoke-RestMethod -Method GET -Uri $url -Headers $headers
        foreach ($m in $resp.value) {
            if ([string]::IsNullOrWhiteSpace($m.computerDnsName)) { continue }
            # Align exactly with the DeviceHealth table: drop merged-away and excluded machines so the
            # Trend mapping cannot match a stale/duplicate record the dashboard itself hides.
            if (-not [string]::IsNullOrWhiteSpace([string]$m.mergedIntoMachineId)) { continue }
            if ([string]$m.isExcluded -eq 'True') { continue }
            $ver = @($m.version, $m.osBuild | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ' / '
            [void]$all.Add([pscustomobject]@{
                DeviceId         = [string]$m.id
                DeviceName       = [string]$m.computerDnsName
                OnboardingStatus = [string]$m.onboardingStatus
                OSPlatform       = [string]$m.osPlatform
                OSVersion        = [string]$ver
            })
        }
        $url = try { $resp.'@odata.nextLink' } catch { $null }
    }
    return $all.ToArray()
}

function Get-NormalizedDeviceName {
    <# Canonical form for matching: lowercase, trimmed, AD trailing '$' removed, DNS domain suffix
       dropped (everything after the first dot), and non-alphanumeric noise stripped. #>
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return "" }
    $n = $Name.Trim().ToLowerInvariant().TrimEnd('$')
    $dot = $n.IndexOf('.')
    if ($dot -gt 0) { $n = $n.Substring(0, $dot) }
    return ($n -replace '[^a-z0-9]', '')
}

function Get-NormalizedDomainSuffix {
    <# The DNS domain suffix (everything after the first dot) of a device name, normalised to
       lowercase with the AD trailing '$' and any leading/trailing dots removed. Empty when the name
       is a short (single-label) host name. Used so fuzzy matching can be confined to the domain
       while the short hostname must match exactly. #>
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return "" }
    $n = $Name.Trim().ToLowerInvariant().TrimEnd('$')
    $dot = $n.IndexOf('.')
    if ($dot -lt 0) { return "" }
    $dom = $n.Substring($dot + 1).Trim('.')
    return ($dom -replace '[^a-z0-9.-]', '')
}

function Get-LevenshteinDistance {
    param([string]$A, [string]$B, [int]$MaxDistance = [int]::MaxValue)
    if ($A -eq $B) { return 0 }
    $la = $A.Length; $lb = $B.Length
    if ($la -eq 0) { return $lb }
    if ($lb -eq 0) { return $la }
    # Fast reject: the distance is at least the length gap, so bail before the DP if that alone
    # already exceeds the caller's tolerance.
    if ([Math]::Abs($la - $lb) -gt $MaxDistance) { return $MaxDistance + 1 }
    $prev = New-Object 'int[]' ($lb + 1)
    $cur  = New-Object 'int[]' ($lb + 1)
    for ($j = 0; $j -le $lb; $j++) { $prev[$j] = $j }
    for ($i = 1; $i -le $la; $i++) {
        $cur[0] = $i
        $ca = $A[$i - 1]
        $rowMin = $cur[0]
        for ($j = 1; $j -le $lb; $j++) {
            $cost = if ($ca -eq $B[$j - 1]) { 0 } else { 1 }
            $del = $prev[$j] + 1
            $ins = $cur[$j - 1] + 1
            $sub = $prev[$j - 1] + $cost
            $m = if ($del -lt $ins) { $del } else { $ins }
            if ($sub -lt $m) { $m = $sub }
            $cur[$j] = $m
            if ($m -lt $rowMin) { $rowMin = $m }
        }
        # Every remaining cell can only grow from this row's minimum, so once the whole row exceeds
        # the tolerance the final distance cannot come back under it - stop early.
        if ($rowMin -gt $MaxDistance) { return $MaxDistance + 1 }
        $tmp = $prev; $prev = $cur; $cur = $tmp
    }
    return $prev[$lb]
}

function Get-NameSimilarity {
    <# 0-100 similarity between two already-normalised names (100 = identical). When -MinScore is
       given, the underlying edit distance is bounded so pairs that cannot reach that score are
       rejected cheaply (keeps the fuzzy search near-linear on large fleets). #>
    param([string]$A, [string]$B, [int]$MinScore = 0)
    if ($A -eq $B) { return 100 }
    $max = [Math]::Max($A.Length, $B.Length)
    if ($max -eq 0) { return 0 }
    $maxDist = if ($MinScore -gt 0) { [int][Math]::Floor($max * (1.0 - ($MinScore / 100.0))) } else { [int]::MaxValue }
    $d = Get-LevenshteinDistance -A $A -B $B -MaxDistance $maxDist
    return [int][Math]::Round((1.0 - ($d / [double]$max)) * 100.0)
}

function Resolve-TrendColumn {
    <# Picks the first header from a candidate list that matches (case/space-insensitive), else the
       first header whose name matches the -Fallback regex, else $null. #>
    param([string[]]$Columns, [string[]]$Candidates, [string]$Fallback)
    foreach ($c in $Candidates) {
        $hit = $Columns | Where-Object { $_.Trim().ToLowerInvariant() -eq $c.ToLowerInvariant() } | Select-Object -First 1
        if ($hit) { return $hit }
    }
    if ($Fallback) {
        $hit = $Columns | Where-Object { $_.ToLowerInvariant() -match $Fallback } | Select-Object -First 1
        if ($hit) { return $hit }
    }
    return $null
}

function Get-TrendSourceFromColumns {
    <# Infers the Trend product from an export's header signature. Deep Security exposes 'Host GUID'
       / 'Agent GUID'; Apex One exposes a bare 'GUID' alongside 'Endpoint'/'Scan Method'. Falls back
       to the generic label 'Trend'. #>
    param([string[]]$Columns)
    $lc = $Columns | ForEach-Object { $_.Trim().ToLowerInvariant() }
    if ($lc -contains 'host guid' -or $lc -contains 'agent guid') { return 'Deep Security' }
    if ($lc -contains 'guid' -and ($lc -contains 'endpoint' -or $lc -contains 'scan method')) { return 'Apex One' }
    return 'Trend'
}

function Get-TrendDeviceRecords {
    <# Reads a Trend Micro CSV export (native Apex One / Deep Security export, or the normalised
       TrendId,DeviceName,TrendSource template) and returns one record per row with the minimum
       fields the dashboard ingests:

         TrendId     - the tool's own unique device identifier (Apex One 'GUID', Deep Security
                       'Host GUID' preferred over 'Agent GUID'), used as the de-duplication key.
         DeviceName  - the host/endpoint name, used to match against the Defender inventory.
         TrendSource - which Trend product the row came from (auto-detected, or -Source override).

       The host-name and id columns are auto-detected from common Trend header names; -Source
       overrides the auto-detected product label. Rows with no device name are dropped. #>
    param([string]$TrendCsv, [string]$Source)
    if (-not (Test-Path -LiteralPath $TrendCsv)) { throw "Trend CSV not found: $TrendCsv" }
    $rows = @(Import-Csv -LiteralPath $TrendCsv)
    if ($rows.Count -eq 0) { return @() }
    $cols = $rows[0].PSObject.Properties.Name

    $nameCol = Resolve-TrendColumn -Columns $cols -Fallback 'host|endpoint|computer|device|machine|name' -Candidates @(
        'DeviceName','Endpoint Name','Endpoint','Host Name','Hostname','Host','Computer Name','Computer',
        'Device Name','Device','Machine Name','Machine','Agent Host Name','Managed Server','Name')
    if (-not $nameCol) { $nameCol = $cols[0] }

    # Prefer a host/machine-level GUID (stable across agent reinstalls) over an agent-install GUID.
    $idCol = Resolve-TrendColumn -Columns $cols -Fallback 'guid|uuid|\bid\b' -Candidates @(
        'TrendId','Host GUID','GUID','Agent GUID','Endpoint GUID','Instance ID','UUID','Host ID','Agent ID','Machine GUID')

    $src = if ($Source) { $Source }
           else {
               $srcCol = Resolve-TrendColumn -Columns $cols -Candidates @('TrendSource')
               if ($srcCol) { $null } else { Get-TrendSourceFromColumns -Columns $cols }
           }

    Write-Ok ("Trend export: name column '{0}', id column '{1}'{2} ({3} rows)" -f `
        $nameCol, ($idCol ?? '(none)'), $(if ($src) { ", source '$src'" } else { '' }), $rows.Count)

    $out = New-Object System.Collections.ArrayList
    foreach ($r in $rows) {
        $name = if ($nameCol) { [string]$r.$nameCol } else { "" }
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $id = if ($idCol) { [string]$r.$idCol } else { "" }
        $rowSrc = if ($src) { $src }
                  elseif ($r.PSObject.Properties.Name -contains 'TrendSource') { [string]$r.TrendSource }
                  else { 'Trend' }
        [void]$out.Add([pscustomobject]@{
            TrendId     = ($id).Trim()
            DeviceName  = ($name).Trim()
            TrendSource = ($rowSrc).Trim()
        })
    }
    return $out.ToArray()
}

function Get-TrendDeviceNames {
    <# Backward-compatible helper: returns just the device/host names from a Trend export. #>
    param([string]$TrendCsv)
    return @(Get-TrendDeviceRecords -TrendCsv $TrendCsv | ForEach-Object { $_.DeviceName })
}

function Get-TrendDedupKey {
    <# De-duplication key for a Trend record: the tool's unique id when present (that is the
       requested "unique ID of the Trend tool"), else a normalised host|source fallback so exports
       without a usable id still de-duplicate sensibly. #>
    param($Record)
    $id = if ($Record.PSObject.Properties.Name -contains 'TrendId') { [string]$Record.TrendId } else { "" }
    if (-not [string]::IsNullOrWhiteSpace($id)) { return "id:" + $id.Trim().ToLowerInvariant().Trim('{','}') }
    $host2 = Get-NormalizedDeviceName ([string]$Record.DeviceName)
    $dom  = Get-NormalizedDomainSuffix ([string]$Record.DeviceName)
    $src  = if ($Record.PSObject.Properties.Name -contains 'TrendSource') { ([string]$Record.TrendSource).ToLowerInvariant() } else { "" }
    return "name:$host2|$dom|$src"
}

function Read-TrendStore {
    <# Reads the local Trend inventory master store (git-ignored CSV of previously ingested devices).
       Returns an empty array when the store does not exist. #>
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return @() }
    $rows = @(Import-Csv -LiteralPath $Path)
    $out = New-Object System.Collections.ArrayList
    foreach ($r in $rows) {
        if ([string]::IsNullOrWhiteSpace([string]$r.DeviceName)) { continue }
        [void]$out.Add([pscustomobject]@{
            TrendId     = [string]$r.TrendId
            DeviceName  = [string]$r.DeviceName
            TrendSource = [string]$r.TrendSource
            FirstSeen   = if ($r.PSObject.Properties.Name -contains 'FirstSeen') { [string]$r.FirstSeen } else { "" }
        })
    }
    return $out.ToArray()
}

function Merge-TrendStore {
    <# Merges freshly parsed Trend records into the existing master store.
         -Mode Replace : the new export becomes the whole list (de-duplicated on the Trend id).
         -Mode Append  : keep everything already ingested and add only records whose Trend id
                         (or host|source fallback) is not already present.
       Returns the merged, de-duplicated record set. #>
    param([object[]]$Existing, [object[]]$New, [ValidateSet('Replace','Append')][string]$Mode = 'Replace')
    $now = (Get-Date).ToString('yyyy-MM-dd')
    $result = New-Object System.Collections.ArrayList
    $seen = @{}
    function _add($rec, $firstSeen) {
        $k = Get-TrendDedupKey $rec
        if ($seen.ContainsKey($k)) { return }
        $seen[$k] = $true
        [void]$result.Add([pscustomobject]@{
            TrendId     = [string]$rec.TrendId
            DeviceName  = [string]$rec.DeviceName
            TrendSource = [string]$rec.TrendSource
            FirstSeen   = if ($firstSeen) { $firstSeen } else { $now }
        })
    }
    if ($Mode -eq 'Append') {
        foreach ($e in $Existing) { _add $e ($(if ($e.PSObject.Properties.Name -contains 'FirstSeen' -and $e.FirstSeen) { $e.FirstSeen } else { $now })) }
    }
    foreach ($n in $New) { _add $n $now }
    return $result.ToArray()
}

function Write-TrendStore {
    <# Persists the master store to CSV (TrendId,DeviceName,TrendSource,FirstSeen). #>
    param([string]$Path, [object[]]$Records)
    if (-not $Path) { return }
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    if (-not $Records -or $Records.Count -eq 0) {
        Set-Content -LiteralPath $Path -Value "TrendId,DeviceName,TrendSource,FirstSeen" -Encoding UTF8
        return
    }
    $Records | Select-Object TrendId, DeviceName, TrendSource, FirstSeen |
        Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
}

function Get-TrendDefenderMapping {
    <# Core matcher. Requires an EXACT normalised short-hostname match between each Trend device and a
       Defender device; fuzzy tolerance is applied ONLY to the DNS domain suffix. So
       'host.contoso.com' still matches 'host.contoso.local' (same host, near domain), a short name
       'host' matches any 'host.<domain>', but two different hostnames never fuzzy-match each other.
       De-duplication is keyed on the Trend tool's unique id (falling back to host|source when no id
       is present). Accepts either -TrendRecords (objects with TrendId/DeviceName/TrendSource) or,
       for backward compatibility, a flat -TrendNames string array. Returns one PSCustomObject per
       de-duplicated Trend device with its best Defender match. #>
    param([object[]]$TrendRecords, [string[]]$TrendNames, [object[]]$Inventory, [int]$MatchThreshold = 82)
    if ($MatchThreshold -lt 0)   { $MatchThreshold = 0 }
    if ($MatchThreshold -gt 100) { $MatchThreshold = 100 }
    if (-not $TrendRecords -or $TrendRecords.Count -eq 0) {
        $TrendRecords = @($TrendNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { [pscustomobject]@{ TrendId = ""; DeviceName = [string]$_; TrendSource = "Trend" } })
    }
    # Index Defender devices by normalised short hostname -> every device that shares that hostname
    # (there can be several across different domains; the domain suffix decides which one wins below).
    $byHost = @{}
    foreach ($d in $Inventory) {
        $h = Get-NormalizedDeviceName $d.DeviceName
        if ($h -eq "") { continue }
        if (-not $byHost.ContainsKey($h)) { $byHost[$h] = New-Object System.Collections.ArrayList }
        [void]$byHost[$h].Add($d)
    }
    $seen = @{}
    $out = New-Object System.Collections.ArrayList
    foreach ($rec in $TrendRecords) {
        $raw      = [string]$rec.DeviceName
        $trendId  = if ($rec.PSObject.Properties.Name -contains 'TrendId') { [string]$rec.TrendId } else { "" }
        $trendSrc = if ($rec.PSObject.Properties.Name -contains 'TrendSource') { [string]$rec.TrendSource } else { "Trend" }
        $thost = Get-NormalizedDeviceName $raw
        $tdom  = Get-NormalizedDomainSuffix $raw
        if ($thost -eq "") { continue }
        $dedup = Get-TrendDedupKey $rec
        if ($seen.ContainsKey($dedup)) { continue }
        $seen[$dedup] = $true
        $match = $null; $score = 0; $mtype = "Unmatched"
        if ($byHost.ContainsKey($thost)) {
            # Hostname matches exactly; the only fuzzy decision left is which candidate's DNS domain
            # is closest. An identical or absent domain is an exact match; a different domain is
            # accepted only when it stays within the fuzzy tolerance.
            $best = -1; $bestDev = $null; $bestType = "Fuzzy"
            foreach ($d in $byHost[$thost]) {
                $ddom = Get-NormalizedDomainSuffix $d.DeviceName
                if ($tdom -eq $ddom -or $tdom -eq "" -or $ddom -eq "") { $s = 100; $type = "Exact" }
                else { $s = Get-NameSimilarity -A $tdom -B $ddom -MinScore $MatchThreshold; $type = "Fuzzy" }
                if (($s -gt $best) -or
                    ($s -eq $best -and [string]$d.OnboardingStatus -eq "Onboarded" -and [string]$bestDev.OnboardingStatus -ne "Onboarded")) {
                    $best = $s; $bestDev = $d; $bestType = $type
                }
            }
            if ($bestDev -and ($bestType -eq "Exact" -or $best -ge $MatchThreshold)) {
                $match = $bestDev; $score = $best; $mtype = $bestType
            } else {
                $score = [Math]::Max(0, $best)
            }
        }
        if ($match) {
            $onboard = [string]$match.OnboardingStatus
            $status = if ($onboard -eq "Onboarded") { "Migrated to Defender" } else { "Matched - not onboarded" }
            [void]$out.Add([pscustomobject]@{
                TrendId            = $trendId
                TrendSource        = $trendSrc
                TrendDeviceName    = $raw
                DefenderDeviceName = [string]$match.DeviceName
                DeviceId           = [string]$match.DeviceId
                MatchType          = $mtype
                MatchScore         = [int]$score
                OnboardingStatus   = $onboard
                OSPlatform         = [string]$match.OSPlatform
                OSVersion          = [string]$match.OSVersion
                MigrationStatus    = $status
            })
        } else {
            [void]$out.Add([pscustomobject]@{
                TrendId            = $trendId
                TrendSource        = $trendSrc
                TrendDeviceName    = $raw
                DefenderDeviceName = ""
                DeviceId           = ""
                MatchType          = "Unmatched"
                MatchScore         = [int]$score
                OnboardingStatus   = ""
                OSPlatform         = ""
                OSVersion          = ""
                MigrationStatus    = "Not found in Defender"
            })
        }
    }
    return $out.ToArray()
}

function ConvertTo-TrendMigrationSeed {
    <# Serialises mapping objects to the compact JSON array the TrendMigration partition expects. #>
    param([object[]]$Mapping)
    if (-not $Mapping -or $Mapping.Count -eq 0) { return "[]" }
    $json = ($Mapping | ConvertTo-Json -Depth 4 -Compress)
    if ($Mapping.Count -eq 1) { $json = "[$json]" }   # single record -> keep it an array
    return $json
}

function New-TrendMigrationSeedOverride {
    <# Generates the Trend->Defender mapping at deploy time and returns a Get-Parts override that
       embeds it in the TrendMigration table (__TRENDMIGRATION_SEED_B64__). Returns $null when the
       model has no TrendMigration placeholder. When -TrendCsv is not supplied, injects an empty
       seed so the table exists but has no rows. On any failure it injects an empty seed and warns,
       so deployment still succeeds.

       -TrendMode Replace (default) uses the supplied export as the whole Trend list; -TrendMode
       Append merges the export into the git-ignored master store (-InventoryStore), de-duplicating
       on the Trend tool's unique id so only new devices are added. The full (merged) list is then
       matched against the current Defender inventory. #>
    param([string]$ModelDir, [string]$TenantId, [string]$ClientId, [string]$ClientSecret,
          [string]$TrendCsv, [int]$MatchThreshold = 82,
          [ValidateSet('Replace','Append')][string]$TrendMode = 'Replace',
          [string]$InventoryStore, [string]$TrendSource)
    $path = Join-Path $ModelDir "definition\tables\TrendMigration.tmdl"
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $txt = Get-Content -LiteralPath $path -Raw
    if ($txt -notmatch '__TRENDMIGRATION_SEED_B64__') { return $null }
    if (-not $InventoryStore) { $InventoryStore = Join-Path $PSScriptRoot "trend-inventory.local.csv" }
    $seedJson = "[]"
    $storeExists = Test-Path -LiteralPath $InventoryStore
    if (-not $TrendCsv -and -not $storeExists) {
        Write-Warn2 "No -TrendCsv supplied and no saved Trend list found - TrendMigration will be empty. Pass -TrendCsv <trend-export.csv> to populate the migration mapping."
    } else {
        try {
            $existing = Read-TrendStore -Path $InventoryStore
            if ($TrendCsv) {
                $newRecs = @(Get-TrendDeviceRecords -TrendCsv $TrendCsv -Source $TrendSource)
                $merged  = Merge-TrendStore -Existing $existing -New $newRecs -Mode $TrendMode
                if ($merged.Count -eq 0) { throw "no device names found in the Trend export or master store" }
                Backup-LocalStore -Path $InventoryStore | Out-Null
                Write-TrendStore -Path $InventoryStore -Records $merged
                Write-Ok "Trend list ($TrendMode): ingested $($newRecs.Count) from export; $($merged.Count) unique devices now in the store ($InventoryStore)"
            } else {
                # No new export on this run: re-use (re-push) the previously ingested Trend list
                # instead of emptying it, so an update-in-place preserves the ingested data.
                $merged = $existing
                if ($merged.Count -eq 0) { throw "the saved Trend list is empty" }
                Write-Ok "Trend list preserved: re-using $($merged.Count) devices previously ingested into the store ($InventoryStore)"
            }
            $inv = Get-DefenderInventory -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret
            $map = Get-TrendDefenderMapping -TrendRecords $merged -Inventory $inv -MatchThreshold $MatchThreshold
            $seedJson = ConvertTo-TrendMigrationSeed -Mapping $map
            $migr = @($map | Where-Object { $_.MigrationStatus -eq "Migrated to Defender" }).Count
            $pend = @($map | Where-Object { $_.MigrationStatus -eq "Matched - not onboarded" }).Count
            $miss = @($map | Where-Object { $_.MigrationStatus -eq "Not found in Defender" }).Count
            Write-Ok "Trend migration mapped: $($map.Count) devices - $migr migrated, $pend matched/not onboarded, $miss not in Defender"
        } catch {
            Write-Warn2 "Could not build the Trend migration mapping ($($_.Exception.Message)). Deploying with an empty TrendMigration table."
        }
    }
    $seedB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($seedJson))
    return @{ "definition/tables/TrendMigration.tmdl" = $txt.Replace('__TRENDMIGRATION_SEED_B64__', $seedB64) }
}

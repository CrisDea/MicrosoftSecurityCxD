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

# --------------------------------------------------------------------- runtime baseline
# These scripts target Windows PowerShell 5.1 (the version shipped in-box on Windows) and also run
# unchanged on PowerShell 7+. Two 5.1-specific behaviours must be corrected before any HTTPS call:
#
#   1. TLS. Windows PowerShell 5.1 uses the .NET Framework default protocol list, which on many
#      estates still negotiates TLS 1.0/1.1. Entra ID, the Fabric/Power BI APIs and the Defender
#      APIs all require TLS 1.2 or better, so a 5.1 host would otherwise fail the handshake with a
#      misleading "underlying connection was closed" error. Add TLS 1.2 (and 1.3 where the host
#      supports it) without removing anything the host already trusts.
#   2. Progress bars. Invoke-WebRequest in 5.1 renders a progress bar for every call, which is slow
#      over large paged exports and pollutes non-interactive logs.
if ([Net.ServicePointManager]::SecurityProtocol -ne 0) {
    $desired = [Net.SecurityProtocolType]::Tls12
    # Tls13 only exists on newer .NET/Windows builds - probe rather than assume.
    try { $desired = $desired -bor [Net.SecurityProtocolType]::Tls13 } catch { }
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor $desired }
    catch { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 }
}
$script:PreviousProgressPreference = $ProgressPreference
$ProgressPreference = 'SilentlyContinue'

function Test-PowerShellBaseline {
    <# Verifies the host meets the documented minimum (Windows PowerShell 5.1 or PowerShell 7+) and
       warns on the PowerShell 2.0/3.0/4.0 hosts where the language features used here are absent. #>
    $v = $PSVersionTable.PSVersion
    if ($v.Major -lt 5) {
        throw "This dashboard requires Windows PowerShell 5.1 or PowerShell 7+. Detected $v. Install Windows Management Framework 5.1 or run under pwsh."
    }
    if ($v.Major -eq 5 -and $v.Minor -lt 1) {
        Write-Warn2 "Detected PowerShell $v. 5.1 is the supported minimum; upgrade if you hit unexpected errors."
    }
}

function Protect-SecretForDisplay {
    <# Masks a secret for console/log output, keeping only enough to identify which value it was.
       Never log a raw client secret - use this everywhere a secret might reach the transcript. #>
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return "<not set>" }
    if ($Value.Length -le 6) { return "******" }
    return ("******" + $Value.Substring($Value.Length - 4))
}

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
       missing file - returns an empty hashtable so callers can merge defensively.

       Security: config.json holds a plaintext client secret, so this also runs a lightweight
       hygiene check on where the file lives and who can read it, and warns (never blocks) when
       the file is somewhere it should not be. #>
    param([string]$ConfigPath, [switch]$SkipSecurityCheck)
    if (-not $ConfigPath) { return @{} }
    if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "ConfigPath not found: $ConfigPath" }
    try { $cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json }
    catch { throw "config.json at '$ConfigPath' is not valid JSON: $($_.Exception.Message)" }
    $h = @{}
    foreach ($p in $cfg.PSObject.Properties) { if ($p.Value) { $h[$p.Name] = $p.Value } }
    if (-not $SkipSecurityCheck) { Test-ConfigSecurity -ConfigPath $ConfigPath }
    return $h
}

function Test-ConfigSecurity {
    <# Warns when the credential file is stored somewhere risky: inside a cloud-synced folder
       (OneDrive/Dropbox/Box/Google Drive - the secret would leave the machine), inside a git work
       tree where it is not ignored (it could be committed), or readable by users beyond the owner
       and the local administrators. Advisory only: it never blocks a deployment. #>
    param([string]$ConfigPath)
    try {
        $full = (Resolve-Path -LiteralPath $ConfigPath).Path

        # 1) Cloud-synced locations.
        $syncRoots = @($env:OneDrive, $env:OneDriveCommercial, $env:OneDriveConsumer) |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        foreach ($root in $syncRoots) {
            if ($full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
                Write-Warn2 "SECURITY: '$full' is inside a cloud-synced folder ($root). The client secret will be uploaded. Move it to a local-only path."
                break
            }
        }
        foreach ($name in @('Dropbox', 'Google Drive', 'Box', 'iCloudDrive')) {
            if ($full -like "*\$name\*") {
                Write-Warn2 "SECURITY: '$full' looks like it is inside a $name sync folder. The client secret will leave this machine. Move it to a local-only path."
                break
            }
        }

        # 2) Inside a git work tree and not ignored.
        $dir = Split-Path -Parent $full
        $probe = $dir
        $repoRoot = $null
        while ($probe) {
            if (Test-Path -LiteralPath (Join-Path $probe '.git')) { $repoRoot = $probe; break }
            $parent = Split-Path -Parent $probe
            if ($parent -eq $probe) { break }
            $probe = $parent
        }
        if ($repoRoot) {
            $ignored = $false
            try {
                & git -C $repoRoot check-ignore -q -- $full 2>$null
                $ignored = ($LASTEXITCODE -eq 0)
            } catch { $ignored = $false }
            if (-not $ignored) {
                Write-Warn2 "SECURITY: '$full' is inside the git repository at '$repoRoot' and is NOT git-ignored. It could be committed. Move it outside the repo, or add it to .gitignore."
            }
        }

        # 3) Over-broad ACL.
        try {
            $acl = Get-Acl -LiteralPath $full
            $risky = @($acl.Access | Where-Object {
                $id = [string]$_.IdentityReference
                $_.AccessControlType -eq 'Allow' -and (
                    $id -match 'Everyone|BUILTIN\\Users|NT AUTHORITY\\Authenticated Users|\\Domain Users$')
            })
            if ($risky.Count -gt 0) {
                $who = ($risky | ForEach-Object { [string]$_.IdentityReference } | Select-Object -Unique) -join ', '
                Write-Warn2 "SECURITY: '$full' is readable by $who. Restrict it to your account, e.g.: icacls `"$full`" /inheritance:r /grant:r `"$env:USERNAME`:F`""
            }
        } catch { }
    } catch { }
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
        $needTables = [ordered]@{ "DeviceHealth.tmdl" = "__AVPOSTURE_SEED_B64__"; "DeploymentTrend.tmdl" = "__TREND_SEED_B64__"; "LegacyAvMigration.tmdl" = "__LEGACYMIGRATION_SEED_B64__" }
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

    foreach ($a in @("DeviceAvPosture.kql")) {
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
       workspace and legacy AV/EDR data choices with plain numbered menus (no Out-GridView
       dependency), then returns a hashtable the caller applies to its parameters. #>
    param([string]$ScriptRoot)
    $choices = @{ ConfigPath = $null; CheckVersionOnly = $false; Force = $false; SelectWorkspace = $false; WorkspaceId = $null; LegacyCsv = $null; LegacyProduct = $null; LegacyMode = $null }
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

    # 4) Legacy AV/EDR data (only when actually deploying)
    if (-not $choices.CheckVersionOnly) {
        $store = Join-Path $ScriptRoot "legacy-inventory.local.csv"
        if (-not (Test-Path -LiteralPath $store)) {
            # Honour a store left behind by an earlier Trend-only release.
            $oldStore = Join-Path $ScriptRoot "trend-inventory.local.csv"
            if (Test-Path -LiteralPath $oldStore) { $store = $oldStore }
        }
        $have = 0
        $existing = @()
        if (Test-Path -LiteralPath $store) {
            $existing = @(Read-LegacyStore -Path $store)
            $have = $existing.Count
        }
        $import = $false
        if ($have -gt 0) {
            Write-Host ""
            Write-Host "  A saved legacy AV/EDR list with $have device(s) was found - it will be kept and re-pushed." -ForegroundColor Green
            foreach ($b in (Get-LegacyProductBreakdown -Records $existing)) {
                Write-Host ("    {0,-38} {1,6} devices" -f $b.Product, $b.Devices) -ForegroundColor DarkGray
            }
            Write-Host "  Migrating from more than one product? Import each vendor's export in turn - every row keeps its own product label." -ForegroundColor DarkGray
            $import = Read-YesNo "Import an additional / updated legacy AV/EDR export CSV as well?" $false
        } else {
            $import = Read-YesNo "No legacy AV/EDR list has been ingested yet. Import an export CSV now?" $false
        }
        if ($import) {
            $tc = Read-Host "  Path to the legacy AV/EDR export CSV"
            if (-not [string]::IsNullOrWhiteSpace($tc) -and (Test-Path -LiteralPath $tc)) {
                $choices.LegacyCsv = $tc.Trim()
                $lbl = Read-Host "  Product label for these devices (Enter to auto-detect, e.g. 'Trend Micro Apex One', 'Symantec Endpoint Protection')"
                if (-not [string]::IsNullOrWhiteSpace($lbl)) { $choices.LegacyProduct = $lbl.Trim() }
                # Adding a second product's export must never wipe the first one.
                if ($have -gt 0) {
                    $mode = Read-Menu "How should this export combine with the saved list?" @(
                        "Append - keep the saved devices and add these (use when migrating from several products)",
                        "Replace - this export becomes the entire legacy list"
                    ) 1
                    if ($mode -eq 1) { $choices.LegacyMode = 'Append' } else { $choices.LegacyMode = 'Replace' }
                }
            }
            elseif (-not [string]::IsNullOrWhiteSpace($tc)) { Write-Host "  '$tc' not found - skipping the import." -ForegroundColor Yellow }
        }
        if (Read-YesNo "Force redeploy even if the workspace is already current?" $false) { $choices.Force = $true }
    }

    # summary + confirm
    Write-Host ""
    Write-Host "Summary:" -ForegroundColor Cyan
    $authTxt = "interactive Azure CLI"
    if ($choices.ConfigPath) { $authTxt = "service principal ($($choices.ConfigPath))" }
    $actionTxt = "deploy / update in place"
    if ($choices.CheckVersionOnly) { $actionTxt = "check for updates (read-only)" }
    $wsTxt = "from config.json"
    if ($choices.WorkspaceId)        { $wsTxt = $choices.WorkspaceId }
    elseif ($choices.SelectWorkspace) { $wsTxt = "choose interactively" }
    Write-Host ("  Auth       : {0}" -f $authTxt)
    Write-Host ("  Action     : {0}" -f $actionTxt)
    Write-Host ("  Workspace  : {0}" -f $wsTxt)
    if (-not $choices.CheckVersionOnly) {
        $legacyTxt = "keep the previously ingested list"
        if ($choices.LegacyCsv) {
            $legacyTxt = "import $($choices.LegacyCsv)"
            if ($choices.LegacyProduct) { $legacyTxt += " as '$($choices.LegacyProduct)'" }
            if ($choices.LegacyMode)    { $legacyTxt += " ($($choices.LegacyMode))" }
        }
        Write-Host ("  Legacy AV  : {0}" -f $legacyTxt)
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
    <# Before a deploy overwrites a local data store (legacy AV/EDR list / deployment-trend
       history), copy the
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
    <# Stable de-dup key for a DeploymentTrend row: the day (first 10 chars of Date) and group.
       Property access is defensive because Set-StrictMode is active: a malformed row that lacks
       Date would otherwise throw and abort the whole merge, silently discarding real history. #>
    param($Row)
    if ($null -eq $Row) { return $null }
    $d = ''
    if ($Row.PSObject.Properties['Date']) {
        $raw = $Row.Date
        # ConvertFrom-Json re-hydrates an ISO date string into [datetime], so a round-tripped row
        # would otherwise stringify as "08/25/2026 00:00:00" and key differently from a freshly
        # generated "2026-08-25T00:00:00Z" - the same day counted twice, doubling the trend.
        if ($raw -is [datetime]) { $d = $raw.ToString('yyyy-MM-dd') }
        else {
            $d = [string]$raw
            $parsed = [datetime]::MinValue
            if ([datetime]::TryParse($d, [ref]$parsed)) { $d = $parsed.ToString('yyyy-MM-dd') }
        }
    }
    if ([string]::IsNullOrWhiteSpace($d)) { return $null }
    if ($d.Length -ge 10) { $d = $d.Substring(0, 10) }
    $g = ''
    if ($Row.PSObject.Properties['MachineGroup']) { $g = [string]$Row.MachineGroup }
    return "$d|$g"
}

function Read-TrendHistoryStore {
    <# Reads the git-ignored local DeploymentTrend history store (JSON array of day/group rows).
       Returns an empty array when the store is absent or unreadable.

       Older stores could be written as a collection *envelope* rather than a bare array - under
       Windows PowerShell 5.1, ConvertTo-Json on an ordered-dictionary value collection emits
       {"value":[...],"Count":N} instead of enumerating it. Such a store deserialises to a single
       object with no Date property, which used to abort the merge and lose the whole history.
       Any recognised envelope is unwrapped here, and only rows that carry a Date survive. #>
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return @() }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw
        if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
        $parsed = $raw | ConvertFrom-Json
        $rows = @($parsed)
        if ($rows.Count -eq 1 -and $null -ne $rows[0] -and -not $rows[0].PSObject.Properties['Date']) {
            foreach ($wrapper in @('value', 'Value', 'Results', 'rows')) {
                if ($rows[0].PSObject.Properties[$wrapper]) { $rows = @($rows[0].$wrapper); break }
            }
        }
        return @($rows | Where-Object { $null -ne $_ -and $_.PSObject.Properties['Date'] })
    } catch {
        Write-Warn2 "Could not read the trend-history store '$Path' ($($_.Exception.Message)); starting a fresh history."
        return @()
    }
}

function Write-TrendHistoryStore {
    <# Persists the accumulated DeploymentTrend history to a JSON array.
       The rows are copied into a plain array first: piping a collection wrapper straight to
       ConvertTo-Json under Windows PowerShell 5.1 can serialise the wrapper's own properties
       ({"value":[...],"Count":N}) instead of the rows, which corrupts the store. #>
    param([string]$Path, [object[]]$Rows)
    if (-not $Path) { return }
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $plain = @(); foreach ($r in $Rows) { if ($null -ne $r) { $plain += $r } }
    $json = "[]"
    if ($plain.Count -gt 0) {
        $json = ($plain | ConvertTo-Json -Depth 5)
        if ($plain.Count -eq 1) { $json = "[$json]" }   # single record -> keep it an array
    }
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
    foreach ($e in $Existing) {
        if ($null -eq $e) { continue }
        $k = Get-TrendHistoryKey $e
        if ($null -ne $k) { $map[$k] = $e }
    }
    foreach ($n in $New) {
        if ($null -eq $n) { continue }
        $k = Get-TrendHistoryKey $n
        if ($null -eq $k) { continue }
        if ($map.Contains($k)) {
            $old = $map[$k]
            $oldNc = 0; if ($old.PSObject.Properties['NonCompliant']) { [void][int]::TryParse([string]$old.NonCompliant, [ref]$oldNc) }
            $newNc = 0; if ($n.PSObject.Properties['NonCompliant'])  { [void][int]::TryParse([string]$n.NonCompliant,  [ref]$newNc) }
            if ($newNc -lt $oldNc -and $n.PSObject.Properties['NonCompliant']) { $n.NonCompliant = $oldNc }
        }
        $map[$k] = $n
    }
    $rows = @(); foreach ($v in $map.Values) { $rows += $v }
    # Canonicalise Date so the store, the embedded seed and the next merge all agree on one format.
    foreach ($r in $rows) {
        if ($r.PSObject.Properties['Date']) {
            $k = Get-TrendHistoryKey $r
            if ($null -ne $k) { $r.Date = $k.Split('|')[0] + 'T00:00:00Z' }
        }
    }
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

function Get-DefenderTrendSnapshot {
    <# Returns today's DeploymentTrend rows (one per machine group) from GET /api/machines - the
       SAME endpoint that feeds the DeviceHealth table and therefore every KPI card.

       This deliberately does not use advanced hunting. DeviceInfo answers a different question:
       it reports devices that have produced telemetry, and its OnboardingStatus reflects
       discovery state, so a tenant can legitimately show "Can be onboarded" there for machines
       the machines API reports as Onboarded. Sourcing the trend from hunting while the cards
       beside it came from /api/machines put two different populations on one page - the trend
       read 0 onboarded / 10 remaining while the cards on the same page read 7 / 13. #>
    param([string]$TenantId, [string]$ClientId, [string]$ClientSecret)
    $tok = Get-SecurityCenterToken -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret
    $headers = @{ Authorization = "Bearer $tok" }
    $url = 'https://api.securitycenter.microsoft.com/api/machines?$select=id,computerDnsName,onboardingStatus,healthStatus,rbacGroupName,mergedIntoMachineId,isExcluded'
    $machines = New-Object System.Collections.ArrayList
    while ($url) {
        $resp = Invoke-RestMethod -Method GET -Uri $url -Headers $headers
        foreach ($m in $resp.value) {
            if ([string]::IsNullOrWhiteSpace($m.computerDnsName)) { continue }
            # Mirror the DeviceHealth table exactly: drop merged-away and excluded machines.
            if (-not [string]::IsNullOrWhiteSpace([string]$m.mergedIntoMachineId)) { continue }
            if ([string]$m.isExcluded -eq 'True') { continue }
            [void]$machines.Add($m)
        }
        $url = try { $resp.'@odata.nextLink' } catch { $null }
    }
    if ($machines.Count -eq 0) { return @() }

    $day = (Get-Date).ToUniversalTime().Date.ToString('yyyy-MM-ddT00:00:00Z')
    $groups = [ordered]@{}
    foreach ($m in $machines) {
        $g = [string]$m.rbacGroupName
        if ([string]::IsNullOrWhiteSpace($g)) { $g = 'Unassigned' }
        if (-not $groups.Contains($g)) {
            $groups[$g] = [pscustomobject]@{
                Date = $day; MachineGroup = $g; MdeOnboarded = 0; TrendRemaining = 0
                ActiveDevices = 0; StaleDevices = 0; NonCompliant = 0
            }
        }
        $r = $groups[$g]
        if ([string]$m.onboardingStatus -eq 'Onboarded') {
            $r.MdeOnboarded++
            if ([string]$m.healthStatus -eq 'Active') { $r.ActiveDevices++ }
            else { $r.StaleDevices++; $r.NonCompliant++ }
        } else {
            $r.TrendRemaining++
        }
    }
    $out = @(); foreach ($v in $groups.Values) { $out += $v }
    return $out
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
    $histStore = Join-Path $PSScriptRoot "deployment-trend.local.json"
    $history = @(Read-TrendHistoryStore -Path $histStore)
    $seedJson = "[]"
    try {
        $rows = @(Get-DefenderTrendSnapshot -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret)
        if ($rows.Count -gt 0) {
            $merged = @(Merge-TrendHistory -Existing $history -New $rows)
            Backup-LocalStore -Path $histStore | Out-Null
            Write-TrendHistoryStore -Path $histStore -Rows $merged
            $seedJson = ($merged | ConvertTo-Json -Depth 5 -Compress)
            if ($merged.Count -eq 1) { $seedJson = "[$seedJson]" }   # single record -> keep it an array
            $extra = $merged.Count - $rows.Count
            if ($extra -gt 0) { Write-Ok "Trend history: $($rows.Count) group rows for today + $extra retained from prior deploys = $($merged.Count) total" }
            else              { Write-Ok "Trend history generated: $($rows.Count) group rows for today" }
        } elseif ($history.Count -gt 0) {
            $seedJson = ($history | ConvertTo-Json -Depth 5 -Compress)
            if ($history.Count -eq 1) { $seedJson = "[$seedJson]" }
            Write-Warn2 "Defender returned no machines - re-pushing $($history.Count) day/group rows retained from prior deploys so the trend is preserved."
        } else {
            Write-Warn2 "Defender returned no machines - trend will be empty until devices are onboarded."
        }
    } catch {
        if ($history.Count -gt 0) {
            $seedJson = ($history | ConvertTo-Json -Depth 5 -Compress)
            if ($history.Count -eq 1) { $seedJson = "[$seedJson]" }
            Write-Warn2 "Could not generate fresh trend history ($($_.Exception.Message)). Re-pushing $($history.Count) day/group rows retained from prior deploys so nothing is lost."
        } else {
            Write-Warn2 "Could not generate trend history ($($_.Exception.Message)). Deploying with an empty trend; re-run once the app has WindowsDefenderATP Machine.Read.All consented."
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

    # Datasource-credential management and the refresh schedule are both restricted to the
    # dataset OWNER, which is a distinct concept from workspace Admin - it is set to whichever
    # identity's token last published/took over the dataset. Claim ownership for the deploying
    # identity (SP or signed-in user) first so the calls below don't 401/403 against a stale owner.
    Set-DatasetOwner -WsId $WsId -DatasetId $DatasetId

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
        # Ownership can take a few seconds to propagate to the datasource-management authorization
        # check, so retry the bind briefly on 401 (DMTS_NotEnoughPermissionToManangeDatasourceErrorCode)
        # instead of failing on the first attempt.
        $bound = $false
        for ($try = 1; $try -le 4 -and -not $bound; $try++) {
            try {
                Invoke-Http -Method PATCH -Resource $script:PowerBIRes -Body $body `
                    -Url "$script:PowerBIBase/gateways/$gw/datasources/$dsid" | Out-Null
                Write-Ok "Service Principal bound ($u)"
                $bound = $true
            } catch {
                if ($try -lt 4 -and $_.Exception.Message -match "DMTS_NotEnoughPermissionToManangeDatasourceErrorCode|HTTP 401") {
                    Write-Warn2 "Owner permission not yet effective ($try/4) - waiting for propagation and retrying."
                    Start-Sleep -Seconds ([Math]::Min(20, 5 * $try))
                    continue
                }
                Write-Warn2 "Service Principal bind failed for $u : $($_.Exception.Message). Bind it manually in the Service (Data source credentials > Service principal)."
            }
        }
    }
}

function Set-DatasetOwner {
    <# Takes ownership of the dataset for the currently authenticated identity (SP or signed-in
       user). Datasource-credential binding and the refresh schedule are both scoped to the
       dataset owner, not just workspace membership, so this must run before those calls. Safe
       to call repeatedly; a 401/403 here just means the identity isn't a workspace member yet
       (handled earlier in the pipeline) or the take-over already belongs to this identity. #>
    param([string]$WsId, [string]$DatasetId)
    for ($try = 1; $try -le 3; $try++) {
        try {
            Invoke-Http -Method POST -Resource $script:PowerBIRes `
                -Url "$script:PowerBIBase/groups/$WsId/datasets/$DatasetId/Default.TakeOver" | Out-Null
            Write-Ok "Dataset ownership claimed for the deploying identity."
            return
        } catch {
            if ($try -lt 3) {
                Write-Warn2 "Take-over attempt $try/3 failed ($($_.Exception.Message)) - retrying."
                Start-Sleep -Seconds (5 * $try)
                continue
            }
            Write-Warn2 "Could not take over dataset ownership automatically: $($_.Exception.Message). Credential bind / refresh schedule may fail until an existing owner (or a Fabric admin) takes this over manually in the Service."
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
    # Restricted to the dataset owner, same as the credential bind above - Set-DatasetOwner
    # should already have run, but retry briefly in case of propagation lag.
    for ($try = 1; $try -le 3; $try++) {
        try {
            Invoke-Http -Method PATCH -Resource $script:PowerBIRes -Body $body `
                -Url "$script:PowerBIBase/groups/$WsId/datasets/$DatasetId/refreshSchedule" | Out-Null
            Write-Ok "Scheduled refresh enabled ($($Times.Count)x/day, $TimeZone)"
            return
        } catch {
            if ($try -lt 3 -and $_.Exception.Message -match "dataset owner|403") {
                Write-Warn2 "Owner permission not yet effective ($try/3) - waiting for propagation and retrying."
                Start-Sleep -Seconds (5 * $try)
                continue
            }
            Write-Warn2 "Could not set the refresh schedule automatically: $($_.Exception.Message)"
        }
    }
}

# ================================================ legacy AV/EDR -> Defender migration
# Deploy-time ingest of a device export from whatever antivirus / EDR product is being retired
# (Trend Micro, Symantec, McAfee/Trellix, Sophos, CrowdStrike, SentinelOne, Kaspersky, ESET,
# Carbon Black, Cylance, Bitdefender, Webroot, Cisco, Cortex XDR, ... - or an unrecognised
# product, which still ingests under its own label). Device names are matched against the current
# Defender inventory and the mapping is materialised into the LegacyAvMigration table (same seed
# pattern as DeploymentTrend / AV posture). Shared by Deploy-Dashboard.ps1 (-LegacyCsv) and
# Import-LegacyAvInventory.ps1. An estate may be migrating off SEVERAL products at once, so every
# ingested row records the product it came from.

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
       DeviceHealth table uses (GET /api/machines), so the legacy mapping aligns exactly with what
       the dashboard shows. One row per machine: DeviceId, DeviceName, OnboardingStatus, OSPlatform,
       OSVersion. Needs only WindowsDefenderATP Machine.Read.All (app-only). #>
    param([string]$TenantId, [string]$ClientId, [string]$ClientSecret)
    if (-not ($TenantId -and $ClientId -and $ClientSecret)) {
        throw "Mapping the legacy AV/EDR export to Defender needs an Entra app registration. Provide graphTenantId/graphClientId/graphClientSecret (or tenantId/clientId/clientSecret) in config.json, or pass -TenantId -ClientId -ClientSecret."
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
            # legacy mapping cannot match a stale/duplicate record the dashboard itself hides.
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


# ===================================================================================
#  Legacy AV/EDR ingestion - vendor-neutral
# -----------------------------------------------------------------------------------
#  These helpers ingest a device export from whatever antivirus / EDR product the
#  customer is migrating AWAY from, and match it to the current Microsoft Defender
#  inventory. Nothing here is specific to one vendor: a customer may be retiring
#  several products at once (for example Trend Micro Apex One on servers and
#  Symantec Endpoint Protection on laptops), so EVERY ingested row carries the name
#  of the product it came from in its own LegacyProduct / LegacyVendor fields. That
#  label survives the merge, the de-duplication, the Defender match and the seed, so
#  the dashboard can always slice migration progress by source product.
# ===================================================================================

# Known legacy AV/EDR products. Each entry describes how to recognise an export of
# that product from its CSV header signature, plus the id columns worth preferring.
#   Vendor    - company name, used for grouping several products of one vendor
#   Product   - the specific product label written to every ingested row
#   Any       - header names of which AT LEAST ONE must be present (a weak signal)
#   All       - header names that must ALL be present (a strong signal)
#   IdColumns - product-specific unique-id headers, tried before the generic list
$script:LegacyAvCatalog = @(
    @{ Vendor='Trend Micro';   Product='Trend Micro Deep Security'; All=@(); Any=@('host guid','agent guid','deep security manager'); IdColumns=@('Host GUID','Agent GUID') }
    @{ Vendor='Trend Micro';   Product='Trend Micro Apex One';      All=@(); Any=@('scan method','apex one','officescan','smart scan agent'); IdColumns=@('GUID','Endpoint GUID') }
    @{ Vendor='Trend Micro';   Product='Trend Micro Vision One';    All=@(); Any=@('endpoint sensor','vision one','xdr endpoint'); IdColumns=@('Agent GUID','Endpoint GUID') }
    @{ Vendor='Broadcom';      Product='Symantec Endpoint Protection'; All=@(); Any=@('sep version','symantec endpoint','computer id','sepm','sep client'); IdColumns=@('Computer ID','Hardware Key','Unique ID') }
    @{ Vendor='Trellix';       Product='McAfee ePolicy Orchestrator'; All=@(); Any=@('epo','agent guid (epo)','managed state','epolicy','node name'); IdColumns=@('Agent GUID','Node ID','ParentID') }
    @{ Vendor='Trellix';       Product='Trellix Endpoint Security'; All=@(); Any=@('trellix','hx agent','agent_id'); IdColumns=@('Agent ID','Agent_ID') }
    @{ Vendor='Sophos';        Product='Sophos Intercept X';       All=@(); Any=@('sophos','tamper protection enabled','health status'); IdColumns=@('Endpoint ID','Machine ID','id') }
    @{ Vendor='CrowdStrike';   Product='CrowdStrike Falcon';       All=@(); Any=@('aid','agent id (aid)','cid','falcon','reduced functionality mode'); IdColumns=@('aid','device_id','AID') }
    @{ Vendor='SentinelOne';   Product='SentinelOne Singularity';  All=@(); Any=@('agent version','network status','sentinelone','mitigation mode','site name'); IdColumns=@('Agent UUID','uuid','Agent ID') }
    @{ Vendor='Kaspersky';     Product='Kaspersky Endpoint Security'; All=@(); Any=@('kaspersky','klhost','administration server','ksc'); IdColumns=@('Host name','KLHST_WKS_HOSTNAME','Host ID') }
    @{ Vendor='ESET';          Product='ESET Endpoint Protection'; All=@(); Any=@('eset','esmc','computer uuid','protect server'); IdColumns=@('Computer UUID','UUID') }
    @{ Vendor='VMware';        Product='Carbon Black';             All=@(); Any=@('carbon black','sensor id','cb defense','sensor version'); IdColumns=@('Sensor ID','device_id','Device ID') }
    @{ Vendor='Broadcom';      Product='Cylance Protect';          All=@(); Any=@('cylance','zone names','agent version (cylance)'); IdColumns=@('Device Id','Device ID') }
    @{ Vendor='Bitdefender';   Product='Bitdefender GravityZone';  All=@(); Any=@('bitdefender','gravityzone','endpoint type'); IdColumns=@('Endpoint ID','Machine ID') }
    @{ Vendor='OpenText';      Product='Webroot SecureAnywhere';   All=@(); Any=@('webroot','secureanywhere','keycode'); IdColumns=@('Device ID','Instance MID') }
    @{ Vendor='Cisco';         Product='Cisco Secure Endpoint';    All=@(); Any=@('cisco secure endpoint','amp for endpoints','connector guid'); IdColumns=@('Connector GUID','GUID') }
    @{ Vendor='Palo Alto';     Product='Cortex XDR';               All=@(); Any=@('cortex','endpoint alias','agent id (cortex)'); IdColumns=@('Endpoint ID','Agent ID') }
    @{ Vendor='Malwarebytes';  Product='Malwarebytes EDR';         All=@(); Any=@('malwarebytes','nebula','endpoint group'); IdColumns=@('Machine ID','Endpoint ID') }
    @{ Vendor='Check Point';   Product='Check Point Harmony Endpoint'; All=@(); Any=@('harmony','check point','endpoint security client'); IdColumns=@('Device ID','Machine ID') }
    @{ Vendor='F-Secure';      Product='WithSecure Elements';      All=@(); Any=@('withsecure','f-secure','protection status'); IdColumns=@('Device ID') }
    @{ Vendor='Sophos';        Product='Sophos Central';           All=@(); Any=@('sophos central'); IdColumns=@('Endpoint ID') }
)

function Get-LegacyAvCatalog {
    <# Returns the built-in catalog of recognised legacy AV/EDR products. Exposed so callers
       (and the docs) can enumerate what auto-detection understands. #>
    return $script:LegacyAvCatalog
}

function Resolve-LegacyVendor {
    <# Maps a free-text product label to its vendor using the catalog. Falls back to matching on a
       leading vendor word, then to the product label itself, so a hand-typed -SourceProduct such
       as "Contoso AV" still yields a usable vendor rather than an empty column. #>
    param([string]$Product)
    if ([string]::IsNullOrWhiteSpace($Product)) { return "" }
    $p = $Product.Trim()
    $lc = $p.ToLowerInvariant()
    foreach ($e in $script:LegacyAvCatalog) {
        if ($e.Product.ToLowerInvariant() -eq $lc) { return $e.Vendor }
    }
    foreach ($e in $script:LegacyAvCatalog) {
        if ($lc -like ("*" + $e.Vendor.ToLowerInvariant() + "*")) { return $e.Vendor }
        if ($lc -like ("*" + $e.Product.ToLowerInvariant() + "*")) { return $e.Vendor }
    }
    return $p
}

function Resolve-CsvColumn {
    <# Picks the first header from a candidate list that matches (case/space-insensitive), else the
       first header whose name matches the -Fallback regex, else $null. #>
    param([string[]]$Columns, [string[]]$Candidates, [string]$Fallback)
    foreach ($c in $Candidates) {
        if ([string]::IsNullOrWhiteSpace($c)) { continue }
        $hit = $Columns | Where-Object { $_.Trim().ToLowerInvariant() -eq $c.Trim().ToLowerInvariant() } | Select-Object -First 1
        if ($hit) { return $hit }
    }
    if ($Fallback) {
        $hit = $Columns | Where-Object { $_.ToLowerInvariant() -match $Fallback } | Select-Object -First 1
        if ($hit) { return $hit }
    }
    return $null
}

function Get-LegacyProductFromColumns {
    <# Infers which legacy AV/EDR product an export came from, using the catalog's header
       signatures. Scores every catalog entry (all 'All' headers required; each 'Any' hit adds a
       point) and returns the best-scoring product, or the neutral label 'Legacy AV/EDR' when
       nothing matches - so an unknown vendor's export still ingests and is still labelled. #>
    param([string[]]$Columns)
    $lc = @($Columns | ForEach-Object { $_.Trim().ToLowerInvariant() })
    $bestScore = 0
    $best = $null
    foreach ($e in $script:LegacyAvCatalog) {
        $ok = $true
        foreach ($req in $e.All) { if ($lc -notcontains $req) { $ok = $false; break } }
        if (-not $ok) { continue }
        $score = @($e.All).Count * 2
        foreach ($a in $e.Any) {
            foreach ($h in $lc) { if ($h -eq $a -or $h -like "*$a*") { $score++; break } }
        }
        if ($score -gt $bestScore) { $bestScore = $score; $best = $e }
    }
    if ($best -and $bestScore -gt 0) { return $best.Product }
    return 'Legacy AV/EDR'
}

function Get-LegacyIdColumnCandidates {
    <# Id-column names to try for a detected product: the product's own preferred ids first, then a
       generic cross-vendor list. #>
    param([string]$Product)
    $pref = @()
    if ($Product) {
        foreach ($e in $script:LegacyAvCatalog) {
            if ($e.Product -eq $Product) { $pref = @($e.IdColumns); break }
        }
    }
    return @($pref + @(
        'LegacyId','TrendId','Host GUID','Endpoint GUID','Agent GUID','Computer ID','Sensor ID','Connector GUID',
        'Agent UUID','Computer UUID','Endpoint ID','Machine ID','Device ID','Device Id','device_id','Hardware Key',
        'Instance ID','Agent ID','aid','AID','GUID','UUID','Host ID','Machine GUID','Unique ID','id'))
}

function Get-LegacyDeviceRecords {
    <# Reads any legacy AV/EDR CSV export - a native vendor export, or the normalised
       LegacyId,DeviceName,LegacyProduct template - and returns one record per row with the
       minimum fields the dashboard ingests:

         LegacyId      - the source tool's own unique device identifier, used as the de-dup key.
         DeviceName    - the host/endpoint name, matched against the Defender inventory.
         LegacyProduct - WHICH product the row came from. Always populated on every row, so a
                         customer migrating from several tools keeps them distinguishable.
         LegacyVendor  - the vendor behind that product, for higher-level grouping.

       Detection order for the product label: an explicit -SourceProduct override, then a
       per-row LegacyProduct/TrendSource column in the file itself (so a hand-merged multi-tool
       CSV keeps its per-row labels), then auto-detection from the header signature. #>
    param([string]$CsvPath, [string]$SourceProduct, [string]$SourceVendor)
    if (-not (Test-Path -LiteralPath $CsvPath)) { throw "Legacy AV/EDR export CSV not found: $CsvPath" }
    $rows = @(Import-Csv -LiteralPath $CsvPath)
    if ($rows.Count -eq 0) { return @() }
    $cols = @($rows[0].PSObject.Properties.Name)

    $nameCol = Resolve-CsvColumn -Columns $cols -Fallback 'host|endpoint|computer|device|machine|node|name' -Candidates @(
        'DeviceName','Endpoint Name','Endpoint','Host Name','Hostname','Host','Computer Name','Computer',
        'Device Name','Device','Machine Name','Machine','Agent Host Name','Node Name','Managed Server',
        'Sensor Name','Client Name','Name')
    if (-not $nameCol) { $nameCol = $cols[0] }

    # A per-row product column keeps multi-tool exports separable. TrendSource is accepted for
    # backwards compatibility with stores written by earlier versions of this dashboard.
    $prodCol   = Resolve-CsvColumn -Columns $cols -Candidates @('LegacyProduct','TrendSource','SourceProduct','Product','AV Product','Security Product')
    $vendorCol = Resolve-CsvColumn -Columns $cols -Candidates @('LegacyVendor','Vendor','Manufacturer')

    # Detected product drives both the fallback label and the preferred id columns.
    $detected = Get-LegacyProductFromColumns -Columns $cols
    $idCol = Resolve-CsvColumn -Columns $cols -Fallback 'guid|uuid|\bid\b' -Candidates (Get-LegacyIdColumnCandidates -Product $detected)

    # An explicit override always wins; otherwise fall back to the detected product per row.
    $fallbackProduct = $SourceProduct
    if (-not $fallbackProduct) { $fallbackProduct = $detected }

    $idLabel = '(none)'
    if ($idCol) { $idLabel = $idCol }
    $prodLabel = $fallbackProduct
    if ($prodCol -and -not $SourceProduct) { $prodLabel = "per-row column '$prodCol'" }
    Write-Ok ("Legacy export: name column '{0}', id column '{1}', product '{2}' ({3} rows)" -f $nameCol, $idLabel, $prodLabel, $rows.Count)

    $out = New-Object System.Collections.ArrayList
    foreach ($r in $rows) {
        $name = ""
        if ($nameCol) { $name = [string]$r.$nameCol }
        if ([string]::IsNullOrWhiteSpace($name)) { continue }

        $id = ""
        if ($idCol) { $id = [string]$r.$idCol }

        # Product label, resolved per row so one file may legitimately carry several products.
        $rowProduct = ""
        if ($SourceProduct) { $rowProduct = $SourceProduct }
        elseif ($prodCol)   { $rowProduct = [string]$r.$prodCol }
        if ([string]::IsNullOrWhiteSpace($rowProduct)) { $rowProduct = $fallbackProduct }
        if ([string]::IsNullOrWhiteSpace($rowProduct)) { $rowProduct = 'Legacy AV/EDR' }

        $rowVendor = ""
        if ($SourceVendor)  { $rowVendor = $SourceVendor }
        elseif ($vendorCol) { $rowVendor = [string]$r.$vendorCol }
        if ([string]::IsNullOrWhiteSpace($rowVendor)) { $rowVendor = Resolve-LegacyVendor -Product $rowProduct }

        [void]$out.Add([pscustomobject]@{
            LegacyId      = $id.Trim()
            DeviceName    = $name.Trim()
            LegacyProduct = $rowProduct.Trim()
            LegacyVendor  = $rowVendor.Trim()
        })
    }
    return $out.ToArray()
}

function Get-LegacyDeviceNames {
    <# Convenience helper: just the device/host names from a legacy AV/EDR export. #>
    param([string]$CsvPath)
    return @(Get-LegacyDeviceRecords -CsvPath $CsvPath | ForEach-Object { $_.DeviceName })
}

function Get-LegacyRecordField {
    <# Reads a field from a record, tolerating both the current LegacyXxx names and the legacy
       TrendXxx names written by earlier versions of this dashboard. #>
    param($Record, [string]$Name, [string]$Legacy, [string]$Default = "")
    if ($null -eq $Record) { return $Default }
    $props = $Record.PSObject.Properties
    if ($props[$Name] -and -not [string]::IsNullOrWhiteSpace([string]$Record.$Name)) { return [string]$Record.$Name }
    if ($Legacy -and $props[$Legacy] -and -not [string]::IsNullOrWhiteSpace([string]$Record.$Legacy)) { return [string]$Record.$Legacy }
    return $Default
}

function Get-LegacyDedupKey {
    <# De-duplication key for a legacy record: the source tool's unique id when present, else a
       normalised host|product fallback so exports without a usable id still de-duplicate.
       The product is part of the fallback key on purpose: the same host reported by two different
       legacy tools is two migration facts, not one. #>
    param($Record)
    $id = Get-LegacyRecordField -Record $Record -Name 'LegacyId' -Legacy 'TrendId'
    if (-not [string]::IsNullOrWhiteSpace($id)) { return "id:" + $id.Trim().ToLowerInvariant().Trim('{','}') }
    $shortName = Get-NormalizedDeviceName ([string]$Record.DeviceName)
    $domain    = Get-NormalizedDomainSuffix ([string]$Record.DeviceName)
    $product   = (Get-LegacyRecordField -Record $Record -Name 'LegacyProduct' -Legacy 'TrendSource').ToLowerInvariant()
    return "name:$shortName|$domain|$product"
}

function Read-LegacyStore {
    <# Reads the local legacy-inventory master store (git-ignored CSV of previously ingested
       devices). Accepts stores written by earlier Trend-only versions and upgrades their columns
       in place, so an existing deployment keeps its accumulated history. Returns an empty array
       when the store does not exist. #>
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return @() }
    $rows = @(Import-Csv -LiteralPath $Path)
    $out = New-Object System.Collections.ArrayList
    foreach ($r in $rows) {
        if ([string]::IsNullOrWhiteSpace([string]$r.DeviceName)) { continue }
        $product = Get-LegacyRecordField -Record $r -Name 'LegacyProduct' -Legacy 'TrendSource' -Default 'Legacy AV/EDR'
        $vendor  = Get-LegacyRecordField -Record $r -Name 'LegacyVendor'
        if ([string]::IsNullOrWhiteSpace($vendor)) { $vendor = Resolve-LegacyVendor -Product $product }
        [void]$out.Add([pscustomobject]@{
            LegacyId      = Get-LegacyRecordField -Record $r -Name 'LegacyId' -Legacy 'TrendId'
            DeviceName    = [string]$r.DeviceName
            LegacyProduct = $product
            LegacyVendor  = $vendor
            FirstSeen     = Get-LegacyRecordField -Record $r -Name 'FirstSeen'
        })
    }
    return $out.ToArray()
}

function Merge-LegacyStore {
    <# Merges freshly parsed legacy records into the existing master store.
         -Mode Replace : the new export becomes the whole list (de-duplicated on the source id).
         -Mode Append  : keep everything already ingested and add only records whose id (or
                         host|product fallback) is not already present. This is the mode to use
                         when migrating from SEVERAL products: ingest each vendor's export in
                         turn with -Mode Append and every row keeps its own product label.
       Returns the merged, de-duplicated record set. #>
    param([object[]]$Existing, [object[]]$New, [ValidateSet('Replace','Append')][string]$Mode = 'Replace')
    $now = (Get-Date).ToString('yyyy-MM-dd')
    $result = New-Object System.Collections.ArrayList
    $seen = @{}
    $addRecord = {
        param($rec, $firstSeen)
        $k = Get-LegacyDedupKey $rec
        if ($seen.ContainsKey($k)) { return }
        $seen[$k] = $true
        $product = Get-LegacyRecordField -Record $rec -Name 'LegacyProduct' -Legacy 'TrendSource' -Default 'Legacy AV/EDR'
        $vendor  = Get-LegacyRecordField -Record $rec -Name 'LegacyVendor'
        if ([string]::IsNullOrWhiteSpace($vendor)) { $vendor = Resolve-LegacyVendor -Product $product }
        $seenDate = $firstSeen
        if ([string]::IsNullOrWhiteSpace($seenDate)) { $seenDate = $now }
        [void]$result.Add([pscustomobject]@{
            LegacyId      = Get-LegacyRecordField -Record $rec -Name 'LegacyId' -Legacy 'TrendId'
            DeviceName    = [string]$rec.DeviceName
            LegacyProduct = $product
            LegacyVendor  = $vendor
            FirstSeen     = $seenDate
        })
    }
    if ($Mode -eq 'Append') {
        foreach ($e in $Existing) {
            & $addRecord $e (Get-LegacyRecordField -Record $e -Name 'FirstSeen' -Default $now)
        }
    }
    foreach ($n in $New) { & $addRecord $n $now }
    return $result.ToArray()
}

function Write-LegacyStore {
    <# Persists the master store to CSV (LegacyId,DeviceName,LegacyProduct,LegacyVendor,FirstSeen). #>
    param([string]$Path, [object[]]$Records)
    if (-not $Path) { return }
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    if (-not $Records -or $Records.Count -eq 0) {
        Set-Content -LiteralPath $Path -Value "LegacyId,DeviceName,LegacyProduct,LegacyVendor,FirstSeen" -Encoding UTF8
        return
    }
    $Records | Select-Object LegacyId, DeviceName, LegacyProduct, LegacyVendor, FirstSeen |
        Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
}

function Get-LegacyProductBreakdown {
    <# Summarises a record or mapping set by legacy product, so the console output tells the
       operator exactly what came from which tool. Returns rows of
       Product / Vendor / Devices / Migrated / Pending / NotFound (the last three are 0 when the
       input is a plain inventory rather than a mapping). #>
    param([object[]]$Records)
    $groups = [ordered]@{}
    foreach ($r in $Records) {
        if ($null -eq $r) { continue }
        $p = Get-LegacyRecordField -Record $r -Name 'LegacyProduct' -Legacy 'TrendSource' -Default 'Legacy AV/EDR'
        if (-not $groups.Contains($p)) {
            $groups[$p] = [pscustomobject]@{
                Product  = $p
                Vendor   = Get-LegacyRecordField -Record $r -Name 'LegacyVendor' -Default (Resolve-LegacyVendor -Product $p)
                Devices  = 0
                Migrated = 0
                Pending  = 0
                NotFound = 0
            }
        }
        $g = $groups[$p]
        $g.Devices++
        $status = Get-LegacyRecordField -Record $r -Name 'MigrationStatus'
        switch ($status) {
            'Migrated to Defender'    { $g.Migrated++ }
            'Matched - not onboarded' { $g.Pending++ }
            'Not found in Defender'   { $g.NotFound++ }
        }
    }
    return @($groups.Values)
}

function Write-LegacyProductBreakdown {
    <# Prints the per-product breakdown. With several legacy tools in flight this is the line the
       operator actually needs: which product still has devices left to migrate. #>
    param([object[]]$Records, [switch]$WithStatus)
    $rows = @(Get-LegacyProductBreakdown -Records $Records)
    if ($rows.Count -eq 0) { return }
    Write-Ok "By legacy product:"
    foreach ($r in ($rows | Sort-Object -Property @{ Expression = { $_.Devices }; Descending = $true })) {
        if ($WithStatus) {
            $pct = 0
            if ($r.Devices -gt 0) { $pct = [math]::Round(100.0 * $r.Migrated / $r.Devices, 1) }
            Write-Ok ("  {0,-38} {1,6} devices | {2,6} migrated ({3}%) | {4,5} pending | {5,5} not found" -f `
                $r.Product, $r.Devices, $r.Migrated, $pct, $r.Pending, $r.NotFound)
        } else {
            Write-Ok ("  {0,-38} {1,6} devices" -f $r.Product, $r.Devices)
        }
    }
}

function Get-LegacyDefenderMapping {
    <# Core matcher. Requires an EXACT normalised short-hostname match between each legacy device
       and a Defender device; fuzzy tolerance is applied ONLY to the DNS domain suffix. So
       'host.contoso.com' still matches 'host.contoso.local', a short name 'host' matches any
       'host.<domain>', but two different hostnames never fuzzy-match each other.

       De-duplication is keyed on the source tool's unique id (falling back to host|product when
       no id is present). Every output row carries LegacyProduct and LegacyVendor, so migration
       progress stays attributable to the specific tool it came from even when the estate is being
       migrated off several products at once.

       Accepts -LegacyRecords (objects with LegacyId/DeviceName/LegacyProduct) or, for backward
       compatibility, a flat -LegacyNames string array. #>
    param([object[]]$LegacyRecords, [string[]]$LegacyNames, [object[]]$Inventory, [int]$MatchThreshold = 82,
          [string]$DefaultProduct = 'Legacy AV/EDR')
    if ($MatchThreshold -lt 0)   { $MatchThreshold = 0 }
    if ($MatchThreshold -gt 100) { $MatchThreshold = 100 }
    if (-not $LegacyRecords -or $LegacyRecords.Count -eq 0) {
        $LegacyRecords = @($LegacyNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object {
                [pscustomobject]@{
                    LegacyId      = ""
                    DeviceName    = [string]$_
                    LegacyProduct = $DefaultProduct
                    LegacyVendor  = (Resolve-LegacyVendor -Product $DefaultProduct)
                }
            })
    }
    # Index Defender devices by normalised short hostname -> every device that shares that hostname
    # (there can be several across different domains; the domain suffix decides which one wins).
    $byHost = @{}
    foreach ($d in $Inventory) {
        $h = Get-NormalizedDeviceName $d.DeviceName
        if ($h -eq "") { continue }
        if (-not $byHost.ContainsKey($h)) { $byHost[$h] = New-Object System.Collections.ArrayList }
        [void]$byHost[$h].Add($d)
    }
    $seen = @{}
    $out = New-Object System.Collections.ArrayList
    foreach ($rec in $LegacyRecords) {
        $raw     = [string]$rec.DeviceName
        $legId   = Get-LegacyRecordField -Record $rec -Name 'LegacyId' -Legacy 'TrendId'
        $product = Get-LegacyRecordField -Record $rec -Name 'LegacyProduct' -Legacy 'TrendSource' -Default $DefaultProduct
        $vendor  = Get-LegacyRecordField -Record $rec -Name 'LegacyVendor'
        if ([string]::IsNullOrWhiteSpace($vendor)) { $vendor = Resolve-LegacyVendor -Product $product }
        $shortName = Get-NormalizedDeviceName $raw
        $domain    = Get-NormalizedDomainSuffix $raw
        if ($shortName -eq "") { continue }
        $dedup = Get-LegacyDedupKey $rec
        if ($seen.ContainsKey($dedup)) { continue }
        $seen[$dedup] = $true

        $match = $null; $score = 0; $mtype = "Unmatched"
        if ($byHost.ContainsKey($shortName)) {
            # Hostname matches exactly; the only fuzzy decision left is which candidate's DNS domain
            # is closest. An identical or absent domain is an exact match; a different domain is
            # accepted only when it stays within the fuzzy tolerance.
            $best = -1; $bestDev = $null; $bestType = "Fuzzy"
            foreach ($d in $byHost[$shortName]) {
                $ddom = Get-NormalizedDomainSuffix $d.DeviceName
                if ($domain -eq $ddom -or $domain -eq "" -or $ddom -eq "") { $s = 100; $type = "Exact" }
                else { $s = Get-NameSimilarity -A $domain -B $ddom -MinScore $MatchThreshold; $type = "Fuzzy" }
                $better = $s -gt $best
                if (-not $better -and $s -eq $best -and $null -ne $bestDev) {
                    $better = ([string]$d.OnboardingStatus -eq "Onboarded" -and [string]$bestDev.OnboardingStatus -ne "Onboarded")
                }
                if ($better) { $best = $s; $bestDev = $d; $bestType = $type }
            }
            if ($bestDev -and ($bestType -eq "Exact" -or $best -ge $MatchThreshold)) {
                $match = $bestDev; $score = $best; $mtype = $bestType
            } else {
                $score = [Math]::Max(0, $best)
            }
        }

        if ($match) {
            $onboard = [string]$match.OnboardingStatus
            $status = "Matched - not onboarded"
            if ($onboard -eq "Onboarded") { $status = "Migrated to Defender" }
            [void]$out.Add([pscustomobject]@{
                LegacyId           = $legId
                LegacyProduct      = $product
                LegacyVendor       = $vendor
                LegacyDeviceName   = $raw
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
                LegacyId           = $legId
                LegacyProduct      = $product
                LegacyVendor       = $vendor
                LegacyDeviceName   = $raw
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

function ConvertTo-LegacyMigrationSeed {
    <# Serialises mapping objects to the compact JSON array the LegacyAvMigration partition expects. #>
    param([object[]]$Mapping)
    if (-not $Mapping -or $Mapping.Count -eq 0) { return "[]" }
    $json = ($Mapping | ConvertTo-Json -Depth 4 -Compress)
    if ($Mapping.Count -eq 1) { $json = "[$json]" }   # single record -> keep it an array
    return $json
}

function New-LegacyMigrationSeedOverride {
    <# Generates the legacy-AV -> Defender mapping at deploy time and returns a Get-Parts override
       that embeds it in the LegacyAvMigration table (__LEGACYMIGRATION_SEED_B64__). Returns $null
       when the model has no placeholder. When -LegacyCsv is not supplied, the previously ingested
       store is re-pushed (so an update-in-place never silently empties the table); when there is
       no store either, an empty seed is injected so the table exists but has no rows. On any
       failure it injects an empty seed and warns, so deployment still succeeds.

       -LegacyMode Replace (default) uses the supplied export as the whole legacy list;
       -LegacyMode Append merges the export into the git-ignored master store (-InventoryStore),
       de-duplicating on the source tool's unique id. Append is the mode for estates migrating off
       SEVERAL products: run it once per vendor export and each row keeps its own product label. #>
    param([string]$ModelDir, [string]$TenantId, [string]$ClientId, [string]$ClientSecret,
          [string]$LegacyCsv, [int]$MatchThreshold = 82,
          [ValidateSet('Replace','Append')][string]$LegacyMode = 'Replace',
          [string]$InventoryStore, [string]$SourceProduct, [string]$SourceVendor,
          [switch]$AllowEmptyLegacyTable)
    $path = Join-Path $ModelDir "definition\tables\LegacyAvMigration.tmdl"
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $txt = Get-Content -LiteralPath $path -Raw
    if ($txt -notmatch '__LEGACYMIGRATION_SEED_B64__') { return $null }
    if (-not $InventoryStore) { $InventoryStore = Join-Path $PSScriptRoot "legacy-inventory.local.csv" }
    # Upgrade path: a deployment created by a pre-2.x (Trend-only) release keeps its ingested
    # devices in trend-inventory.local.csv. Adopt that file on the first vendor-neutral deploy so
    # an update-in-place carries the existing list forward instead of publishing an empty table.
    if (-not (Test-Path -LiteralPath $InventoryStore)) {
        $preTwoStore = Join-Path (Split-Path -Parent $InventoryStore) "trend-inventory.local.csv"
        if (Test-Path -LiteralPath $preTwoStore) {
            try {
                Copy-Item -LiteralPath $preTwoStore -Destination $InventoryStore -Force
                Write-Ok "Upgrade: adopted the pre-2.x legacy list '$preTwoStore' into '$InventoryStore'."
            } catch {
                Write-Warn2 "Could not copy the pre-2.x legacy list ($($_.Exception.Message)); reading it in place."
                $InventoryStore = $preTwoStore
            }
        }
    }
    $seedJson = "[]"
    $storeExists = Test-Path -LiteralPath $InventoryStore
    if (-not $LegacyCsv -and -not $storeExists) {
        Write-Warn2 "No -LegacyCsv supplied and no saved legacy AV/EDR list found - the migration table will be empty. Pass -LegacyCsv <export.csv> to populate it."
    } else {
        $hadStoredDevices = $false
        try {
            $existing = Read-LegacyStore -Path $InventoryStore
            if ($existing.Count -gt 0) { $hadStoredDevices = $true }
            if ($LegacyCsv) {
                $newRecs = @(Get-LegacyDeviceRecords -CsvPath $LegacyCsv -SourceProduct $SourceProduct -SourceVendor $SourceVendor)
                $merged  = Merge-LegacyStore -Existing $existing -New $newRecs -Mode $LegacyMode
                if ($merged.Count -eq 0) { throw "no device names found in the legacy export or master store" }
                Backup-LocalStore -Path $InventoryStore | Out-Null
                Write-LegacyStore -Path $InventoryStore -Records $merged
                Write-Ok "Legacy list ($LegacyMode): ingested $($newRecs.Count) from export; $($merged.Count) unique devices now in the store ($InventoryStore)"
            } else {
                # No new export on this run: re-use (re-push) the previously ingested list instead
                # of emptying it, so an update-in-place preserves the ingested data.
                $merged = $existing
                if ($merged.Count -eq 0) { throw "the saved legacy AV/EDR list is empty" }
                Write-Ok "Legacy list preserved: re-using $($merged.Count) devices previously ingested into the store ($InventoryStore)"
            }
            Write-LegacyProductBreakdown -Records $merged
            $inv = Get-DefenderInventory -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret
            $map = Get-LegacyDefenderMapping -LegacyRecords $merged -Inventory $inv -MatchThreshold $MatchThreshold
            $seedJson = ConvertTo-LegacyMigrationSeed -Mapping $map
            $migr = @($map | Where-Object { $_.MigrationStatus -eq "Migrated to Defender" }).Count
            $pend = @($map | Where-Object { $_.MigrationStatus -eq "Matched - not onboarded" }).Count
            $miss = @($map | Where-Object { $_.MigrationStatus -eq "Not found in Defender" }).Count
            Write-Ok "Legacy migration mapped: $($map.Count) devices - $migr migrated, $pend matched/not onboarded, $miss not in Defender"
            Write-LegacyProductBreakdown -Records $map -WithStatus
        } catch {
            # Publishing an empty seed over a workspace that already holds migration data would
            # DESTROY it (updateDefinition replaces the table). When devices were already ingested,
            # fail the deploy instead so the live table keeps its current contents, and let the
            # operator opt in explicitly if an empty table really is wanted.
            if ($hadStoredDevices -and -not $AllowEmptyLegacyTable) {
                throw ("Could not build the legacy AV/EDR migration mapping ($($_.Exception.Message)). " +
                       "Refusing to publish an EMPTY migration table over the $(@(Read-LegacyStore -Path $InventoryStore).Count) device(s) already ingested, " +
                       "because that would overwrite the live data. Fix the cause (usually Defender API credentials/permissions) and re-run, " +
                       "or pass -AllowEmptyLegacyTable to publish an empty table deliberately.")
            }
            Write-Warn2 "Could not build the legacy AV/EDR migration mapping ($($_.Exception.Message)). Deploying with an empty migration table."
        }
    }
    $seedB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($seedJson))
    return @{ "definition/tables/LegacyAvMigration.tmdl" = $txt.Replace('__LEGACYMIGRATION_SEED_B64__', $seedB64) }
}

# ----------------------------------------------------------------------------------
# Backward-compatible aliases. Earlier releases of this dashboard exposed Trend-only
# names; scripts or forks calling them keep working against the vendor-neutral core.
# ----------------------------------------------------------------------------------
Set-Alias -Name Resolve-TrendColumn        -Value Resolve-CsvColumn            -Scope Script -Force
Set-Alias -Name Get-TrendSourceFromColumns -Value Get-LegacyProductFromColumns -Scope Script -Force
Set-Alias -Name Get-TrendDeviceNames       -Value Get-LegacyDeviceNames        -Scope Script -Force
Set-Alias -Name Get-TrendDedupKey          -Value Get-LegacyDedupKey           -Scope Script -Force
Set-Alias -Name Read-TrendStore            -Value Read-LegacyStore             -Scope Script -Force
Set-Alias -Name Merge-TrendStore           -Value Merge-LegacyStore            -Scope Script -Force
Set-Alias -Name Write-TrendStore           -Value Write-LegacyStore            -Scope Script -Force
Set-Alias -Name ConvertTo-TrendMigrationSeed -Value ConvertTo-LegacyMigrationSeed -Scope Script -Force


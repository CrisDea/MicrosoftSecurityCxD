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
    param([string]$ProjectPath)
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
        $md = Get-ChildItem -LiteralPath $ProjectPath -Directory -Filter "*.SemanticModel" -ErrorAction SilentlyContinue | Select-Object -First 1
        $rd = Get-ChildItem -LiteralPath $ProjectPath -Directory -Filter "*.Report"        -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $md -or -not $rd) { throw "Could not find a *.SemanticModel and a *.Report folder under '$ProjectPath'." }
        Write-Ok "PBIP project found ($([IO.Path]::GetFileName($md.FullName)) + $([IO.Path]::GetFileName($rd.FullName)))"
    }
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
            Write-Ok "Trend history generated: $($rows.Count) day/group rows"
        } else {
            Write-Warn2 "Advanced-hunting trend query returned no rows - trend will be empty until more history accrues."
        }
    } catch {
        Write-Warn2 "Could not generate trend history ($($_.Exception.Message)). Deploying with an empty trend; re-run once the app has WindowsDefenderATP AdvancedQuery.Read.All / Machine.Read.All consented."
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
    if (-not $TrendCsv -and -not (($TrendMode -eq 'Append') -and (Test-Path -LiteralPath $InventoryStore))) {
        Write-Warn2 "No -TrendCsv supplied - TrendMigration will be empty. Pass -TrendCsv <trend-export.csv> to populate the migration mapping."
    } else {
        try {
            $newRecs = if ($TrendCsv) { @(Get-TrendDeviceRecords -TrendCsv $TrendCsv -Source $TrendSource) } else { @() }
            $existing = Read-TrendStore -Path $InventoryStore
            $merged = Merge-TrendStore -Existing $existing -New $newRecs -Mode $TrendMode
            if ($merged.Count -eq 0) { throw "no device names found in the Trend export or master store" }
            Write-TrendStore -Path $InventoryStore -Records $merged
            Write-Ok "Trend list ($TrendMode): $($merged.Count) unique devices in store ($InventoryStore)"
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

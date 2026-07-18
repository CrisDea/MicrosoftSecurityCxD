<#
.SYNOPSIS
    One-button publish of the Defender Migration Dashboard to a Power BI / Microsoft Fabric
    workspace in YOUR tenant. Headless - no Power BI Desktop required.

.DESCRIPTION
    Publishes the semantic model and report from the local project folder (..\pbip-project) to a
    Power BI / Fabric workspace, links the report to the model, binds the data-source credentials to
    your Entra app registration (Service Principal), enables a scheduled refresh, and runs a first
    refresh so the report shows real data straight away.

    The dashboard reads your tenant's Defender data through the Microsoft Defender for Endpoint
    export-assessment REST APIs (api.securitycenter.microsoft.com) using an Entra app registration
    (client credentials / Service Principal), which scales to 100k+ devices. The 30-day deployment-
    trend history is generated at deploy time from the Defender advanced-hunting API and embedded in
    the model, because the advanced-hunting POST cannot run during a cloud scheduled refresh. Supply
    the app's tenantId/clientId/clientSecret via -ConfigPath config.json (or -TenantId -ClientId
    -ClientSecret). The secret is bound to the dataset over REST - it is never written to the
    committed project files.

    The app registration needs these Microsoft Defender for Endpoint (WindowsDefenderATP) application
    permissions, admin-consented: Machine.Read.All, Vulnerability.Read.All, Software.Read.All and
    AdvancedQuery.Read.All.

    You can run it again at any time - it updates the existing model and report rather than creating
    duplicates, and regenerates the trend history.

    Runs on PowerShell 5.1 or 7. The only extra tool it needs is the Azure CLI, and only when you
    sign in interactively (not when you use a service principal).

.PARAMETER WorkspaceName
    Display name of the target workspace. Used to find an existing workspace, or (with -CapacityId)
    to create one. Default: "Defender Migration Dashboard".

.PARAMETER WorkspaceId
    GUID of an existing workspace. Overrides -WorkspaceName lookup when supplied.

.PARAMETER CapacityId
    Fabric / Premium / PPU capacity GUID. Needed only if the workspace does NOT already exist and
    you want this script to create it. A semantic model must live on a capacity.

.PARAMETER SelectWorkspace
    Interactively enumerate capacity-backed workspaces and pick one (or create a new one).
    Not compatible with service-principal auth (which is non-interactive).

.PARAMETER TenantId
    Optional tenant GUID to sign in to. If omitted, the current az session is reused.

.PARAMETER ModelName
    Display name for the semantic model item. Default: "Defender Migration". Can also be set as
    "modelName" in config.json (an explicit -ModelName wins over config).

.PARAMETER ReportName
    Display name for the report item. Default: "Defender Migration". Can also be set as
    "reportName" in config.json (an explicit -ReportName wins over config).

.PARAMETER ProjectPath
    Path to the PBIP project folder. Default: ..\pbip-project relative to this script.

.PARAMETER SkipRefresh
    Skip the post-publish dataset refresh.

.PARAMETER SkipSchedule
    Skip enabling the native scheduled refresh.

.PARAMETER RefreshTimes
    Times of day (24h "HH:mm") for the scheduled refresh. Default: 2x/day (06:00 and 18:00).
    The Defender Vulnerability Management snapshot tables refresh ~once a day, so twice daily is
    sufficient; pass more times only if you need finer granularity.

.PARAMETER RefreshTimeZone
    Time-zone id for the schedule (e.g. "UTC", "GMT Standard Time"). Default: "UTC".

.PARAMETER Wait
    Poll the dataset refresh until it reaches a terminal state (Completed/Failed) before exiting.

.PARAMETER Force
    Deploy even when the version check finds the workspace is already at (or newer than) the local
    version. Use it to refresh live data or re-seed the trend/AV/Trend-migration tables without a
    version bump.

.PARAMETER SkipVersionCheck
    Skip the local-vs-GitHub-vs-workspace version comparison entirely (offline/air-gapped runs).
    The post-publish version stamp is also skipped.

.PARAMETER CheckVersionOnly
    Read-only mode: report the local, GitHub and live workspace versions, say whether an update is
    available, then exit WITHOUT deploying. This needs only workspace read access (Item.Read.All /
    Viewer), so a low-privilege identity can check for updates without any deploy rights.

.PARAMETER SkipGitHubCheck
    Skip only the GitHub raw-CHANGELOG lookup (still compares local vs the live workspace). Can also
    be set as "skipGitHubVersionCheck" in config.json.

.PARAMETER ConfigPath
    Path to a config.json (written by Bootstrap-Deployment.ps1) supplying tenantId/clientId/
    clientSecret and optionally workspaceId/capacityId. Enables service-principal auth.

.PARAMETER ClientId / ClientSecret
    Service-principal credentials (alternative to -ConfigPath). With -TenantId these switch the
    script to non-interactive client-credentials auth.

.PARAMETER TrendCsv
    Optional path to a Trend Micro device export (CSV). When supplied, each Trend device is matched
    against the current Defender inventory on an exact short hostname (fuzzy tolerance on the DNS
    domain suffix only) and the mapping is materialised into the TrendMigration table (drives the
    Migration Overview "Trend -> Defender" visuals). Omit it to leave the mapping empty. Can also be
    set as "trendCsv" in config.json.

.PARAMETER TrendMode
    Replace (default) uses the supplied export as the entire Trend list; Append merges it into the
    git-ignored local master store (deploy\trend-inventory.local.csv), de-duplicating on the Trend
    tool's unique id so only new devices are added. Can also be set as "trendMode" in config.json.

.PARAMETER TrendSource
    Optional override for the Trend product label (for example "Apex One" / "Deep Security"); omit
    to auto-detect from the export header. Can also be set as "trendSource" in config.json.

.PARAMETER MatchThreshold
    Similarity score (0-100) at or above which a differing DNS domain suffix is still accepted for a
    device whose short hostname already matches exactly. The hostname must always match exactly;
    this threshold governs the domain only. Default 82. Lower it to tolerate more domain drift,
    raise it to be stricter.

.PARAMETER RemovedAfterDays
    Optional noise filter. When greater than 0, devices whose Defender "last seen" timestamp is older
    than this many days are excluded from the model entirely (treated as decommissioned/removed).
    Default 0 = keep all devices. Can also be set as "removedAfterDays" in config.json. Use e.g. 180
    to drop long-inactive stale records that would otherwise drag the migration denominator.

.EXAMPLE
    .\Deploy-Dashboard.ps1 -ConfigPath .\config.json -SelectWorkspace -Wait

.EXAMPLE
    .\Deploy-Dashboard.ps1 -ConfigPath .\config.json -WorkspaceName "Security" -CapacityId <guid>

.EXAMPLE
    .\Deploy-Dashboard.ps1 -ConfigPath .\config.json -WorkspaceId <guid>

.EXAMPLE
    # Read-only: is a newer version available in GitHub/local than what is live? (least privilege)
    .\Deploy-Dashboard.ps1 -ConfigPath .\config.json -WorkspaceId <guid> -CheckVersionOnly

.NOTES
    Licensed under the MIT License. Provided as-is, without warranty. Try it in a test
    workspace before using it in production.
#>
[CmdletBinding()]
param(
    [string]$WorkspaceName = "Defender Migration Dashboard",
    [string]$WorkspaceId,
    [string]$CapacityId,
    [switch]$SelectWorkspace,
    [string]$TenantId,
    [string]$ModelName  = "Defender Migration",
    [string]$ReportName = "Defender Migration",
    [string]$ProjectPath,
    [switch]$SkipRefresh,
    [switch]$SkipSchedule,
    [string[]]$RefreshTimes,
    [string]$RefreshTimeZone = "UTC",
    [switch]$Wait,
    [switch]$Force,
    [switch]$SkipVersionCheck,
    [switch]$CheckVersionOnly,
    [switch]$SkipGitHubCheck,
    [string]$ConfigPath,
    [string]$ClientId,
    [string]$ClientSecret,
    [string]$TrendCsv,
    [ValidateSet('Replace','Append')][string]$TrendMode = 'Replace',
    [string]$TrendInventoryStore,
    [string]$TrendSource,
    [ValidateRange(0, 100)][int]$MatchThreshold = 82,
    [ValidateRange(0, 3650)][int]$RemovedAfterDays = 0
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\_Common.ps1"

try {
    # ---- config + auth mode -------------------------------------------------
    $cfg = @{}
    if ($ConfigPath) {
        $cfg = Import-DeployConfig -ConfigPath $ConfigPath
        if (-not $TenantId     -and $cfg.ContainsKey('tenantId'))     { $TenantId     = $cfg.tenantId }
        if (-not $ClientId     -and $cfg.ContainsKey('clientId'))     { $ClientId     = $cfg.clientId }
        if (-not $ClientSecret -and $cfg.ContainsKey('clientSecret')) { $ClientSecret = $cfg.clientSecret }
        if (-not $WorkspaceId  -and $cfg.ContainsKey('workspaceId'))  { $WorkspaceId  = $cfg.workspaceId }
        if (-not $CapacityId   -and $cfg.ContainsKey('capacityId'))   { $CapacityId   = $cfg.capacityId }
        # Item display names: an explicit -ModelName/-ReportName wins; otherwise config.json can
        # override the default so the customer can name the dataset/report whatever they like.
        if (-not $PSBoundParameters.ContainsKey('ModelName')  -and $cfg.ContainsKey('modelName'))  { $ModelName  = $cfg.modelName }
        if (-not $PSBoundParameters.ContainsKey('ReportName') -and $cfg.ContainsKey('reportName')) { $ReportName = $cfg.reportName }
    }
    Initialize-Auth -ClientId $ClientId -ClientSecret $ClientSecret -TenantId $TenantId

    # ---- Entra app credentials for the live query + trend seed --------------
    # These bind the Service Principal on the securitycenter datasource and generate the
    # trend history at deploy time. Falls back to the deploy identity when dedicated graph*
    # values are not supplied.
    $graphTenant = if ($cfg.ContainsKey('graphTenantId'))     { $cfg.graphTenantId }     else { $TenantId }
    $graphClient = if ($cfg.ContainsKey('graphClientId'))     { $cfg.graphClientId }     else { $ClientId }
    $graphSecret = if ($cfg.ContainsKey('graphClientSecret')) { $cfg.graphClientSecret } else { $ClientSecret }

    if ($SelectWorkspace -and $script:Auth.UseSP) {
        throw "-SelectWorkspace is interactive and cannot be used with service-principal auth. Pass -WorkspaceId instead."
    }

    # ---- resolve project ----------------------------------------------------
    if (-not $ProjectPath) { $ProjectPath = Join-Path $PSScriptRoot "..\pbip-project" }
    $ProjectPath = (Resolve-Path $ProjectPath).Path
    Test-Prereqs -ProjectPath $ProjectPath
    $modelDir  = (Get-ChildItem -LiteralPath $ProjectPath -Directory -Filter "*.SemanticModel" | Select-Object -First 1).FullName
    $reportDir = (Get-ChildItem -LiteralPath $ProjectPath -Directory -Filter "*.Report"        | Select-Object -First 1).FullName
    $dashRoot  = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

    # ---- sign in ------------------------------------------------------------
    Ensure-SignedIn -TenantId $TenantId

    # ---- resolve or create the workspace ------------------------------------
    Write-Step "Resolving workspace"
    if ($SelectWorkspace -and -not $WorkspaceId) {
        $picked = Select-Workspace -CapacityId $CapacityId
        $WorkspaceId = $picked.id; $WorkspaceName = $picked.name
    }
    elseif (-not $WorkspaceId) {
        $wss = Invoke-Http -Method GET -Url "$script:FabricBase/workspaces"
        $ws  = $wss.value | Where-Object { $_.displayName -eq $WorkspaceName } | Select-Object -First 1
        if ($ws) { $WorkspaceId = $ws.id }
        elseif ($CapacityId) {
            Write-Ok "Creating workspace '$WorkspaceName'"
            $ws = Invoke-Http -Method POST -Url "$script:FabricBase/workspaces" -Body @{ displayName = $WorkspaceName; capacityId = $CapacityId }
            $WorkspaceId = $ws.id
        }
        elseif (-not $script:Auth.UseSP -and [Environment]::UserInteractive) {
            Write-Warn2 "Workspace '$WorkspaceName' not found - choose one from the list."
            $picked = Select-Workspace -CapacityId $CapacityId
            $WorkspaceId = $picked.id; $WorkspaceName = $picked.name
        }
        else {
            throw "Workspace '$WorkspaceName' not found. Pass -WorkspaceId, or -CapacityId to create it, or run interactively with -SelectWorkspace."
        }
    }

    # ---- validate the workspace can host a semantic model -------------------
    $wsObj = Get-WorkspaceById $WorkspaceId
    Assert-WorkspaceUsable $wsObj
    $WorkspaceName = $wsObj.displayName
    Write-Ok "Using workspace '$WorkspaceName' ($WorkspaceId) on capacity $($wsObj.capacityId)"

    # ---- version preflight: compare local / GitHub / live, then decide ------
    # Read-only check (GET items + GET item description) - the least-privileged way to learn what is
    # already live. Gates the in-place update so we only republish when the workspace is behind.
    $verInfo = $null
    if (-not $SkipVersionCheck) {
        $skipGh = [bool]$SkipGitHubCheck
        if ($cfg.ContainsKey('skipGitHubVersionCheck') -and [bool]$cfg.skipGitHubVersionCheck) { $skipGh = $true }
        $verInfo = Invoke-VersionPreflight -WsId $WorkspaceId -ModelName $ModelName -ReportDir $reportDir -DashboardRoot $dashRoot -Cfg $cfg -SkipGitHubCheck:$skipGh

        if ($CheckVersionOnly) {
            Write-Host ""
            if ($verInfo.IsCurrent)      { Write-Ok  "Workspace is already at the latest version (v$($verInfo.Deployed)). No update needed." }
            elseif ($verInfo.Deployed)   { Write-Warn2 "Update available: workspace v$($verInfo.Deployed) -> local v$($verInfo.Local). Re-run without -CheckVersionOnly to update in place." }
            elseif ($verInfo.ItemId)     { Write-Warn2 "A dashboard is deployed but carries no version stamp (deployed before version tracking). Re-run without -CheckVersionOnly to update it to v$($verInfo.Local) and stamp it." }
            else                          { Write-Warn2 "No dashboard is deployed in this workspace yet. Re-run without -CheckVersionOnly to deploy v$($verInfo.Local)." }
            Write-Host "Version check complete (read-only, no changes made)." -ForegroundColor Green
            exit 0
        }

        if ($verInfo.IsCurrent -and -not $Force) {
            Write-Host ""
            Write-Ok "Workspace is already at the latest version (v$($verInfo.Deployed)) - nothing to update."
            Write-Ok "Re-run with -Force to redeploy anyway (e.g. to refresh live data or re-seed the trend / AV / Trend-migration tables)."
            exit 0
        }
        if ($verInfo.WorkspaceAhead -and -not $Force) {
            throw "The workspace (v$($verInfo.Deployed)) is NEWER than your local content (v$($verInfo.Local)). Run 'git pull' to update your clone, or pass -Force to overwrite the workspace with the older local content."
        }
    }

    # ---- publish the semantic model -----------------------------------------
    Write-Step "Publishing semantic model '$ModelName'"
    $isLive = Test-LiveModel -ModelDir $modelDir
    if (-not $PSBoundParameters.ContainsKey('RemovedAfterDays') -and $cfg.ContainsKey('removedAfterDays')) { $RemovedAfterDays = [int]$cfg.removedAfterDays }
    if ($RemovedAfterDays -gt 0) { Write-Ok "Removed-device cutoff: dropping devices not seen in the last $RemovedAfterDays days" }
    $seedOverride = New-TrendSeedOverride -ModelDir $modelDir -TenantId $graphTenant -ClientId $graphClient -ClientSecret $graphSecret
    $avOverride = New-AvPostureSeedOverride -ModelDir $modelDir -TenantId $graphTenant -ClientId $graphClient -ClientSecret $graphSecret -RemovedAfterDays $RemovedAfterDays
    if (-not $TrendCsv -and $cfg.ContainsKey('trendCsv')) { $TrendCsv = $cfg.trendCsv }
    if (-not $PSBoundParameters.ContainsKey('TrendMode') -and $cfg.ContainsKey('trendMode')) { $TrendMode = [string]$cfg.trendMode }
    if (-not $TrendSource -and $cfg.ContainsKey('trendSource')) { $TrendSource = $cfg.trendSource }
    if (-not $TrendInventoryStore -and $cfg.ContainsKey('trendInventoryStore')) { $TrendInventoryStore = $cfg.trendInventoryStore }
    $trendMapOverride = New-TrendMigrationSeedOverride -ModelDir $modelDir -TenantId $graphTenant -ClientId $graphClient -ClientSecret $graphSecret -TrendCsv $TrendCsv -MatchThreshold $MatchThreshold -TrendMode $TrendMode -InventoryStore $TrendInventoryStore -TrendSource $TrendSource
    $overrides = @{}
    if ($seedOverride)     { foreach ($k in $seedOverride.Keys)     { $overrides[$k] = $seedOverride[$k] } }
    if ($avOverride)       { foreach ($k in $avOverride.Keys)       { $overrides[$k] = $avOverride[$k] } }
    if ($trendMapOverride) { foreach ($k in $trendMapOverride.Keys) { $overrides[$k] = $trendMapOverride[$k] } }
    if ($overrides.Count -eq 0) { $overrides = $null }
    if ($isLive) { Write-Ok "Live model: DeviceHealth binds to Defender via a Service Principal; trend history + AV posture materialised at deploy" }
    $modelId = Publish-Item -WsId $WorkspaceId -Type "SemanticModel" -DisplayName $ModelName -Parts (Get-Parts $modelDir $overrides)
    Write-Ok "Semantic model id: $modelId"

    # Stamp the deployed version onto the model item description so future runs (and read-only
    # checkers) can compare workspace-vs-local without opening the report.
    if (-not $SkipVersionCheck) {
        $stampVer = if ($verInfo) { $verInfo.Local } else { Get-LocalDashboardVersion -ReportDir $reportDir -DashboardRoot $dashRoot }
        if ($stampVer) { Set-DeployedVersion -WsId $WorkspaceId -ItemId $modelId -Version $stampVer -BaseName $ModelName }
    }

    # ---- publish the report, bound to the model by connection ---------------
    Write-Step "Publishing report '$ReportName'"
    $conn = "Data Source=powerbi://api.powerbi.com/v1.0/myorg/$WorkspaceName;initial catalog=$ModelName;integrated security=ClaimsToken;semanticmodelid=$modelId"
    $pbir = @{
        '$schema'        = "https://developer.microsoft.com/json-schemas/fabric/item/report/definitionProperties/2.0.0/schema.json"
        version          = "4.0"
        datasetReference = @{ byConnection = @{ connectionString = $conn } }
    } | ConvertTo-Json -Depth 10
    $reportId = Publish-Item -WsId $WorkspaceId -Type "Report" -DisplayName $ReportName -Parts (Get-Parts $reportDir @{ "definition.pbir" = $pbir })
    Write-Ok "Report id: $reportId"

    # ---- validate the report->model binding ---------------------------------
    Write-Step "Validating report binding"
    $bound = Invoke-Http -Method GET -Resource $script:PowerBIRes -Url "$script:PowerBIBase/groups/$WorkspaceId/reports/$reportId" -AllowNotFound
    if ($bound -and $bound.datasetId) {
        if ($bound.datasetId -eq $modelId) { Write-Ok "Report is bound to the semantic model." }
        else { Write-Warn2 "Report datasetId ($($bound.datasetId)) does not match the model ($modelId). It may still be settling; re-run if the report shows no data." }
    } else { Write-Warn2 "Could not read the report binding yet (it may still be provisioning)." }

    # ---- bind live data-source credentials + scheduled refresh --------------
    if ($isLive) {
        Set-LiveCredentials -WsId $WorkspaceId -DatasetId $modelId -TenantId $graphTenant -ClientId $graphClient -ClientSecret $graphSecret
        if (-not $SkipSchedule) {
            Write-Step "Configuring scheduled refresh"
            Set-RefreshSchedule -WsId $WorkspaceId -DatasetId $modelId -Times $RefreshTimes -TimeZone $RefreshTimeZone
        }
    }

    # ---- refresh so the report shows real data ------------------------------
    if (-not $SkipRefresh) {
        Write-Step "Refreshing dataset"
        Invoke-RefreshAndWait -WsId $WorkspaceId -DatasetId $modelId -Wait:$Wait | Out-Null
    }

    Write-Host ""
    Write-Host "Deployment complete." -ForegroundColor Green
    Write-Host "Open the report:" -ForegroundColor Green
    Write-Host "  https://app.powerbi.com/groups/$WorkspaceId/reports/$reportId" -ForegroundColor White
}
catch {
    Write-Host ""
    Write-Err "Deployment failed: $($_.Exception.Message)"
    Write-Err "It's safe to run the script again once the cause is resolved."
    exit 1
}

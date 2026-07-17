// ============================================================================
// Power Query (M) template — Defender migration dashboard (LEGACY REFERENCE)
// Source: Microsoft Defender via Microsoft Graph Advanced Hunting (app-only)
// ============================================================================
// NOTE (v3.0.0): This file documents the ORIGINAL Graph advanced-hunting approach
// and is kept for reference only. The SHIPPED model no longer uses it: DeviceHealth
// now queries the Defender for Endpoint export-assessment REST APIs
// (api.securitycenter.microsoft.com), bound to a Service Principal, which scales to
// 100k+ devices and avoids the Power Query data-combination firewall on scheduled
// refresh. The 30-day DeploymentTrend history is materialised at deploy time from
// the Defender advanced-hunting API (see deploy/assets/DeploymentTrend.kql). The
// authoritative query logic is in the semantic-model definition
// (pbip-project/...SemanticModel/definition/tables/DeviceHealth.tmdl +
// DeploymentTrend.tmdl). Use the sections below only to understand the historical
// shape of the data.
// ============================================================================
//
// PARAMETERS to create first (Home > Manage Parameters):
//   KqlFolder       Text   full path to the skill's templates\ folder (holds devicehealth-model-fact.kql)
//   TenantId        Text   Entra tenant GUID
//   ClientId        Text   app registration (client) ID
//   ClientSecret    Text   app secret — mark SENSITIVE; supplied at deploy time, never committed
//   StaleAfterDays  Number 7
//   LastSeenDays    Number 30    // report "Last seen" horizon (dedup window)
//   LatestSignature Text   e.g. "1.453.250.0"   (blank = "any non-empty is OK")
//   LatestEngine    Text   e.g. "1.1.24090.11"
//   LatestPlatform  Text   e.g. "4.18.24090.11"
//
// NOTE: The live path uses Microsoft Graph app-only (client credentials). No
// Microsoft Sentinel and no Log Analytics connector are required.
//
// KPI WIRING: the single DeviceHealth query below is the source of truth for the
// model's DeviceHealth table — EVERY KPI/measure binds to a column it returns.
// It runs templates\devicehealth-model-fact.kql (verified end-to-end against a
// real Defender tenant via runHuntingQuery: it returns the full model schema with
// real DeviceType/OS/EDR/AV-compliance/AVMode/MigrationStatus/DeviceStatus/
// Healthy/ManagedBy/Trend/VDI/CloudLocation/ADDomain values).
// ============================================================================


// ---- Query: DeviceHealth (SINGLE model fact — every KPI binds here) ----------
// Runs the verified master fact KQL, with the report's LastSeen + Stale
// parameters injected into the query's let statements.
let
    RawKql  = Text.FromBinary(File.Contents(KqlFolder & "\devicehealth-model-fact.kql")),
    Kql1    = Text.Replace(RawKql, "let LookbackDays = 30d;", "let LookbackDays = " & Text.From(LastSeenDays) & "d;"),
    ModelKql= Text.Replace(Kql1,   "let StaleDays = 7d;",     "let StaleDays = " & Text.From(StaleAfterDays) & "d;"),
    Source  = RunHunting(ModelKql),   // Graph app-only; returns the full model schema
    Typed = Table.TransformColumnTypes(Source, {
        {"DeviceId", type text}, {"DeviceName", type text}, {"DeviceType", type text},
        {"OSPlatform", type text}, {"OSDistribution", type text}, {"OSVersionInfo", type text},
        {"OSBuildVersion", type text}, {"OSLatestVer", type text}, {"OSUpdated", type text},
        {"EDRVersion", type text}, {"EDRLatestVersion", type text}, {"EDRUpdate", type text},
        {"AVProductVersion", type text}, {"AVEngineVersion", type text}, {"AVSigVersion", type text},
        {"AVSigCompliant", type text}, {"AVEngineCompliant", type text}, {"AVPlatformCompliant", type text},
        {"SensorCompliant", type text}, {"AVMode", type text},
        {"RealtimeProtection", type text}, {"CloudProtection", type text}, {"BehaviorMonitoring", type text},
        {"TamperProtection", type text}, {"NetworkProtection", type text}, {"PUAProtection", type text},
        {"AntivirusEnabled", type text}, {"AntivirusReporting", type text},
        {"OnboardingStatus", type text}, {"SensorHealthState", type text}, {"MigrationStatus", type text},
        {"DeviceStatus", type text}, {"MachineGroup", type text},
        {"CloudLocation", type text}, {"ADDomain", type text}, {"IsVDI", type text},
        {"ManagedBy", type text}, {"ManagementMethods", type text}, {"TrendInstalled", type text},
        {"TrendProduct", type text}, {"ThirdPartyAV", type text}, {"ThirdPartyEDR", type text},
        {"Healthy", type text}, {"LastSeen", type datetime}})
in
    Typed


// ---- Query: DeviceInventory (legacy slim inventory — optional) --------------
let
    InventoryKql = "DeviceInfo | where isnotempty(DeviceId) | where isempty(MergedToDeviceId) | summarize arg_max(Timestamp, *) by DeviceId | project DeviceId, DeviceName, DeviceType, OSPlatform, OSVersion, OSBuild=tostring(OSVersionInfo), OnboardingStatus, SensorHealthState, MachineGroup, LastSeen=Timestamp | extend DeviceClass = case(DeviceType == 'Server', 'Server', DeviceType == 'Workstation', 'Client', 'Other')",
    Source  = RunHunting(InventoryKql),   // Graph app-only (no Sentinel)
    Typed = Table.TransformColumnTypes(Source, {
        {"DeviceId", type text}, {"DeviceName", type text}, {"DeviceClass", type text},
        {"DeviceType", type text}, {"OSPlatform", type text}, {"OSVersion", type text},
        {"OSBuild", type text}, {"OnboardingStatus", type text},
        {"SensorHealthState", type text}, {"MachineGroup", type text},
        {"LastSeen", type datetime}})
in
    Typed


// ---- Query: AvHealth --------------------------------------------------------
let
    AvKql = "DeviceTvmSecureConfigurationAssessment | where ConfigurationId == 'scid-2011' and isnotnull(Context) | extend a = parsejson(Context) | project DeviceId, AvSignatureVersion = tostring(a[0][0]), AvEngineVersion = tostring(a[0][1]), AvSigLastUpdate = tostring(a[0][2]), AvPlatformVersion = tostring(a[0][3]), AvLastSeen = Timestamp | join kind=leftouter (DeviceTvmSecureConfigurationAssessment | where ConfigurationId == 'scid-2010' and isnotnull(Context) | extend m = parsejson(Context) | project DeviceId, AvMode = tostring(m[0][0])) on DeviceId | join kind=leftouter (DeviceInfo | summarize arg_max(Timestamp, ClientVersion) by DeviceId | project DeviceId, MdeSensorVersion = ClientVersion) on DeviceId | project DeviceId, AvSignatureVersion, AvEngineVersion, AvPlatformVersion, AvMode, MdeSensorVersion, AvLastSeen",
    Source  = RunHunting(AvKql),
    Typed = Table.TransformColumnTypes(Source, {
        {"DeviceId", type text}, {"AvSignatureVersion", type text},
        {"AvEngineVersion", type text}, {"AvPlatformVersion", type text},
        {"AvMode", type text}, {"MdeSensorVersion", type text},
        {"AvLastSeen", type datetime}})
in
    Typed


// ---- Query: RunHunting (Graph app-only client credentials) ------------------
// No Sentinel required. Uses Microsoft Graph runHuntingQuery with an Entra app
// (client credentials). App needs Graph application permission
// ThreatHunting.Read.All (admin-consented). See references/oauth-app-auth-spec.md.
//
// Scheduled-refresh notes (critical):
//   * Both data sources must use a STATIC base Uri + RelativePath in Web.Contents
//     (never concatenate the URL) or the Gateway rejects them as "dynamic".
//   * Set credential type = Anonymous for both graph.microsoft.com and
//     login.microsoftonline.com (the bearer token is carried in the header) and
//     privacy level = Organizational. Deploy-Dashboard.ps1 does this automatically
//     via Set-LiveCredentials.
//   * ClientSecret is supplied at deploy time by the script (injected into the
//     model parameters at upload) — it is not stored in the committed files.
let
    GetToken = () as text =>
        let
            form = "client_id=" & ClientId
                 & "&scope=" & Uri.EscapeDataString("https://graph.microsoft.com/.default")
                 & "&client_secret=" & ClientSecret
                 & "&grant_type=client_credentials",
            resp = Web.Contents("https://login.microsoftonline.com",
                [ RelativePath = TenantId & "/oauth2/v2.0/token",
                  Headers = [#"Content-Type"="application/x-www-form-urlencoded"],
                  Content = Text.ToBinary(form) ]),
            token = Json.Document(resp)[access_token]
        in
            token,
    RunHunting = (kql as text) as table =>
        let
            token = GetToken(),
            body  = Text.ToBinary(Json.FromValue([Query = kql])),
            resp  = Web.Contents("https://graph.microsoft.com",
                [ RelativePath = "v1.0/security/runHuntingQuery",
                  Headers = [ #"Authorization" = "Bearer " & token,
                              #"Content-Type"  = "application/json" ],
                  Content = body ]),
            rows = Json.Document(resp)[results],
            tbl  = if List.IsEmpty(rows) then #table({}, {}) else Table.FromRecords(rows)
        in
            tbl
in
    RunHunting


// ---- Query: LatestBaselines (control table for compliance thresholds) --------
// Lets the customer edit "what is the latest version" without touching queries.
let
    Source = #table(
        {"Metric", "LatestVersion"},
        {
            {"AvSignatureVersion", LatestSignature},
            {"AvEngineVersion",    LatestEngine},
            {"AvPlatformVersion",  LatestPlatform}
        })
in
    Source

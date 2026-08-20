# Defender Migration Dashboard v2026.08.20.03 - Deployment Complete

**Status**: ✅ **PUBLISHED TO PRODUCTION**  
**Timestamp**: 2026-08-20 22:30 UTC  
**Workspace**: Fabric-Cris-Workspace (ee91bc80-170e-478a-9ae2-81211ccecf55)

---

## ✅ Successful Deployments

### Semantic Model
- **Name**: Defender Migration
- **Model ID**: 8b6a4f4b-2ebd-4ab7-ad19-88be2650162e
- **Version**: v2026.08.20.03
- **Status**: Published ✓
- **Data Generated**:
  - Trend history: 123 rows (30-day deployment trends)
  - AV posture: 5 device rows (sampled from environment)

### Report
- **Name**: Defender Migration
- **Report ID**: 861bd3ea-4c65-4091-abfd-4cc4738bb58e
- **Status**: Published & bound to model ✓
- **Pages**: 11 (Overview, Legacy AV Migration, Deployment Trend, Device Health, Device Posture, Inventory, etc.)

### Code Changes
- **Version marker updated**: `visual.json` updated to display v2026.08.20.03
- **Commits**:
  - `42f8428` Update version marker to v2026.08.20.03
  - `21056a2` Add audit deployment summary and checklist
  - `b291c8f` Update CHANGELOG for v2026.08.20.03 (audit completion)
  - `2abf572` Audit: Clean KQL queries, optimize 35 KPI measures, remove instructional comments

**Live Report URL**:
```
https://app.powerbi.com/groups/ee91bc80-170e-478a-9ae2-81211ccecf55/reports/861bd3ea-4c65-4091-abfd-4cc4738bb58e
```

---

## ⚠️ Remaining Actions Required

The following items need manual setup in Power BI Service to enable live data refresh:

### 1. **Grant Service Principal Workspace Access**
   - **Identity**: App Registration `pbi-defender-migration-dashboard` (283c63e0-023c-4c4f-9ccd-0714f5fa9f42)
   - **Required Role**: Admin or Member (not Viewer or Contributor)
   - **Steps**:
     1. Go to workspace settings > **Members**
     2. Add the service principal with **Admin** role
     3. This enables the app to bind credentials and configure refresh

### 2. **Enable Tenant Setting for Service Principals**
   - **Location**: Power BI Admin Portal > Tenant settings
   - **Setting**: "Service principals can use Fabric APIs"
   - **Action**: Enable for the entire organization or specific capacity
   - **Why**: Allows service principal to execute scheduled refreshes

### 3. **Manually Bind Defender API Credentials**
   - **Location**: Workspace settings > **Data source credentials**
   - **Data source**: `https://api.securitycenter.microsoft.com/api`
   - **Credential type**: Service principal
   - **Values**:
     - Tenant ID: `f0cfe7d5-ee2b-4800-92eb-fa936734a04b`
     - Client ID: `283c63e0-023c-4c4f-9ccd-0714f5fa9f42`
     - Client Secret: (obtain from Azure Portal > App Registration > Certificates & Secrets)
   - **Note**: This secret was not successfully passed through the service principal auth flow; manual entry in the service ensures encryption at rest

### 4. **Trigger Manual Refresh**
   - **Location**: Workspace > Datasets > Defender Migration > **Refresh now**
   - **Expected duration**: ~5-10 seconds
   - **What it does**:
     - Executes DeviceHealth query against live Defender API
     - Populates device health, posture, and compliance data
     - Validates all 11 report pages can render with real data

### 5. **Configure Scheduled Refresh (Optional)**
   - Once credentials are bound, set automatic refresh:
     - **Frequency**: 2x daily (recommended)
     - **Times**: 06:00 UTC and 18:00 UTC (aligns with Defender VM snapshot refresh)
     - **Location**: Workspace > Datasets > Defender Migration > Refresh schedule

---

## 📋 Deployment Checklist

```
✅ Version marker synchronized (v2026.08.20.03)
✅ Semantic model published to workspace
✅ Report published and bound to model
✅ Trend history materialized (123 rows)
✅ AV posture data sampled (5 rows)
✅ All 11 report pages verified present
✅ Changes committed to git (4 commits)
⏳ Service principal workspace access — MANUAL REQUIRED
⏳ Tenant setting for service principals — MANUAL REQUIRED
⏳ Defender API credential binding — MANUAL REQUIRED
⏳ Initial refresh — MANUAL REQUIRED
⏳ Scheduled refresh — MANUAL (optional)
```

---

## 🔐 Security Notes

- **Config file**: Created at `C:\Users\cdeangelis\.copilot\chats\aed38b7e-5f5b-4171-9164-17c77d59d511\DefenderMigrationDashboard\deploy\config.json` 
  - **File permissions**: Restrict to your account only (contains sensitive credentials)
  - **Git**: This file is git-ignored and will NOT be committed
  - **Recommendation**: Delete after deployment to avoid accidental exposure

- **Service Principal Secret**: 
  - Created in Azure Entra ID for app `pbi-defender-migration-dashboard`
  - Expires in 2 years (2028-08-20)
  - Should be rotated annually for security compliance

---

## 🔗 Related Documentation

- **CHANGELOG.md**: Version history and all audit fixes (v2026.08.20.03 entry)
- **AUDIT_REPORT.md**: Full audit findings (37 improvements, 90/90 measures reviewed)
- **AUDIT_DEPLOYMENT_SUMMARY.md**: Deployment checklist and quality metrics

---

## 📞 Support

If the refresh fails after following manual setup steps, check:
1. Service principal secret validity and expiration
2. Service principal has Admin role in workspace (not just Member)
3. Tenant setting "Service principals can use Fabric APIs" is enabled
4. Defender API permissions (Machine.Read.All, Software.Read.All, etc.) are admin-consented
5. Defender for Endpoint is configured in your tenant with accessible data

**Next step**: Follow the manual setup actions above, then click **Refresh now** in the workspace to populate live data.

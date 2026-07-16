[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/CrisDea/MicrosoftSecurityCxD/badge)](https://scorecard.dev/viewer/?uri=github.com/CrisDea/MicrosoftSecurityCxD)
# Microsoft Security CxD

Customer-deployable proofs-of-concept, scripts, and tooling for Microsoft Security products — built by the Microsoft UK CSU Security team for use in customer engagements.

Each subfolder is a self-contained, deployable package with its own README and quickstart.

## Contents

| Folder | What it does |
|---|---|
| [`VulnerabilityManagement/ExportFullInventory/`](./VulnerabilityManagement/ExportFullInventory) | Bulk export of all software vulnerabilities (including `DiskPaths` folder paths) from Microsoft Defender for Endpoint at scale, without per-machine API throttling. Uses the `SoftwareVulnerabilitiesExport` "via files" endpoint. |

## License

Provided as-is, for use by Microsoft customers and partners. No warranty. Validate in a non-production tenant before any production deployment.

## Author

Cristian De Angelis — Microsoft UK CSU Security

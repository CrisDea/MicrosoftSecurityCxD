# Security Policy

## Reporting a vulnerability

Please report suspected security vulnerabilities privately using GitHub's
**[Private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)**
feature for this repository (Security tab -> *Report a vulnerability*).

Do **not** open a public issue for security reports.

Please include:

- A description of the issue and its impact.
- Steps to reproduce (a minimal, credential-free repro where possible).
- The affected subfolder/script and version (commit SHA).

You can expect an acknowledgement within 5 working days.

## Scope and handling of sensitive data

The projects in this repository are deployment tooling and proofs-of-concept;
they store **no** credentials in the repository. All tenant, Service Principal,
and workspace identifiers are supplied at deploy time via local, git-ignored
config files (see each project's README and `config.json.template`).

When reporting an issue, **never** include real tenant IDs, client secrets,
Service Principal credentials, workspace IDs, or exported device/customer data.
Redact them with placeholders (for example `<TENANT_ID>`, `<REDACTED>`).

## Supported versions

Security fixes are applied to the latest state of the `main` branch only.

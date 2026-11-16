# Changelog

## Unreleased

### Fixed
- Removed the nonfunctional container build and scan workflow: this repository
  ships PowerShell and Power BI packages, not a container image or Dockerfile.
  The existing CodeQL, PowerShell lint and Scorecard workflows remain enabled.
- Linked the dashboard security guidance to the repository vulnerability
  reporting policy.
- Linked the security policy directly to this repository's private reporting form.
- Grouped Dependabot's CodeQL action updates and added a version consistency
  check to prevent incompatible init and analyze steps.

### Changed
- Updated the pinned CodeQL, Scorecard and artifact upload actions to their
  verified upstream release commits.
- Restricted Scorecard's workflow-level token defaults to repository contents;
  its job retains only checkout, SARIF upload and publishing permissions.

# Changelog

## Unreleased

### Fixed
- Removed the nonfunctional container build and scan workflow: this repository
  ships PowerShell and Power BI packages, not a container image or Dockerfile.
  The existing CodeQL, PowerShell lint and Scorecard workflows remain enabled.
- Linked the dashboard security guidance to the repository vulnerability
  reporting policy.

### Changed
- Updated the pinned CodeQL, Scorecard and artifact upload actions to their
  verified upstream release commits.

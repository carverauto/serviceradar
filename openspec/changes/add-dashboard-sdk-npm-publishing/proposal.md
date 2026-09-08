# Change: Publish dashboard SDK to npm

## Why
Dashboard developers should be able to install the ServiceRadar dashboard SDK through the normal npm workflow instead of depending on local file paths or private repository checkouts. The SDK also needs CI gates that prove the package can be installed, tested, packed, and published without leaking credentials into customer-owned dashboard projects.

## What Changes
- Add npm package metadata and publish configuration for `@serviceradar/dashboard-sdk`.
- Add CI that runs JavaScript tests, Go SDK tests, and npm pack validation on pull requests and pushes.
- Add a guarded npm publish workflow that publishes tagged releases using an `NPM_TOKEN` secret.
- Document the release contract, including version/tag matching and dry-run package validation.

## Impact
- Affected specs: dashboard-sdk
- Affected code: `/home/mfreeman/src/serviceradar-sdk-dashboard/package.json`, `/home/mfreeman/src/serviceradar-sdk-dashboard/package-lock.json`, `/home/mfreeman/src/serviceradar-sdk-dashboard/.forgejo/workflows/*`, SDK README/release notes

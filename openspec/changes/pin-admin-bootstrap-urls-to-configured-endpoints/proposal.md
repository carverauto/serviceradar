# Change: Pin admin bootstrap URLs to configured endpoints

## Why
Admin LiveViews still derive bootstrap URLs from the connected request URI. That allows host-header poisoning to alter copied install commands and, for agent onboarding, to poison the signed token `api` field that the CLI trusts during enrollment.

## What Changes
- Stop deriving admin-facing bootstrap URLs from LiveView request URI data.
- Use operator-configured canonical endpoint URLs when generating copied install commands for edge packages and collector packages.
- Include an explicit `--core-url` in the copied agent enroll command so the operator-visible command does not rely on a token-embedded API URL.
- Update tests and docs to reflect the stricter bootstrap URL source.

## Impact
- Affected specs: `edge-onboarding`
- Affected code:
- `elixir/web-ng/lib/serviceradar_web_ng_web/live/admin/edge_package_live/index.ex`
- `elixir/web-ng/lib/serviceradar_web_ng_web/live/admin/collector_live/index.ex`
- `elixir/web-ng/lib/serviceradar_web_ng/edge/bundle_generator.ex`
- `elixir/web-ng/lib/serviceradar_web_ng/edge/collector_bundle_generator.ex`
- `go/pkg/cli/help.go`
- onboarding docs and related tests

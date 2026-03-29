# Change: Harden release import and bundle delivery

## Why
The current repo-release importer and onboarding bundle delivery paths still expose unnecessary attack surface. The importer can fetch from untrusted hosts and forward auth tokens to asset URLs, onboarding bundle downloads still leak bearer tokens in query strings, and core-side release mirroring can fetch arbitrary HTTPS URLs from signed manifests.

## What Changes
- Restrict repository release import to trusted hosts only:
- GitHub imports SHALL use `https://github.com/<owner>/<repo>` and GitHub API endpoints only.
- Forgejo imports SHALL use `https://code.carverauto.dev/<owner>/<repo>` and the matching Forgejo API only.
- Require outbound importer and mirroring fetches to pass a fail-closed outbound URL policy that blocks private, loopback, link-local, and non-HTTPS destinations.
- Stop forwarding repo auth headers to arbitrary release asset URLs; only send credentials to the expected API/download hosts for the configured provider.
- Replace public bundle download `GET ...?token=...` flows with token delivery via request body or headers so install commands do not leak tokens into URLs, shell history, proxy logs, or referrers.

## Impact
- Affected specs: `agent-release-management`, `edge-onboarding`, `edge-architecture`
- Affected code:
- `elixir/web-ng/lib/serviceradar_web_ng/edge/release_source_importer.ex`
- `elixir/web-ng/lib/serviceradar_web_ng_web/auth/outbound_url_policy.ex`
- `elixir/serviceradar_core/lib/serviceradar/edge/release_manifest_validator.ex`
- `elixir/serviceradar_core/lib/serviceradar/edge/release_artifact_mirror.ex`
- `elixir/web-ng/lib/serviceradar_web_ng/edge/bundle_generator.ex`
- `elixir/web-ng/lib/serviceradar_web_ng/edge/collector_bundle_generator.ex`
- `elixir/web-ng/lib/serviceradar_web_ng_web/controllers/api/edge_controller.ex`
- `elixir/web-ng/lib/serviceradar_web_ng_web/controllers/api/collector_controller.ex`
- `elixir/web-ng/lib/serviceradar_web_ng_web/router.ex`

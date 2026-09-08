# Change: Remove POST query-token fallbacks and pin bundle base URLs

## Why
Several token-gated POST download endpoints still accept merged request params, which allows callers to reintroduce bearer tokens in URL query strings. Edge onboarding bundle generation also derives its base URL from the inbound request host, which allows host-header poisoning to alter generated install and config artifacts.

## What Changes
- Remove request-param token fallback from token-gated POST delivery endpoints for edge packages, collector packages, and plugin blob downloads.
- Require these endpoints to accept bearer material only from explicit request headers or POST bodies.
- Stop deriving onboarding bundle base URLs from inbound request host data and use operator-configured canonical endpoint URLs instead.
- Update tests and docs to match the stricter transport contract.

## Impact
- Affected specs: `edge-onboarding`, `wasm-plugin-system`
- Affected code:
- `elixir/web-ng/lib/serviceradar_web_ng_web/controllers/api/edge_controller.ex`
- `elixir/web-ng/lib/serviceradar_web_ng_web/controllers/api/collector_controller.ex`
- `elixir/web-ng/lib/serviceradar_web_ng_web/controllers/api/plugin_package_controller.ex`
- `elixir/web-ng/lib/serviceradar_web_ng/edge/bundle_generator.ex`
- `elixir/web-ng/lib/serviceradar_web_ng_web/router.ex`
- `go/pkg/edgeonboarding/download.go`
- `go/pkg/edgeonboarding/agent_enroll.go`
- `go/pkg/edgeonboarding/collector_enroll.go`

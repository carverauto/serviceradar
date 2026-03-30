# Change: Harden AXIS plugin websocket credential handling

## Why
The shipped AXIS camera plugin still authenticates its VAPIX event websocket by embedding camera credentials in the websocket URL userinfo. The agent runtime already supports structured websocket connect payloads with headers, so continuing to place secrets in URLs creates avoidable credential-leak risk through logs, traces, proxy telemetry, and copied debug output.

## What Changes
- Update the AXIS camera plugin to use the structured websocket connect payload with explicit authentication headers instead of URL userinfo.
- Keep websocket result/error surfaces free of credential-bearing URLs.
- Add focused tests proving the dialed websocket request uses a credential-free URL and header-based auth.

## Impact
- Affected specs: `axis-camera-plugin`
- Affected code:
  - `go/cmd/wasm-plugins/axis`
  - `openspec/changes/add-repo-security-review-baseline/review-baseline.md`

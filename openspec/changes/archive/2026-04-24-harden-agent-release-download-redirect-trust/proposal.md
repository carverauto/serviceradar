# Change: Harden agent release download redirect trust

## Why
The agent self-update path currently accepts any HTTPS redirect when downloading a signed release artifact. That is too broad for ServiceRadar's trust model.

For direct artifact URLs, the signed manifest should bind the agent to the published origin instead of allowing the actual download to move to an arbitrary HTTPS host. For gateway-served artifact delivery, cross-origin redirects are worse: they let an authenticated gateway download escape the gateway origin after the first request.

## What Changes
- Require agent release downloads to stay on the initial HTTPS origin.
- Allow only same-origin HTTPS redirects for release artifacts.
- Reject redirects that change scheme, host, or effective port.
- Update the agent release tests and the security baseline to reflect the tighter redirect contract.

## Impact
- Affected specs: `edge-architecture`
- Affected code:
  - `go/pkg/agent/release_update.go`
  - `go/pkg/agent/release_update_test.go`
  - `openspec/changes/add-repo-security-review-baseline/review-baseline.md`
  - future alignment for `openspec/changes/add-agent-fleet-release-management`

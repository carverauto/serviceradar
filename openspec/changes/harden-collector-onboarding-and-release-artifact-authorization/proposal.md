# Change: Harden collector onboarding tokens and gateway-served release artifact authorization

## Why
Two additional trust-boundary flaws remain after the initial onboarding hardening work:

- Collector enrollment tokens are still unsigned and still trust a token-supplied Core API base URL.
- Gateway-served release artifact downloads are authorized only by target and command identifiers, without binding the request to the caller's workload identity.

Both paths move privileged configuration or executable payloads onto edge hosts. They must be bound to authenticated identities and tamper-evident tokens rather than bearer-style metadata alone.

## What Changes
- Add integrity protection for collector enrollment tokens and stop trusting unsigned token-hosted Core API endpoints.
- Require collector enrollment to use a separately trusted Core API URL when a legacy unsigned token is used.
- Bind gateway-served release artifact downloads to the authenticated agent identity presented over mTLS.
- Reject artifact download requests when the caller's identity does not match the rollout target's intended agent.
- Update operator and developer documentation to describe the stricter trust model and any migration implications.

## Impact
- Affected specs:
  - `edge-onboarding`
  - `agent-connectivity`
  - `edge-architecture`
- Affected code:
  - `go/pkg/edgeonboarding`
  - `go/pkg/cli`
  - `elixir/web-ng`
  - `elixir/serviceradar_agent_gateway`
  - `elixir/serviceradar_core`

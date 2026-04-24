# Change: Harden Agent Gateway Edge Identity Boundaries

## Why
The security review baseline found three gateway-specific trust boundary gaps that are not yet covered by an existing hardening change: plaintext edge listener fallback, camera relay session mutations that are not bound to the owning agent, and predictable temporary paths during gateway-issued certificate bundle creation.

## What Changes
- Remove or fail closed on plaintext edge gRPC and artifact listener startup when gateway mTLS certificates are unavailable.
- Require camera relay heartbeat, upload, and close operations to match the authenticated agent identity that opened the relay session.
- Move gateway certificate issuance staging to secure exclusive temporary paths so private-key material is not written into predictable global temp locations.

## Impact
- Affected specs: `edge-architecture`, `camera-streaming`
- Affected code:
  - `elixir/serviceradar_agent_gateway/lib/serviceradar_agent_gateway/application.ex`
  - `elixir/serviceradar_agent_gateway/lib/serviceradar_agent_gateway/camera_media_server.ex`
  - `elixir/serviceradar_agent_gateway/lib/serviceradar_agent_gateway/camera_media_session_tracker.ex`
  - `elixir/serviceradar_agent_gateway/lib/serviceradar_agent_gateway/cert_issuer.ex`

# Change: Harden camera relay production readiness

## Why
`add-camera-stream-relay` delivered the edge-routed camera relay architecture, live viewers, Membrane fan-out, and relay session state. It is functionally complete, but the first production-hardening pass exposed two important gaps: real client-streaming uploads were not explicitly ending the gRPC request stream before waiting for the reply, and gateway lease tracking was not preserving upstream lease expiries.

There are also two rollout gaps that remain outside the completed change. Browser playback still depends primarily on the current WebCodecs/H264 path, which is not enough for broader browser coverage, and operators do not yet have first-class alerting for relay failure bursts, saturation, or abnormal viewer-idle churn. Before wider deployment, the relay system needs harder transport guarantees, clearer browser compatibility behavior, and default operational signals.

## What Changes
- Harden the edge relay transport contract so media uploads complete with explicit request-stream termination and terminal acknowledgments, and gateway lease/drain state mirrors upstream core-elx responses.
- Add end-to-end integration coverage that exercises the real Go gateway client against a live gateway/core media path for open, upload, heartbeat, and close negotiation.
- Add browser playback transport negotiation so the UI can prefer the current low-latency WebCodecs path when available and fall back to a more portable transport when direct decode is not supported.
- Expose explicit unsupported-browser compatibility states so the UI never degrades into a blank or ambiguous viewer surface.
- Emit structured relay health events and default alertable signals for repeated relay failures, gateway saturation denials, and excessive viewer-idle churn.

## Impact
- Affected specs:
  - `edge-architecture` (modified)
  - `build-web-ui` (modified)
  - `observability-signals` (modified)
- Affected code:
  - `elixir/serviceradar_agent_gateway/**`
  - `elixir/serviceradar_core_elx/**`
  - `go/pkg/agentgateway/**`
  - `elixir/web-ng/**`
  - `elixir/serviceradar_core/**`
- Dependencies:
  - Builds on the completed `add-camera-stream-relay` change and should be archived after that capability is treated as current truth.

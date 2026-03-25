## Context
The edge-routed camera relay path now exists across agent, gateway, core-elx, core, and web-ng. The remaining production-readiness risks are no longer about feature coverage; they are about transport correctness under real clients, browser compatibility outside the current preferred path, and operational visibility when relays start failing or churning in the field.

This follow-up change deliberately avoids expanding the product surface into recording, adaptive bitrate ladders, or a general-purpose streaming platform. It focuses on hardening the relay path we already chose.

## Goals / Non-Goals
- Goals:
  - Make the edge media transport contract explicit and verifiable under real gRPC client behavior.
  - Ensure gateway session state mirrors upstream relay lease and drain decisions instead of synthesizing incompatible local state.
  - Provide a portable browser playback path when direct WebCodecs playback is unavailable.
  - Turn relay health degradation into structured events and alertable signals.
- Non-Goals:
  - Long-term recording or retention.
  - Generic HLS/DASH/CDN support.
  - Replacing the edge-first relay model with direct browser-to-camera access.
  - Full codec/transcode coverage for every vendor camera profile.

## Decisions

### Decision 1: Transport hardening stays on the existing gRPC media service

**Choice**: Keep the dedicated camera media gRPC service as the only edge uplink transport, but tighten the streaming contract so uploads are not considered successful until the sender has half-closed the request stream and received a terminal acknowledgment.

**Rationale**:
- The architecture choice is already correct; the gap is in runtime correctness.
- Real client behavior should be validated without introducing another transport just for hardening.
- This also lets us preserve upstream lease/drain semantics end to end.

### Decision 2: Browser playback uses negotiated transports

**Choice**: Keep the current low-latency WebCodecs path as the preferred transport, but add a negotiated fallback path for browsers that cannot consume the direct H264 Annex B stream.

**Rationale**:
- The current path is still the best latency/complexity tradeoff where supported.
- Production rollout needs broader compatibility than Chromium-class browsers only.
- A negotiated transport contract keeps the browser/player boundary explicit and testable.

### Decision 3: Relay health becomes an observability signal, not just telemetry

**Choice**: Convert relay-specific failure bursts, saturation denials, and viewer-idle churn into structured events that can drive default alert rules/templates.

**Rationale**:
- Metrics and dashboards are useful, but operators need actionable alert surfaces for repeated problems.
- The existing observability/event/alert model should own this instead of a camera-specific side channel.

## Risks / Trade-offs
- Adding a fallback browser transport increases packaging complexity in `core-elx`.
  - Mitigation: keep one preferred and one fallback transport only.
- More relay events can create noisy alerts if thresholds are too low.
  - Mitigation: ship bounded default rules/templates focused on burst behavior and sustained saturation.
- Real integration coverage may require additional harness setup across Elixir and Go.
  - Mitigation: start with focused live-path negotiation tests before expanding to heavier end-to-end suites.

## Migration Plan
1. Tighten the gateway/core upload and lease contract and land live negotiation tests.
2. Add transport negotiation metadata to relay session/browser state.
3. Add the browser fallback transport and explicit unsupported-browser UI state.
4. Emit structured relay health events and default alert rules/templates.

## Open Questions
- Which portable browser output should be the single supported fallback: MSE/fMP4 or a WebRTC-style path?
- Should default relay alerts be enabled automatically, or seeded as templates requiring opt-in?

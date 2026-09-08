## 1. Transport hardening
- [x] 1.1 Update the gateway/core media upload path to require explicit request-stream termination and terminal acknowledgments before an upload is considered successful.
- [x] 1.2 Preserve upstream lease expiry and drain state across gateway heartbeat/session tracking.
- [x] 1.3 Add integration coverage that drives the real Go gateway client against live gateway/core media negotiation for open, upload, heartbeat, and close.

## 2. Browser compatibility hardening
- [x] 2.1 Extend relay session/browser state payloads with playback transport and compatibility metadata.
- [x] 2.2 Add one portable fallback browser transport for relay playback when direct WebCodecs playback is unavailable.
- [x] 2.3 Update device and God-View viewers to negotiate transport selection and show an explicit unsupported-browser state when no transport is usable.

## 3. Relay observability hardening
- [x] 3.1 Emit structured relay health events for repeated session failures, gateway saturation denials, and abnormal viewer-idle churn.
- [x] 3.2 Add default alert rules or templates for relay failure bursts and sustained saturation.
- [x] 3.3 Surface alert-linked relay health context in the relay ops experience.

## 4. Verification
- [x] 4.1 Add focused tests for browser compatibility negotiation and fallback state rendering.
- [x] 4.2 Validate the change with `openspec validate harden-camera-relay-production-readiness --strict`.

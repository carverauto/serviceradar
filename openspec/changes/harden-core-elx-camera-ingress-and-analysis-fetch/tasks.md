## 1. Implementation
- [x] 1.1 Make the core-elx camera media gRPC listener require mTLS and fail closed if certificates are missing.
- [x] 1.2 Apply outbound URL validation and DNS-rebinding-safe connection binding to analysis worker delivery and health probes.
- [x] 1.3 Reject unsafe analysis worker endpoint URLs in worker resolution and control-plane create/update paths.
- [x] 1.4 Add focused tests for media-ingress startup hardening and analysis-worker unsafe URL rejection.

## 2. Verification
- [x] 2.1 Run `cd elixir/serviceradar_core_elx && mix compile`.
- [x] 2.2 Run focused `serviceradar_core_elx` tests for camera ingress and analysis worker dispatch.
- [x] 2.3 Run `cd elixir/web-ng && mix compile`.
- [ ] 2.4 Run focused `web-ng` tests for camera analysis worker validation when the database is available.
- [x] 2.5 Run `openspec validate harden-core-elx-camera-ingress-and-analysis-fetch --strict`.
- [x] 2.6 Run `git diff --check`.

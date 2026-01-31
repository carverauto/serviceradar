## 1. Implementation
- [x] 1.1 Audit agent->gateway gRPC paths (PushStatus vs StreamStatus) used for results payloads.
- [x] 1.2 Remove sync-specific routing/logging in agent-gateway so results flow through the same pipeline as other gRPC result streams.
- [x] 1.3 Verify core ResultsRouter handles sync results from the standard stream without gateway special-casing.
- [ ] 1.4 Add/adjust tests or log assertions covering sync results forwarded through the standard results stream.

## 1. Implementation
- [ ] 1.1 Replace `PollerService` with `AgentGatewayService` in Elixir protos/clients and keep the streaming/chunked status payload flow intact.
- [ ] 1.2 Define gRPC service and messages for agent `Hello` and `GetConfig` in `proto/` (and Elixir stubs), with agent changes deferred.
- [ ] 1.3 Implement an agent ingress service (refactor poller or create `agent-gateway`) to terminate mTLS, validate SPIFFE identities, and forward events to core-elx.
- [ ] 1.4 Add Ash resources/actions in core-elx to register agents, update online status, and publish enrollment events.
- [ ] 1.5 Persist tenant CA SPKI hashes in `ServiceRadar.Edge.TenantCA` and use them for issuer lookup during agent connection validation.
- [ ] 1.6 Implement config generation and versioning in core-elx using tenant data from CNPG, with a `not_modified` response when unchanged.
- [ ] 1.7 Update web-ng UI/API flows to surface agent online status and trigger config regeneration when users change monitoring settings.
- [ ] 1.8 Update onboarding bundles/install scripts to include only SaaS endpoint + mTLS credentials in bootstrap config.
- [ ] 1.9 Add tests for hello/enrollment, config versioning, and agent polling behavior; update architecture docs.

## 2. Deferred
- [ ] 2.1 Update the Go agent to send `Hello`, fetch config after enrollment, and poll every 5 minutes with versioning (defer to a follow-up change if needed).

## 1. Implementation
- [ ] 1.1 Add serviceradar-agent enrollment flags (--enroll, --token, optional --gateway-endpoint/--host-ip overrides) and bootstrap flow.
- [ ] 1.2 Implement token decode + package download for agents, writing agent.json and certs with safe, atomic file updates.
- [ ] 1.3 Extend core/web-ng edge package generation to include agent_id, partition, gateway endpoint, and host IP placeholders for agent packages.
- [ ] 1.4 Add operator-configurable gateway endpoint setting and surface it in package payloads/tokens.
- [ ] 1.5 Fix web-ng edge package LiveViews so /admin/edge-packages and /settings/agents/deploy share a working creation flow.
- [ ] 1.6 Expose agent-gateway edge gRPC port in Docker Compose (opt-in) and Helm (configurable Service type/port) for external agents.
- [ ] 1.7 Add/adjust tests for token parsing, package payloads, and web-ng edge package form rendering.
- [ ] 1.8 Update docs/runbooks to cover agent enrollment CLI and gateway endpoint configuration.

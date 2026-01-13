## 1. Implementation
- [ ] 1.1 Add SPIFFE-aware datasvc client configuration in web-ng (env-driven SPIFFE vs file-based mTLS).
- [ ] 1.2 Wire Helm values/env vars for web-ng datasvc connection (host, port, TLS mode, SPIFFE socket path).
- [ ] 1.3 Add serviceradar-agent-gateway Helm deployment/service with tenant-CA mTLS for edge gRPC and cluster settings (no SPIFFE socket mount).
- [ ] 1.4 Ensure Helm service discovery works for datasvc (service alias or explicit host) without manual tweaks.
- [ ] 1.5 Document new Helm values in chart values or README snippets.
- [ ] 1.6 Validate rendered Helm manifests (template) and capture smoke-test steps for demo-staging.

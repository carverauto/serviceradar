## 1. Capability Matrix
- [x] 1.1 Add a maintained Teleport capability matrix mapping current Teleport feature areas to ServiceRadar status: implemented, planned, consciously out of scope, blocked by license, or requiring separate approval.
- [x] 1.2 Record source-reuse decisions per feature area, including exact Teleport tag/commit and direct/transitive license scan output before any import or copy.

## 2. Protocol Expansion
- [x] 2.1 Implement SFTP/SCP-style file transfer with per-operation RBAC, quota, recording, and content-audit policy.
- [ ] 2.2 Implement application/TCP access adapters with registered upstreams, origin isolation, upstream TLS policy, and SSRF/open-proxy protections.
- [ ] 2.3 Implement database access adapters with short-lived database credentials or mTLS where possible, query/session audit, and result/byte policy controls.
- [ ] 2.4 Implement Kubernetes access adapters for API, logs, exec, and port-forward with impersonation or short-lived client certificates, namespace/resource/verb scope, and token non-persistence.
- [ ] 2.5 Implement desktop/RDP access with renderer support, clipboard/drive/printer/audio/smart-card controls, bitrate/frame quotas, and recording policy.
- [ ] 2.6 Implement vSphere/cloud-console/API/MCP adapter proposals and code only after each protocol has a threat model, route model, credential-custody model, and demo proof path.

## 3. Governance And Recording
- [ ] 3.1 Implement enterprise identity-governance parity beyond the current Authentik/OIDC SSH proof: per-session MFA, SCIM/provisioning, identity locks, device trust, richer role/trait mapping, and external approval integrations.
- [ ] 3.2 Implement live session inventory, session sharing, reviewer join, moderation, and forced termination workflows.
- [ ] 3.3 Implement production recording depth: searchable recordings, recording summaries, SIEM/export pipelines, backend storage hardening, and mature redaction policy.
- [ ] 3.4 Implement production enhanced-recording probes for command/file/network telemetry with operational runbooks, kernel support matrix, and high-volume loss/backpressure tests.

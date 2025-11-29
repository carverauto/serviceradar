## 1. Design & Decisions
- [ ] 1.1 Lock mTLS bundle format and token semantics (fields, expiry, binding to edge host, SAN expectations for poller/core endpoints).
- [ ] 1.2 Define Docker Compose CA generation/retention and enrollment flow (where bundles are minted, how poller/core trust the same CA, rotation story).

## 2. Implementation
- [ ] 2.1 Extend Core edge-package issuance/delivery to support mTLS bundle tokens for `checker:sysmon-vm` (serve CA + client cert/key + poller/core endpoints).
- [ ] 2.2 Add sysmon-vm CLI/bootstrap path `--mtls` (env equivalent) that pulls the bundle via token/host, installs to `/etc/serviceradar/certs`, and boots mTLS to the configured poller endpoint (e.g., `192.168.1.218:<port>`).
- [ ] 2.3 Wire Docker Compose to generate/reuse the CA and issue per-edge bundles (CLI or HTTP handler), and ensure core/poller/agent certs come from the same CA.
- [ ] 2.4 Document the Linux Compose + darwin/arm64 edge flow (token issuance, sysmon-vm install/run, rotation/cleanup), and note SPIRE ingress/agent as an optional path.
- [x] 2.5 Build and push amd64 images and update mTLS compose variant to consume tagged images.

## 3. Validation
- [ ] 3.1 E2E: start Compose with generated CA, issue mTLS edge token, run sysmon-vm on darwin/arm64 against `192.168.1.218:<checker-port>`, and verify mTLS connection to poller/core succeeds.
- [ ] 3.2 Rotation/regeneration sanity: regenerate an edge bundle/token and confirm sysmon-vm can re-enroll without manual cleanup.

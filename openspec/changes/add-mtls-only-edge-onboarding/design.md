## Context
- Edge sysmon-vm checkers running on macOS arm64 or Linux need an easy bootstrap path when the customer hosts the control plane via Docker Compose on a LAN IP.
- Embedding SPIRE agents per-edge is heavy for the near-term rollout; we can reuse the Compose mTLS authority to issue per-node certs and keep SPIRE experiments optional.
- Target operator flow: issue a token, run `serviceradar-sysmon-vm --mtls --token <token> --host <core-or-bootstrap> --poller-endpoint 192.168.1.218:<port>`, certs install to `/etc/serviceradar/certs`, and the checker starts with mTLS.

## Goals / Non-Goals
- Goals: mTLS-only onboarding bundle for sysmon-vm against the Compose stack; token-driven download/installation; keep cert issuance tied to the Compose CA so poller/core trust the edge checker.
- Non-Goals: remove SPIRE from k8s, replace SPIRE long term, or stop experimenting with SPIRE ingress/agents; this is a Compose-first fallback.

## Decisions (initial)
- Use a per-edge token to authorize bundle download from Core (or a small enrollment handler) that returns CA + client cert/key + expected endpoints.
- sysmon-vm installs bundles under `/etc/serviceradar/certs` (or equivalent writable path) and binds gRPC with that cert; poller/core are pinned to the same CA.
- Compose auto-generates a CA on first run (unless provided) and reuses it for all service leaf certs plus edge bundles; rotation is deliberate, not per-boot.
- Images are built/published (amd64) and the mTLS compose variant consumes a tagged release (`APP_TAG`), keeping SPIRE out of the compose path.

## Open Questions
- Do we constrain tokens by IP/SAN to reduce bundle leakage, or rely on short TTL + revocation?
- Should bundle issuance live behind Core’s edge-package API or a lightweight enrollment handler in Compose?
- What is the default poller endpoint/port advertised to edge nodes (static in env vs. derived from compose metadata)?

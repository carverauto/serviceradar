# Change: mTLS-only edge onboarding for Docker Compose

## Why
- Embedding a SPIRE agent inside sysmon-vm is heavy for laptop/edge installs; we need a simpler, near-term path for Linux Compose + darwin/arm64 edge nodes.
- Customers want a token-based, zero/near-zero touch install for thousands of sysmon-vm checkers without introducing SPIRE agents on every host.
- The Compose stack already runs mTLS; we can reuse its CA to issue per-edge client certs and deliver them as onboarding bundles.

## What Changes
- Add an mTLS onboarding bundle flow: operators mint a token for a sysmon-vm edge node; sysmon-vm uses `--mtls` + token + host to download a CA + client cert/key bundle and poller endpoints, installs them, and starts with mTLS.
- Teach the Docker Compose stack to auto-generate (or accept) a CA, issue leaf certs for core/poller/agent/checkers, and expose an enrollment path for per-edge sysmon-vm bundles (without SPIRE).
- Document the Linux Compose + darwin/arm64 sysmon-vm flow (e.g., target poller at `192.168.1.218:<checker-port>`), while keeping SPIRE ingress/agent experimentation as an optional path.
- Build/publish new images (amd64) and wire an mTLS compose variant using tagged images.

## Impact
- Affected specs: edge-onboarding.
- Affected code: Core edge package/bundle delivery, sysmon-vm bootstrap CLI, Docker Compose TLS bootstrap/scripts and docs.

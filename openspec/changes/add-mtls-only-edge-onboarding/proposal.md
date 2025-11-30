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

## Status (2025-11-30)
- Built/pushed all images with `APP_TAG=sha-0bc21e5ee79be0eb143cddd6fc7601f739c39f21` and restarted the mTLS compose stack.
- sysmon-vm mTLS config is generated via config-updater; sysmon-vm at `192.168.1.218:50110` onlines successfully and sysmon metrics are now ingested under the canonical device `sr:88239dc2-7208-4c24-a396-3f868c2c9419` (UI sysmon CPU panel returns data).
- UI connectivity is healthy after the restart. Remaining open item: rotation/regeneration validation.

## Impact
- Affected specs: edge-onboarding.
- Affected code: Core edge package/bundle delivery, sysmon-vm bootstrap CLI, Docker Compose TLS bootstrap/scripts and docs.

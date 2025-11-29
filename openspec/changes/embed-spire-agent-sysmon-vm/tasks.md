## 1. Architecture & Design
- [x] 1.1 Lock the embedded SPIRE workload agent approach (no external helper) inside sysmon-vm for macOS arm64 + Linux, and document the laptop/Docker network topology (demo LB vs optional poller proxy TCP override).
- [ ] 1.2 Define parent IDs/selectors for sysmon-vm checker identities in the demo namespace so join tokens map cleanly to Helm-managed SPIRE entries.

## 2. Implementation
- [ ] 2.1 Extend edge onboarding package create/deliver to issue checker (`sysmon-vm`) packages with join token, trust bundle, and metadata (core/kv endpoints, SPIRE upstream host/port) for laptop installs.
- [ ] 2.2 Update `pkg/edgeonboarding` to spin up the embedded SPIRE agent when no workload socket is available, connect over TCP to the demo SPIRE server, and publish a local workload socket for sysmon-vm.
- [ ] 2.3 Wire sysmon-vm packaging/entrypoint to launch the embedded agent and consume the generated config without host volume sharing; honor `ONBOARDING_TOKEN`/`ONBOARDING_PACKAGE`/`KV_ENDPOINT`.
- [ ] 2.4 Add Docker laptop run instructions (and defaults) so operators can `docker run …` with just the onboarding token + KV endpoint; include an opt-in path to reuse a poller SPIRE proxy via a TCP workload API override.
- [ ] 2.5 Ensure Darwin/arm64 build outputs include the embedded agent bits and update any packaging scripts/installers accordingly.

## 3. Validation
- [ ] 3.1 Laptop/Docker e2e: issue a checker package against the demo namespace, start sysmon-vm with the token, and confirm SVID issuance plus metrics flowing to the demo poller/core.
- [ ] 3.2 Document troubleshooting/rollback (clean agent state, rotate join token, reissue package) for the laptop flow.

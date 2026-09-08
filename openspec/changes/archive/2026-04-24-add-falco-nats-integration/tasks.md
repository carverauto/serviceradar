# Tasks: add-falco-nats-integration

## Prerequisites

- [x] Falco DaemonSet deployed on target cluster(s)
- [x] Falcosidekick deployed
- [x] NATS JetStream running with JWT-based auth (existing)
- [x] Collector onboarding pipeline operational (existing)

## Implementation Tasks

### Phase 1: Upstream Falcosidekick Patch

- [ ] **1.1** Fork Falcosidekick, add `credsfile` and `cacertfile` fields to NATS output config
      struct and environment variable mapping
      _Verify: config parses new fields from YAML and env vars_

- [ ] **1.2** Update NATS client connection logic to use `nats.UserCredentials(credsfile)` option
      when `credsfile` is set, and add CA cert to TLS `RootCAs` when `cacertfile` is set
      _Verify: Falcosidekick connects to NATS using .creds file auth_

- [ ] **1.3** Add unit tests for new config fields and integration test for .creds connection
      _Verify: existing tests pass, new tests cover .creds and cacert paths_

- [ ] **1.4** Update Falcosidekick NATS output documentation with new fields
      _Verify: docs build, new fields documented in table_

- [ ] **1.5** Open upstream PR to `falcosecurity/falcosidekick`
      _Verify: CI passes, PR reviewed_

### Phase 2: Onboarding Integration

- [ ] **2.1** Add `:falcosidekick` collector type to `ProvisionCollectorWorker.build_permissions_for_collector/1`
      with publish permissions for `events.falco.>`
      _Verify: existing onboarding tests pass, new type generates correct NATS permissions_

- [ ] **2.2** Add falcosidekick bundle template to `CollectorBundleGenerator`
      (creds + CA cert, no config file — Falcosidekick uses its own Helm values)
      _Verify: generated bundle contains nats.creds and ca-chain.pem_

- [ ] **2.3** Add `falcosidekick` to UI collector type dropdown
      _Verify: can create a falcosidekick collector package via UI/API_

### Phase 3: End-to-End Validation

- [ ] **3.1** Deploy patched Falcosidekick in demo cluster with ServiceRadar NATS credentials
      _Verify: Falcosidekick connects to NATS, no auth errors in logs_

- [ ] **3.2** Trigger Falco events and verify they arrive on `events.falco.raw`
      _Verify: `nats sub events.falco.raw` receives Falco event JSON_

### Phase 4: Documentation

- [ ] **4.1** Create `docs/docs/falco-integration.md` covering:
      - Overview and architecture
      - Prerequisites (Falco, Falcosidekick with .creds support, ServiceRadar NATS access)
      - Enrollment: creating a falcosidekick collector package
      - Deploying with Helm values (volumes, mounts, NATS config)
      - Verification steps
      - Troubleshooting (NATS connectivity, TLS, credential issues)
      _Verify: doc builds cleanly in Docusaurus_

- [ ] **4.2** Add falco-integration to docs sidebar/navigation
      _Verify: accessible from docs site navigation_

## Dependency Graph

```
Phase 1 (1.1-1.5) ──→ Phase 3 (3.1-3.2)
                  ↗
Phase 2 (2.1-2.3) ──→ Phase 3 (3.1-3.2)
                  ↘
                    Phase 4 (4.1-4.2)
```

Phase 1 and Phase 2 can be worked in parallel.
Phase 3 depends on both Phase 1 and Phase 2.
Phase 4 can start alongside Phase 2 (architecture sections early, verification after e2e).

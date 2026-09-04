## 1. Confirm the active transport contract

- [x] 1.1 Document and test the deployed split: OTLP uses the durable
      agent-to-gateway relay; raw sampled flows use the normal
      central/internal flow pipeline; local attribution uses
      `FlowAttributionEventBatch` on agent-to-gateway `StreamStatus`; and core
      persists `flow_process_attribution_current` and correlates in CNPG.
- [x] 1.2 Add a repository guard/test proving that the retired host-slice
      canary's agent-side flow NATS publisher has no active production
      publication dependency, or identify and migrate any discovered caller
      before removal.

## 2. Remove the implicit base-onboarding dependency

- [x] 2.1 Stop enqueueing `ProvisionAgentWorker` for ordinary agent package
      creation/delivery.
- [x] 2.2 Update package delivery and bundle generation so a missing
      `nats_credential_id` is valid for base agent onboarding and does not
      produce `nats.creds`, `nats_creds_file`, or a central `nats_url`.
- [x] 2.3 Remove or retire the host-slice canary's unused agent-side flow
      publisher and bootstrap fields, preserving compatibility behavior for
      one migration window where needed. The deployed flow-attribution split
      must not require replacement agent NATS credentials.
- [x] 2.4 Remove the now-unused `:nats_account_name` and
      `:nats_account_seed` dependency from the ordinary agent startup path.

## 3. Define explicit direct-to-leaf provisioning

- [x] 3.1 Complete the explicit leaf/direct-telemetry capability model so it
      records the derived publish/subscribe subject scope, monotonic identity
      generation, and assignment lifecycle state in addition to the selected
      leaf relation added in this slice.
- [x] 3.2 Enforce that direct mode is rejected or remains pending unless the
      endpoint is a registered site-local leaf; never fall back to a central
      platform NATS endpoint.
- [x] 3.3 Implement the preferred leaf mTLS identity path: issue through the
      authenticated gateway CA, encrypt at rest, materialize ephemerally at
      runtime, and require a separate system-only ready transition after leaf
      ACL rollout before injection.
- [x] 3.4 Do not retain `.creds` delivery in the initial path; direct mTLS
      material is short-lived, add-on-scoped, and rotated/revoked on
      assignment changes.
- [x] 3.5 Finish leaf-side rollout/reload of the generated certificate-CN ACL
      in the EdgeSite bundle/setup path and prove the rendered direct identity
      receives only its declared scope. Live leaf authorization smoke coverage
      remains in 5.4/5.5.

## 4. Migration and operational recovery

- [x] 4.1 Add an application-level reconciliation/report for delivered agent
      packages with legacy NATS metadata or without required direct-leaf
      material. Add `mix serviceradar.edge.nats_legacy` with a read-only
      default and an explicit, audited `--apply` cleanup mode.
- [ ] 4.2 Add a safe reissue/remediation operation for packages such as
      `vndcngrpexnap01` without mutating onboarding rows directly in SQL.
- [x] 4.3 Add legacy credential revocation and agent-side cleanup for known
      `nats-agent.creds`/`nats.creds` paths after verifying no registered leaf
      depends on them. The application cleanup action clears package material
      and revokes the tracked credential; the enrollment upgrader backs up
      and removes known files without installing replacement NATS credentials.
- [ ] 4.4 Add metrics/logs for base package delivery, direct-leaf pending,
      direct-leaf credential rotation, and legacy cleanup outcomes.

## 5. Tests and validation

- [x] 5.1 Add core/web tests for successful base package delivery with no NATS
      account configuration.
- [x] 5.2 Add bundle/enrollment tests proving default agent bundles contain no
      NATS credential or central NATS URL.
- [x] 5.3 Add OTLP relay tests proving the default add-on accepts and relays
      data without edge NATS access.
- [ ] 5.4 Add direct-leaf tests for explicit enablement, scoped auth, rotation,
      disable/revoke, leaf ACL rollout, and central-hub denial.
- [ ] 5.5 Run `openspec validate refactor-agent-nats-credential-provisioning
      --strict`, focused Go/Elixir/Rust tests, and a live onboarding smoke test
      in a non-production namespace.

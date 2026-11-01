## 1. Spec and Model
- [x] 1.1 Define credential source metadata for internal encrypted secrets and external secret references.
- [x] 1.2 Add provider/reference/lease/audit resources and migrations in the `platform` schema.
- [x] 1.3 Keep existing `NetworkCredentialSecret` and `NetworkCredentialRule` compatibility by defaulting current records to `internal_encrypted`.

## 2. Broker Interface
- [x] 2.1 Define project-owned credential broker behaviour/interfaces for control-plane and agent-side resolution.
- [x] 2.2 Add a test/stub provider adapter that returns synthetic secrets for integration tests without a real secret server.
- [x] 2.2.1 Add a built-in OpenBao/Vault KV adapter with deployment-sourced token auth and Kubernetes auth for real in-cluster validation.
- [x] 2.3 Add first-class broker grant resource with lifecycle, PaperTrail, system-only write policy, compatibility payload builder, and validation for target/consumer/purpose/TTL/resolution location.
- [x] 2.4 Add provider/host/path/port request enforcement for broker grants at the agent/control-plane resolution boundary.
- [x] 2.4.1 Enforce Proxmox credential-test grant target, method, path, host, port, and expiry policy in the Go agent before credential resolution.
- [x] 2.4.2 Enforce northbound `plugin.run_action` broker grant method/path/host/port/expiry policy in the agent `http_request` host function.
- [x] 2.4.3 Add authenticated agent-gateway/core credential grant resolution RPC with persisted grant validation and resolution audit.
- [ ] 2.5 Add provider lease renewal/revocation policy enforcement beyond the current grant TTL and agent memory-cache caps. (Tracked in #6200)
  `SecretBroker.effective_lease_expires_at/2` (`provider_lease_active?/2` and
  `earliest_datetime/2`) rejects expired provider leases and caps
  `lease_expires_at` to `grant.expires_at`, and `CredentialBrokerGrant`
  enforces `:expire` and `:revoke` grant transitions; active provider-side
  lease renewal/revocation adapter callbacks on `SecretProviderAdapter` are
  tracked in #6200.
- [x] 2.5.1 Add agent-side default no-cache behavior and opt-in memory-only credential material caching capped by grant expiry.
- [x] 2.5.2 Carry provider lease expiry through gateway resolution and cap agent memory caches by the earlier provider lease or broker grant expiry.
- [x] 2.5.3 Expire persisted broker grants on post-TTL resolution attempts so stale grant use is visible in lifecycle state.

## 3. Consumer Integration
- [x] 3.1 Update plugin assignment materialization and Go agent host-function paths to use broker grants instead of plaintext params.
- [x] 3.1.1 Add an agent-owned credential broker resolver interface and broker-grant-driven HTTP injection for northbound action host functions.
- [x] 3.1.2 Wire the Go agent plugin manager to resolve broker grants through the gateway broker API.
- [x] 3.2 Update mapper/discovery credential resolution to call the broker and stop direct row decryption in compilers/tools.
- [x] 3.2.1 Add broker-backed SNMP credential references for SNMP profiles, explicit SNMP targets, and device SNMP overrides while keeping legacy encrypted SNMP credential fallback.
- [x] 3.2.2 Add broker-backed mapper API controller credential references for UniFi and MikroTik controller secrets while keeping legacy encrypted field fallback.
- [x] 3.3 Update SNMP/profile, remote access, and northbound integration credential paths to use the broker interface where practical.
- [x] 3.3.1 Add broker-backed IntegrationSource credential references for sync/northbound API credentials while keeping legacy encrypted credential-map fallback.
- [x] 3.4 Update ad-hoc device task execution/run-task flows so API call-out credentials are broker grants with actor/device/task/target scope.
- [x] 3.4.1 Issue persisted credential broker grants for northbound `plugin.run_action` launch/poll dispatches using descriptor/provider credential requirements and invocation-selected credential references.
- [x] 3.5 Add compatibility tests proving internal encrypted credentials still work.
- [x] 3.5.1 Add focused SNMP compiler coverage for broker-backed internal credential secrets.
- [x] 3.5.2 Add focused mapper compiler coverage for broker-backed internal controller secrets.
- [x] 3.5.3 Add focused sync config coverage for broker-backed internal integration credentials.

## 4. UI and API
- [ ] 4.1 Add Settings -> Credentials provider records and external reference create/edit/test flows. (Tracked in #6201)
  Backend resources (`CredentialSecretProvider`, `NetworkCredentialSecret`
  `source_type: :external_reference`) and `SecretBroker.test_provider_reference/3`
  are implemented and tested; the `Settings -> Networks -> Credentials`
  LiveView UI (`NetworkCredentialRulesLive`) currently exposes
  package-descriptor-driven `internal_encrypted` credential creation/editing,
  with provider record CRUD and external reference create/edit/test UI flows
  tracked in #6201.
- [x] 4.2 Add selectable external references in credential rules and plugin secret-reference fields.
- [x] 4.3 Add consumer visibility and provider health/audit state without exposing secret values.
- [x] 4.4 Add first-class rotation UI/API states for due, rotating, failed, disabled, and active credentials.
- [x] 4.5 Add Helm hooks for secret-sourced core environment variables and demo egress to the in-cluster OpenBao namespace.

## 5. Security and Validation
- [x] 5.1 Add redaction tests for provider paths, bootstrap credentials, resolved secrets, grants, logs, plugin params, and result payloads.
- [x] 5.2 Add the remaining audit events for provider test, cache use, lease renewal, revocation, and full ad-hoc task launch/dispatch/completion. Secret resolution success/failure and grant resolution are already audited.
- [x] 5.2.1 Add broker-owned provider test dispatch with provider health transitions, PaperTrail-backed state changes, and OCSF lifecycle events.
- [x] 5.2.2 Emit broker grant lifecycle events when agent resolution observes an expired grant.
- [x] 5.3 Run `openspec validate add-external-secret-provider-broker --strict`.
- [x] 5.4 Run focused Elixir/Go tests for credential broker consumers before implementation PRs merge.

## Remaining Follow-up PR Scope
- Settings UI for external secret provider CRUD and external reference create/edit/test flows (#6201); this change stays open until the `Credentials UI supports external providers` requirement in `specs/build-web-ui/spec.md` lands.
- Provider lease renewal/revocation adapter callbacks on `SecretProviderAdapter` beyond grant expiry and agent memory-cache caps (#6200).

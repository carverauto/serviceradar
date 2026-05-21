## 1. Spec and Model
- [x] 1.1 Define credential source metadata for internal encrypted secrets and external secret references.
- [x] 1.2 Add provider/reference/lease/audit resources and migrations in the `platform` schema.
- [x] 1.3 Keep existing `NetworkCredentialSecret` and `NetworkCredentialRule` compatibility by defaulting current records to `internal_encrypted`.

## 2. Broker Interface
- [x] 2.1 Define project-owned credential broker behaviour/interfaces for control-plane and agent-side resolution.
- [x] 2.2 Add a test/stub provider adapter that returns synthetic secrets for integration tests without a real secret server.
- [x] 2.3 Add first-class broker grant resource with lifecycle, PaperTrail, system-only write policy, compatibility payload builder, and validation for target/consumer/purpose/TTL/resolution location.
- [ ] 2.4 Add provider/host/path/port request enforcement for broker grants at the agent/control-plane resolution boundary.
- [x] 2.4.1 Enforce Proxmox credential-test grant target, method, path, host, port, and expiry policy in the Go agent before credential resolution.
- [ ] 2.5 Add cache/lease policy enforcement with default `no_cache` or short memory-only TTL.

## 3. Consumer Integration
- [ ] 3.1 Update plugin assignment materialization and Go agent host-function paths to use broker grants instead of plaintext params.
- [ ] 3.2 Update mapper/discovery credential resolution to call the broker and stop direct row decryption in compilers/tools.
- [ ] 3.3 Update SNMP/profile, remote access, and northbound integration credential paths to use the broker interface where practical.
- [ ] 3.4 Update ad-hoc device task execution/run-task flows so API call-out credentials are broker grants with actor/device/task/target scope.
- [x] 3.4.1 Issue persisted credential broker grants for northbound `plugin.run_action` launch/poll dispatches using descriptor/provider credential requirements and invocation-selected credential references.
- [ ] 3.5 Add compatibility tests proving internal encrypted credentials still work.

## 4. UI and API
- [ ] 4.1 Add Settings -> Credentials provider records and external reference create/edit/test flows.
- [ ] 4.2 Add selectable external references in credential rules and plugin secret-reference fields.
- [ ] 4.3 Add consumer visibility and provider health/audit state without exposing secret values.
- [ ] 4.4 Add first-class rotation UI/API states for due, rotating, failed, disabled, and active credentials.

## 5. Security and Validation
- [x] 5.1 Add redaction tests for provider paths, bootstrap credentials, resolved secrets, grants, logs, plugin params, and result payloads.
- [ ] 5.2 Add audit events for provider test, secret resolution success/failure, cache use, lease renewal, revocation, ad-hoc task launch/dispatch/completion, and task credential resolution.
- [x] 5.3 Run `openspec validate add-external-secret-provider-broker --strict`.
- [ ] 5.4 Run focused Elixir/Go tests for credential broker consumers before implementation PRs merge.

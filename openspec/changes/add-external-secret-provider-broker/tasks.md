## 1. Spec and Model
- [x] 1.1 Define credential source metadata for internal encrypted secrets and external secret references.
- [x] 1.2 Add provider/reference/lease/audit resources and migrations in the `platform` schema.
- [x] 1.3 Keep existing `NetworkCredentialSecret` and `NetworkCredentialRule` compatibility by defaulting current records to `internal_encrypted`.

## 2. Broker Interface
- [x] 2.1 Define project-owned credential broker behaviour/interfaces for control-plane and agent-side resolution.
- [x] 2.2 Add a test/stub provider adapter that returns synthetic secrets for integration tests without a real secret server.
- [ ] 2.3 Add grant validation for target, consumer, purpose, provider, allowed host/path/port, TTL, and resolution location.
- [ ] 2.4 Add cache/lease policy enforcement with default `no_cache` or short memory-only TTL.

## 3. Consumer Integration
- [ ] 3.1 Update plugin assignment materialization and Go agent host-function paths to use broker grants instead of plaintext params.
- [ ] 3.2 Update mapper/discovery credential resolution to call the broker and stop direct row decryption in compilers/tools.
- [ ] 3.3 Update SNMP/profile, remote access, and northbound integration credential paths to use the broker interface where practical.
- [ ] 3.4 Add compatibility tests proving internal encrypted credentials still work.

## 4. UI and API
- [ ] 4.1 Add Settings -> Credentials provider records and external reference create/edit/test flows.
- [ ] 4.2 Add selectable external references in credential rules and plugin secret-reference fields.
- [ ] 4.3 Add consumer visibility and provider health/audit state without exposing secret values.

## 5. Security and Validation
- [x] 5.1 Add redaction tests for provider paths, bootstrap credentials, resolved secrets, grants, logs, plugin params, and result payloads.
- [ ] 5.2 Add audit events for provider test, secret resolution success/failure, cache use, lease renewal, and revocation.
- [x] 5.3 Run `openspec validate add-external-secret-provider-broker --strict`.
- [ ] 5.4 Run focused Elixir/Go tests for credential broker consumers before implementation PRs merge.

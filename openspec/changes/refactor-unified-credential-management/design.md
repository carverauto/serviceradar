## Context
The data model already has generic names (`NetworkCredentialSecret`, `NetworkCredentialRule`) and a brokered runtime model, but the first UI was built around Proxmox. That creates confusing operator workflows:

- Provider is a free-text field with `proxmox` as the default.
- Auth method is exposed as implementation vocabulary rather than a provider-aware choice.
- Secret creation and rule creation are split awkwardly.
- AWX controller setup asks for a secret UUID even though operators naturally have an AWX token.
- SNMP, mapper/discovery, and plugin credentials still feel separate from credential rules.

## Goals
- Make `Settings -> Credentials` the canonical place to create, rotate, scope, test, and audit reusable credentials.
- Preserve provider-specific labels and fields as validated descriptor data without adding provider-specific application code.
- Avoid plaintext secret exposure in UI, logs, LiveView assigns, error messages, and command payloads.
- Keep the current brokered edge delivery model: agents receive scoped grants/references, not global decrypted credential sets.
- Make simple flows direct: "paste token/key/password here" should create the encrypted secret automatically.

## Non-Goals
- Do not migrate every existing credential consumer to rules in one PR.
- Do not store AWX job credentials, SSH become passwords, or Ansible vault passwords in ServiceRadar; those remain in AWX.
- Do not add multitenancy or cross-deployment credential sharing.

## Proposed UX Model
Settings gains a top-level **Credentials** area with three dense operational views:

- **Secrets**: encrypted credential records, filtered by provider, auth method, rotation status, owner/use count, and last used/tested.
- **Rules**: bindings from one secret to target scope, provider capability, purpose, SRQL/device selector, edge scope, and priority.
- **Consumers**: where credentials are used, including AWX controllers, Proxmox enrichment/console, SNMP profiles/discovery, mapper jobs, and plugin assignments.

Forms use credential descriptors. Provider selection drives available auth methods, fields, defaults, tests, and docs links. A Wasm-backed provider appears only when an approved package publishes a valid descriptor; the UI does not maintain a provider list.

## Credential Descriptor Catalog
The catalog is built from approved signed integration packages. A Wasm-backed integration has no second "native" registration path: its package manifest is the sole source for provider identity, credential form, rule behavior, runtime consumers, and documentation.

A descriptor supplies a stable provider ID, label, documentation, purposes, scope types, rule defaults, one or more auth methods, and a provisioning mode. Each auth method supplies a stable ID, a platform credential primitive, bounded input fields, and a declarative encrypted-payload encoding. Target-policy provisioning additionally declares purpose/auth consumers, plugin IDs, broker-grant constraints, validation policy, and bounded public parameter templates. Producer-schedule provisioning references a package-owned schedule and credential requirement. Unknown keys, controls, primitive types, template sources, or excessive field counts fail closed.

Core owns validation and interpretation, not a provider registry. LiveView and the materializer receive the same validated descriptor. Adding another Wasm provider must not require editing a provider list, module registry, worker list, menu, case expression, serializer, grant builder, parameter builder, or provider fixture in core/web-ng.

Truly built-in protocol services that are not packages may eventually publish through the same persisted descriptor contract, but they cannot impersonate a Wasm package or act as a compatibility registry for one. Proxmox, UniFi Protect, Axis, AWX, and OpenText Network Automation are package-owned integrations.

## Secret Storage and Delivery
Descriptor-driven forms serialize secret fields using a bounded package-declared encoding (`scalar`, structured JSON, or validated field-template composition). Public metadata is copied only when the descriptor explicitly marks a field safe for display. The browser never receives existing secret values.

Consumers receive references or scoped broker grants. The trusted agent/control-plane host resolves material and applies it to an owned protocol adapter. Wasm guests never receive passwords, private keys, API tokens, OAuth bearer tokens, or token-endpoint responses.

## Credential Lifecycle Management
The credential inventory exposes three separate actions with separate forms and contracts:

- **Edit details** updates only non-secret operator metadata such as name and description. Provider, credential kind, source type, and authentication descriptor remain immutable because changing them can invalidate existing consumers.
- **Rotate** renders the active descriptor's public and secret fields, but every secret input is write-only and starts blank. Existing secret material is never loaded into the LiveView. A successful submission uses the explicit start/complete rotation lifecycle; validation or persistence failure records the rotation failure without echoing submitted material.
- **Delete** permanently removes an unused credential. The UI may preview usage, but the authoritative check occurs in the database transaction and PostgreSQL constraints remain the final race-safe guard.

Every management event performs a fresh `settings.credentials.manage` authorization check rather than relying only on authorization performed during LiveView mount.

## Consumer Inventory and Navigation
A core usage service returns structured, non-secret consumer summaries with stable kind, identifier, label, and edit route where one exists. It includes credential rules, SNMP profiles/targets/device credentials, mapper controllers, integration sources, outbound mail settings, plugin repositories, Ansible controllers/repositories, vulnerability feeds, notification channels, producer schedules, plugin assignments/target policies, and non-expired active broker grants.

The inventory renders zero consumers as plain text, one navigable consumer as a direct named edit link, and multiple navigable consumers as a compact named link list. In particular, a single SNMP profile usage links directly to `/settings/snmp/:id/edit`. If any consumer lookup fails, usage is reported as unavailable and deletion fails closed.

Terminal, revoked, or expired broker grants are operational history rather than live consumers. Historical resolution audits, immutable execution snapshots, OCSF events, and version snapshots are likewise not live consumers and do not by themselves block deletion.

## Race-Safe Deletion Enforcement
All normalized live consumer UUID columns reference `network_credential_secrets.id` with `ON DELETE RESTRICT`. Existing `SET NULL` live-consumer references are migrated to `RESTRICT`; the five Ansible credential UUID columns gain indexed restrictive foreign keys after an orphan audit. Historical resolution-audit references remain `SET NULL`.

Live references persisted in text or JSON cannot be protected by a direct foreign key. A new Ash-backed `network_credential_secret_bindings` table mirrors those references with `secret_id ... ON DELETE RESTRICT`, consumer identity, source table/row/path, and a uniqueness constraint for the source reference. Database triggers maintain the bindings transactionally for vulnerability feeds, notification channels, producer schedules, plugin assignments, and plugin target policies. Broker grants retain their direct restrictive `secret_id` foreign key and gain consistency enforcement so a network-credential `secret_ref` cannot omit or disagree with `secret_id`.

The sanctioned delete operation locks the credential row, rechecks structured usage, rejects non-expired active grants, removes terminal or expired grants and their owned versions, writes a redacted append-only deletion audit, and deletes the credential. Restrictive foreign keys and binding rows serialize concurrent consumer creation against deletion; an application-level count is never treated as the guard.

`network_credential_secret_versions` is owned secret history and can contain encrypted payload ciphertext. Its source foreign key therefore changes to `ON DELETE CASCADE` so permanent deletion removes all ciphertext-bearing versions. A separate append-only deletion audit retains only the credential UUID, safe public identity fields, actor, and timestamp. Resolution and OCSF audit rows may retain redacted historical context with their credential foreign key nilled, but never secret material.

Credential PaperTrail versions do not persist action input maps. Secret-bearing create and rotation actions otherwise risk copying submitted plaintext into `version_action_inputs` even when the virtual secret attribute is excluded from tracked changes. Action names and the explicitly redacted lifecycle/deletion events provide the audit trail instead.

## Migration Strategy
- Keep existing `network_credential_secrets` and `network_credential_rules` tables.
- Audit live consumer columns for orphans before changing them to restrictive foreign keys.
- Backfill FK-backed binding rows for all supported text/JSON credential references before enabling guarded deletion, and fail the migration if a network credential reference cannot be resolved safely.
- Cascade credential-owned version rows and introduce a redacted append-only deletion audit before exposing the destructive UI action.
- Backfill descriptor/auth metadata for existing secrets and rules where missing or ambiguous.
- Keep existing records readable while their owning package descriptor is active; do not retain a provider-specific native-profile fallback.
- Add new AWX controller token creation through `NetworkCredentialSecret` without requiring users to copy UUIDs.
- Move global guidance into a general credentials guide while provider-specific setup documentation remains with its package descriptor.

## Risks
- A generic page can become too abstract. Mitigation: descriptors carry concrete labels, descriptions, defaults, and inline field sets.
- Multiple consumers may expect different secret payload shapes. Mitigation: bounded declarative payload encodings and host-owned credential injection primitives, not provider serializers in core.
- A malicious package could request misleading or unsafe fields. Mitigation: signed-package approval plus a bounded field/control vocabulary, strict limits, and host-owned delivery semantics.
- Existing users may rely on current defaults. Mitigation: preserve old routes and stored values through compatibility descriptors during rollout.
- A missed denormalized reference could allow deletion to strand a consumer. Mitigation: enumerate every persisted reference path, normalize it into the FK-backed binding table, test every trigger path, and fail deletion whenever usage lookup is incomplete.
- A stale UI usage count could race with a new assignment. Mitigation: treat counts as presentation only and rely on restrictive foreign keys/bindings inside the delete transaction.
- Credential history can itself contain ciphertext. Mitigation: cascade owned secret versions and retain only a separate explicitly redacted deletion audit.
- PaperTrail action inputs can bypass attribute-level redaction. Mitigation: disable action-input storage for credential secret versions and test the database, events, errors, and rendered HTML for submitted marker values.

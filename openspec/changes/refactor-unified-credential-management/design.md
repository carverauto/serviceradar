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

## Migration Strategy
- Keep existing `network_credential_secrets` and `network_credential_rules` tables.
- Backfill descriptor/auth metadata for existing secrets and rules where missing or ambiguous.
- Keep existing records readable while their owning package descriptor is active; do not retain a provider-specific native-profile fallback.
- Add new AWX controller token creation through `NetworkCredentialSecret` without requiring users to copy UUIDs.
- Move global guidance into a general credentials guide while provider-specific setup documentation remains with its package descriptor.

## Risks
- A generic page can become too abstract. Mitigation: descriptors carry concrete labels, descriptions, defaults, and inline field sets.
- Multiple consumers may expect different secret payload shapes. Mitigation: bounded declarative payload encodings and host-owned credential injection primitives, not provider serializers in core.
- A malicious package could request misleading or unsafe fields. Mitigation: signed-package approval plus a bounded field/control vocabulary, strict limits, and host-owned delivery semantics.
- Existing users may rely on current defaults. Mitigation: preserve old routes and stored values through compatibility descriptors during rollout.

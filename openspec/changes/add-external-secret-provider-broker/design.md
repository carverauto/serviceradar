## Context
ServiceRadar already has internal encrypted credential records, network credential rules, plugin secret references, and some broker-grant behavior. External references extend that model to point a credential rule at an enterprise secret server record and resolve it at runtime; implementation limits are linked below.

External secret servers also change failure and trust behavior:
- a secret may be reachable from the control plane, from an edge agent, from both, or from neither
- a provider token may itself need secure storage and rotation
- a returned secret may be leased, versioned, disabled, or field-shaped
- checks should fail closed when a secret cannot be resolved
- plugins should not receive plaintext even when the resolved credential is needed for an HTTP/database request

## Implementation status and remaining integration

See [Declarative environments: future Delinea Secret Server integration](../../../docs/docs/declarative-environments.md#future-delinea-secret-server-integration)
for the implemented broker subset, remaining consumer and adapter work,
credential-custody constraints, and separate runner-delivery contract.
The design below describes the target contract, not completed acceptance.

## Goals
- Treat "internal encrypted secret" and "external secret reference" as interchangeable credential sources for consumers.
- Keep plugins untrusted with respect to credential custody.
- Support provider adapters later without forcing a data model rewrite.
- Support both control-plane and agent-side resolution depending on reachability.
- Make broker decisions auditable without logging secret values.
- Keep mapper/discovery, plugins, remote access, SNMP, and service monitoring on one credential resolution interface.

## Non-Goals
- No additional concrete adapter in this documentation follow-up; OpenBao/Vault support already exists.
- No generic "run arbitrary provider script" escape hatch.
- No plaintext external secret values in CNPG except optional encrypted local cache entries with strict TTL, when policy allows.
- No browser-side secret resolution.

## Core Model
Add these concepts:

- `SecretProvider`: configured external secret server connection metadata. Examples: `delinea`, `cyberark`, `vault`, `aws_secrets_manager`, `azure_key_vault`, `gcp_secret_manager`, `custom_future`. The implemented subset is described in the status note above.
- `SecretProviderAuth`: how ServiceRadar authenticates to the provider. New provider bootstrap credentials must use canonical internally encrypted custody, never plugin config. Existing OpenBao deployment-sourced authentication is a legacy limitation, as noted above.
- `CredentialSource`: either `internal_encrypted` or `external_reference`.
- `ExternalSecretReference`: provider ID, object/path identifier, optional field mapping, version selector, expected credential kind, redaction hints, cache/lease policy, and test status.
- `CredentialBrokerGrant`: target-bound, purpose-bound, consumer-bound, time-bound permission for an agent or control-plane worker to resolve a credential and use it in a specific adapter.

Existing `NetworkCredentialSecret` records should gain source metadata rather than forcing every consumer to learn a second credential table. A credential rule should point to a credential source and remain provider/purpose/target scoped exactly as it does today.

## Resolution Location
The system chooses one resolution location per grant:

- `control_plane`: core/web-ng resolves the external secret and either uses it locally or sends a short-lived encrypted broker payload to a trusted internal worker.
- `agent`: the agent resolves the external secret directly because the secret server is reachable only from the customer network or edge site.
- `hybrid`: the control plane authorizes and signs the grant, while the agent performs provider resolution and returns only status/audit metadata.

Provider configuration must declare allowed resolution locations. A credential rule cannot silently switch from control-plane to agent-side resolution without explicit provider policy.

## Agent-Side Broker
Agent-side resolution needs a dedicated broker inside the ServiceRadar agent, not the Wasm plugin runtime:

1. Control plane compiles an assignment or command with a broker grant reference.
2. Agent validates the grant, target, purpose, descriptor/consumer, allowed host/path/port, and expiry.
3. Agent broker resolves the secret from local cache or external provider adapter.
4. Agent injects the resolved credential into an owned adapter such as host HTTP headers, mTLS client material, database connect parameters, SNMP auth fields, SSH session setup, or mapper/discovery request builder.
5. Plugin guest code receives only response/status data and never the credential value.
6. Agent drops the secret from memory after use or lease expiry.

For Wasm host functions, credential injection should be explicit in the host request policy. A plugin may ask to use grant `g1` for an allowed target; the host validates and applies the credential if the descriptor and grant allow it.

## Caching and Leases
External references should support cache policy:

- `no_cache`: resolve every use
- `memory_ttl`: cache in memory for a short TTL
- `encrypted_ttl`: optional encrypted local cache for provider outages, disabled by default

Leased provider secrets must honor provider lease TTL and revocation semantics. Cache TTL cannot exceed the provider lease TTL or the ServiceRadar grant TTL. Failed refresh should fail closed unless an explicit encrypted cache grace policy is enabled.

## Provider Adapter Boundary
Each provider adapter should implement:

- health/test connection
- read secret by reference and field mapping
- optional read version
- optional lease/renew/revoke
- error classification: not found, unauthorized, unreachable, rate limited, bad field mapping, provider policy denied
- redacted audit metadata

Provider adapters must be project-owned modules. Third-party SDKs, when used later, should be wrapped behind ServiceRadar interfaces.

## UI Shape
Settings -> Credentials should include:

- Providers: create/edit/test external secret provider records, auth method, resolution location, and health.
- Secrets: internal secrets and external references in one list with source type, provider, object path metadata, version policy, rotation/last-tested state, and consumers.
- Rules: credential routing rules that can select either internal or external sources.
- Reference test: choose provider, object/path, field mapping, target credential kind, and test from control plane or selected agent without revealing the secret.
- Consumers: mapper/discovery jobs, plugins, SNMP profiles, remote access targets, service monitoring bindings, and northbound integrations.

Default flows must never ask users to paste internal UUIDs. Advanced views may show IDs and provider paths for troubleshooting.

## Security Decisions
- Provider bootstrap credentials are secret material and must be protected like any other credential.
- External secret values are never rendered to browser clients.
- Broker grants are single-purpose and target-bound.
- Plugins are not credential principals.
- Provider reference metadata can be sensitive; object paths and usernames should be redacted or access-controlled in non-admin views.
- Audit logs record who configured/tested/used a provider reference, from which agent/control-plane worker, for which target/purpose, with outcome and provider error class.

## Migration Plan
1. Add source metadata to credential records while treating all current secrets as `internal_encrypted`.
2. Add broker interfaces and no-op/stub provider adapter for tests.
3. Update existing credential consumers to call the broker instead of directly decrypting internal rows.
4. Add UI for provider and external reference records behind a feature flag.
5. Add provider-specific adapters later as separate proposals/PRs, starting with whichever system can be tested.

## Open Questions
- Should agent-side provider auth be provisioned through the same broker grant path or through deployment-local agent configuration?
- Do customers expect provider paths/object IDs to be visible to operators, or should they be treated as sensitive by default?
- Which external provider should be the first real adapter once test infrastructure is available?


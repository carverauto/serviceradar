# Change: Add external secret provider broker abstraction

## Implementation status and remaining integration

The original adapter-free scope below has been superseded by built-in stub,
OpenBao KV, and Vault-alias support. The external-reference model exists; Delinea
is only an enum placeholder and resolves to `adapter_unavailable` without an
adapter. Consumer migration, lease/renewal, audit, and UI/API coverage remain
partial, including legacy scheduled paths that materialize runtime parameters.
The current four-resource Terraform/public API surface creates internal encrypted
credentials, not external provider/reference records.

OpenBao bootstrap currently uses options/environment tokens or Kubernetes login;
canonical `internal_credential` lookup is not implemented by that adapter. New
provider bootstrap material must follow canonical encrypted credential custody,
not extend deployment-secret storage for integration credentials.

Delinea's reference-only adapter, declarative provider/reference management, and
secure credential handoff remain follow-up work. Separate runner delivery of an
existing ServiceRadar API identity from runtime broker resolution. The latter
requires scoped grants, field/version mapping, least-privilege authentication,
audited resolution/rotation, and explicit cache, lease, revocation, and outage
policy. Acceptance must test compatibility, rotation/revocation, provider outage,
failover reachability, and leakage in plans/state/logs/plugin configuration.
See the [customer workflow](../../../docs/docs/declarative-environments.md).

## Why
Operators have asked for ServiceRadar to retrieve credentials from existing enterprise secret servers instead of always storing credential material internally. This matters before expanding plugin/service monitoring because the credential contract needs to work consistently for mapper/discovery, SNMP, remote access, northbound integrations, and plugin-backed checks.

The product also needs a clearer trust boundary: plugins should not receive decrypted credentials. ServiceRadar should resolve credentials through a broker and inject them only into approved host functions, protocol adapters, or agent-owned request builders.

## What Changes
- Add a provider-neutral external secret provider abstraction for references to Delinea, CyberArk, HashiCorp Vault/OpenBao, cloud secret managers, and future systems with the implemented adapter subset and remaining follow-up described above.
- Extend reusable credentials so a credential can be either internally encrypted material or an external secret reference with provider, path/object identifier, field mapping, version selector, and rotation metadata.
- Define resolution locations: control-plane broker, agent-side broker, or hybrid broker depending on where the secret server is reachable and where the credential is needed.
- Add a credential broker contract that resolves, leases, caches, redacts, and audits external secrets without exposing plaintext to browsers, plugin params, assignment JSON, logs, or plugin result payloads.
- Ensure plugins receive credential grant references and target-bound host function authorization, not raw secret values.
- Make mapper/discovery, plugin assignment materialization, SNMP/profile resolution, remote access, and service monitoring consume the same broker interface.
- Add UI/API surfaces for configuring external secret providers, testing references, selecting fields, and showing health/audit state.

## Impact
- Affected specs:
  - `credential-secret-providers` (new)
  - `agent-config`
  - `network-discovery`
  - `plugin-configuration-ui`
  - `wasm-plugin-system`
  - `build-web-ui`
  - `platform-security`
- Related active changes:
  - `refactor-unified-credential-management` should use this as the storage/resolution abstraction beneath the unified UX.
  - `add-service-oriented-plugin-monitoring` should depend on broker grants and external references rather than assuming all credentials are stored internally.
  - `add-proxmox-plugin-credential-rules` provides current network credential rule and broker-grant semantics that this generalizes.
- Affected code:
  - Credential Ash resources and migrations for provider definitions, external references, lease/cache metadata, and audit records.
  - Agent config compilers and credential materializers for plugins, mapper/discovery, SNMP, remote access, and future service monitoring.
  - Go agent broker/runtime paths that inject credentials into host HTTP/TCP/database adapters without exposing them to Wasm guests.
  - Web-ng Settings -> Credentials UI and provider/reference test flows.
  - Redaction, audit, and policy enforcement tests.

## Non-Goals
- Additional adapters (including Delinea) remain follow-up; OpenBao/Vault support is already implemented.
- Do not let plugins call secret servers directly.
- Do not store provider master tokens in plugin configuration or agent assignment params.
- Do not make external secret servers mandatory; internally encrypted ServiceRadar credentials remain supported.
- Do not introduce multitenancy or cross-deployment secret sharing.


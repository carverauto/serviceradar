## Context
The data model already has generic names (`NetworkCredentialSecret`, `NetworkCredentialRule`) and a brokered runtime model, but the first UI was built around Proxmox. That creates confusing operator workflows:

- Provider is a free-text field with `proxmox` as the default.
- Auth method is exposed as implementation vocabulary rather than a provider-aware choice.
- Secret creation and rule creation are split awkwardly.
- AWX controller setup asks for a secret UUID even though operators naturally have an AWX token.
- SNMP, mapper/discovery, and plugin credentials still feel separate from credential rules.

## Goals
- Make `Settings -> Credentials` the canonical place to create, rotate, scope, test, and audit reusable credentials.
- Preserve provider-specific affordances without making the overall feature Proxmox-branded.
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

Forms use provider presets. Provider selection drives available auth methods, fields, defaults, tests, and docs links. Free-text provider entry is reserved for an "Custom provider" advanced mode.

## Provider Presets
Initial preset catalog:

- `awx`: API token for AWX/AAP controller API calls.
- `proxmox`: API token for PVE API and SSH private key for host console access.
- `snmp`: SNMPv1/v2 community and SNMPv3 auth/privacy fields.
- `ssh`: SSH private key or username/password for shell-style integrations.
- `http_api`: bearer token, header token, or username/password for generic HTTP integrations.
- `certificate`: client certificate/key pair.
- `opaque`: advanced escape hatch for plugin-specific secrets.

Each preset has labels, help text, validation, redaction behavior, default ports, and supported purposes.

## Migration Strategy
- Keep existing `network_credential_secrets` and `network_credential_rules` tables.
- Backfill provider metadata for existing Proxmox secrets/rules where missing or ambiguous.
- Add compatibility mapping so current `provider: "proxmox"` and auth methods continue to compile into Proxmox plugin assignments.
- Add new AWX controller token creation through `NetworkCredentialSecret` without requiring users to copy UUIDs.
- Move docs from provider-specific setup pages into a general credentials guide, with provider-specific sections linked from the preset UI.

## Risks
- A generic page can become too abstract. Mitigation: provider presets with concrete labels and inline field sets.
- Multiple consumers may expect different secret payload shapes. Mitigation: typed provider/auth serializers and provider-specific validation.
- Existing users may rely on current Proxmox defaults. Mitigation: keep Proxmox presets and preserve old routes as redirects or compatibility views during rollout.

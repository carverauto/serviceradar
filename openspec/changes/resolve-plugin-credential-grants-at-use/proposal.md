# Change: Resolve plugin credential grants at use, not at config delivery

## Why
Plugin assignments embed a short-lived credential-broker grant in the agent
config. Two defects follow from minting at compile/delivery time:

- **Churn.** The 60-second credential-rule reconcile mints and persists a grant
  per rule and purpose that the reconciler then ignores (grant fields are
  stripped before comparison), and config delivery can only reuse the grant id
  stored in the assignment, which is always stale, so it mints again and never
  stores the result. One deployment minted 11,154 grants in 24 hours for 8
  distinct scopes, most never resolved.
- **Expiry race.** A delivered grant lives `ttl_seconds` (300) and the agent's
  only refresh is its next config poll (300). Any poll jitter or gateway delay
  leaves the agent holding an expired grant, and a check in that window gets
  host error -2. Lengthening the TTL hides the race; it does not remove it.

## What Changes
- **Resolve by binding.** At host-request time the agent sends
  `ResolveCredentialGrant` with its agent id, the assignment id, and the
  binding id instead of a grant id. Core loads the *current* assignment,
  re-derives the binding's grant scope from it, re-runs every existing
  authorization check, then reuses a live grant of identical scope or mints
  one, and resolves material through that grant as today.
- **No grant id in config** for agents that advertise the
  `credential_broker_resolve_by_binding` capability. The binding carries its
  scope (consumer, purpose, rule, allow-lists, inject, resolution location) so
  the agent can still enforce host policy locally; the config version no
  longer changes when a grant rotates.
- **Reconcile stops minting.** The materializer writes the grant *scope* into
  the params template, never a minted grant. The reconcile worker stays: it
  still turns credential rules into assignments.
- **Version skew.** Agents that do not advertise the capability keep receiving
  an embedded grant exactly as now, minted at delivery with scope-keyed reuse
  (a live identical-scope grant is reused, so delivery stops minting every
  poll). They keep working, with today's expiry race, until upgraded. Core
  never sends a binding-only config to an agent that has not advertised the
  capability, and a new agent talking to an old core falls back to the
  embedded grant when the config carries one.
- **BREAKING (additive on the wire):** `CredentialBrokerResolveRequest` gains
  `assignment_id` and `binding_id`; `grant_id` becomes optional when both are
  present. Old agents and old cores are unaffected.

Security checks that MUST remain, unchanged in strength: exact-origin narrowing
of Proxmox bindings, agent binding (`agent_id` and partition from the mTLS
identity), consumer/purpose/rule/secret scope validation, `resolution_location`
agent or hybrid, system-actor-only grant issuance, and the credential-rule
lifecycle guard on issue. Resolution by binding authorizes against the current
assignment, so a disabled rule or a changed secret denies immediately instead
of at grant expiry.

## Impact
- Affected specs: `agent-config` (supersedes, for plugin assignments, the
  "Agent config carries broker grants" requirement in the unarchived
  `add-external-secret-provider-broker` change).
- Affected code: `proto/monitoring.proto`; core
  `edge/agent_gateway_sync.ex`, `edge/agent_config_generator.ex`,
  `plugins/credential_broker_delivery.ex`,
  `credentials/plugin_assignment_materializer.ex`,
  `credentials/credential_broker_grant.ex`, `plugins/proxmox_host_authority.ex`;
  gateway resolve forwarding; agent `plugin_runtime_http.go` and
  `plugin_runtime_host_authority.go`.

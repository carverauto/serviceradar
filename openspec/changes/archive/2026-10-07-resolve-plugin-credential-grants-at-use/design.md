## Context
Grants exist so the agent can resolve exactly one secret, for one consumer and
purpose, against one target, for a bounded time. The scope is what matters;
the grant row is the audit and revocation handle. Minting the row when config
is compiled ties its lifetime to config delivery, which is the source of both
the churn and the race.

## Decisions
- **Authorize against the current assignment at use.** The resolve handler
  looks up `PluginAssignment` by id, requires `agent_uid` to equal the
  mTLS-authenticated agent and the assignment to be enabled, finds the binding
  by id in the assignment's current params, and rebuilds grant attrs through
  the same `CredentialIntegration.grant_spec/5` and Proxmox host-authority
  narrowing used today. Anything that does not match denies, and the denial is
  audited like other broker denials.
- **Reuse, then mint.** `CredentialBrokerGrant.reuse_or_issue/2` returns a live
  grant whose full wire scope and metadata equal the rebuilt attrs and that
  will not expire within the agent cache margin, or issues one through the
  existing `:issue` action (system actor, rule lifecycle guard). The response's
  `lease_expires_at_unix` bounds the agent's material cache, as today.
- **Capability gate, not version compare.** The agent adds
  `credential_broker_resolve_by_binding` to `AgentHelloRequest.capabilities`.
  Config generation reads the capability recorded for the agent; unknown means
  legacy delivery.
- **The agent never reroutes.** Bindings stay origin-narrowed; this change does
  not alter which host a binding may reach.

## Risks / Trade-offs
- Each material cache miss is a core round-trip. That is unchanged: the agent
  already calls `ResolveCredentialGrant` before using any grant.
- Two delivery shapes coexist until every agent advertises the capability. The
  legacy path keeps its expiry race; the scope-keyed reuse only removes its
  churn.

## Migration
No data migration. Ship core first (accepts both request shapes, delivers per
capability), then agents. Remove legacy embedded-grant delivery in a later
change once no agent lacks the capability.

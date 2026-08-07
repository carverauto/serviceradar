## Context

There are three distinct NATS-related paths that must not be conflated:

1. The platform's internal NATS connection, used by core and central
   collectors.
2. The default edge OTLP path, where the `otel-collector` add-on durably
   spools data and sends it through `serviceradar-agent` to the gateway. This
   path does not require edge NATS.
3. Optional direct-to-leaf OTLP, where an operator intentionally deploys a
   NATS leaf at the edge and configures the add-on to publish there.

The current per-agent NATS package work was introduced for host-slice flow
attribution. In the current implementation, the central flow collector
publishes `flow.host-slice.<agent-id>` and core subscribes to that stream,
while the agent sends local process-attribution events to the gateway. The
agent-side `flowPublisher` is initialized from bootstrap fields but has no
production publication call site, so its credential is not required by the
active data path.

## Goals / Non-Goals

### Goals

- Make base agent enrollment and ordinary OTLP onboarding work without any
  platform NATS account seed or per-agent NATS JWT.
- Preserve durable gateway-relay behavior when no leaf exists.
- Make direct NATS access explicit, leaf-scoped, and add-on-scoped.
- Ensure missing optional direct-leaf material is reported as an explicit
  configuration state instead of silently producing a misleading worker
  discard during package creation.
- Provide a safe migration path for packages and hosts that received legacy
  `nats.creds` material.

### Non-Goals

- This change does not deploy or redesign the NATS leaf server itself.
- This change does not remove central NATS authentication for core, event
  writer, or the central flow collector.
- This change does not make the gateway relay depend on NATS at the edge.

## Decisions

### 1. Base onboarding is NATS-independent

The base agent bundle contains the gateway endpoint, agent identity, and
mTLS material. It does not contain `nats.creds`, `nats_creds_file`, or a
central `nats_url`. A package with a null `nats_credential_id` is valid unless
the operator explicitly requested a direct-leaf capability.

The old package columns may remain temporarily for read-only migration and
revocation bookkeeping, but their absence must not block base delivery.

### 2. Gateway relay is the default edge telemetry transport

The OTLP add-on defaults to `output.backend = "agent"`. Its local durable
spool and the existing agent-to-gateway acknowledged relay provide the
normal edge path. This keeps the agent's trust boundary centered on its
existing mTLS gateway connection and avoids storing a second platform
credential on every host.

### 3. Direct NATS is an explicit leaf-only capability

An operator must register/deploy a site-local NATS leaf and explicitly select
the direct JetStream backend before the control plane provisions any NATS
material for an edge add-on. `AddonAssignment.edge_site_id` is the
authoritative association between the add-on and the registered leaf. The
control plane must verify that the requested URL matches the selected
`EdgeSite.nats_leaf_url`, that the site is active, and that its
`NatsLeafServer` is connected; a central hub URL is not a valid substitute.

The first direct-leaf implementation is mTLS-only. A system-only issuer asks
the gateway CA to mint a short-lived certificate for the add-on assignment and
the authenticated agent partition. Core stores the returned PEM values
encrypted with AshCloak and injects them only into a ready add-on config; the
base bundle never contains them. The runtime writes the PEM values to a
mode-0600 temporary directory for its NATS client and removes that directory
when the runtime is replaced. `.creds` delivery is not part of this path and
no account seed is ever sent to the agent.

The selected NATS leaf must render the assignment's exact publish, JetStream
stream-management, and request/ack subjects in its `verify_and_map` user
authorization block. The certificate's CN/SPIFFE identity alone is not treated
as a permission grant; issuance stores the encrypted material as `pending`,
and a separate system-only ready transition is allowed only after the leaf
authorization is updated.

The assignment stores a derived direct-leaf scope containing the OTEL publish
subjects, JetStream stream name, and request/ack subscription subjects. A
direct assignment starts in `pending` and carries a monotonic identity
generation. Agent configuration delivery refuses the assignment until a
system-only issuer marks the matching generation `ready`; changing the
selected site or subject contract returns it to `pending`, while relay mode
clears the direct state. This makes credential rotation/revocation an
explicit lifecycle operation instead of treating a file path as proof that
the leaf has authorized the add-on.

### 4. Flow attribution remains gateway/core mediated

The central flow collector remains the publisher of raw flows and approved
per-host slices. Core's host-slice subscriber consumes those slices, and the
agent continues to send local attribution events through the gateway. The
base agent does not need a NATS publish connection for this path.

If a future feature needs an agent-side NATS publisher, it must be introduced
as a separately declared capability with an explicit transport, leaf
registration, subject allowlist, credential lifetime, rotation behavior, and
end-to-end authorization tests. It must not silently reuse base onboarding.

### 5. Explicit failure semantics

If direct-leaf mode is not selected, missing NATS account configuration is
not an error. If direct-leaf mode is selected but the leaf or its scoped
authentication is unavailable, the add-on assignment/configuration reports a
bounded actionable failure and remains pending or degraded; the base agent
package is not marked as incorrectly delivered.

## Alternatives Considered

### Keep provisioning a per-agent central NATS JWT

Rejected. It couples base onboarding to a control-plane account seed, places
unneeded credentials on hosts, and currently provisions an unused agent-side
publisher path.

### Send a broad platform NATS credential to every agent

Rejected. A compromised agent could read or publish outside its intended
scope, and the credential would still be unnecessary for gateway-relay OTLP.

### Require a NATS leaf for every agent

Rejected. The gateway relay is already the intended default for sites that do
not run a local broker, and requiring a leaf would add operational burden and
turn an optional durability optimization into a base dependency.

## Migration Plan

1. Stop enqueueing the legacy per-agent NATS worker for ordinary agent
   packages and update bundle generation so new base packages contain no NATS
   material.
2. Reconcile existing `edge_onboarding_packages` rows with legacy NATS
   metadata through `mix serviceradar.edge.nats_legacy`, not direct database
   edits. The command reports package IDs, lifecycle state, and presence of
   encrypted material without printing secrets. `--apply` uses a system-only
   Ash action that records a cleanup timestamp/reason, clears the encrypted
   payload, and then revokes the tracked credential. Reissue only packages
   whose explicitly requested direct-leaf capability still requires material.
3. Revoke legacy per-agent NATS users after confirming they are not required by
   a registered leaf deployment, and remove the known legacy credential file
   from upgraded agents.
4. Validate a normal agent enrollment, default OTLP relay, and flow
   attribution without any agent-side NATS credential.
5. Validate direct-to-leaf separately with a test leaf, scoped identity,
   credential rotation, disable/revoke, and denial of central-hub access.

## Risks / Trade-offs

- Removing the unused publisher may expose an undocumented deployment that
  relied on it. A repository-wide call-site check and a migration metric/log
  should be required before deletion.
- Direct-leaf on-demand credentials add configuration lifecycle complexity.
  Keeping the relay default limits that complexity to operators who opt into
  leaf mode.
- Legacy credentials may remain on hosts during the migration window. The
  migration must provide an auditable revocation and cleanup path rather than
  silently assuming they are gone.

## Open Questions

- Should the first direct-leaf implementation require mTLS-only and defer
  NATS `.creds` delivery, or support both from the start?
- Which existing leaf registration resource is authoritative for the local
  URL, leaf identity, and allowed subjects?
- Should legacy `nats_credential_id` columns be removed in a later migration,
  or retained for historical revocation/audit records?

## Context

The Proxmox integration crosses four trust boundaries:

1. web-ng and core authorize an operator and select an inventory-backed device;
2. the control plane creates an assignment or console-session command for an edge agent;
3. an untrusted Wasm plugin asks the agent host to perform provider operations;
4. the agent connects to a Proxmox API, WebSocket, or SSH endpoint using privileged credentials.

The security invariant is stronger than "the plugin does not log a token." A Wasm module must neither observe reusable credential material nor control enough of the final network request to redirect host-injected credentials. The agent host must be able to prove that the credential, operation, destination, and current user authorization all belong to one exact assignment or console session.

The inventory model adds another boundary. A native Proxmox VMID is unique only inside a cluster, and a cluster display name is not globally unique. ServiceRadar currently operates two integrations, farm01 and tonka01, whose PVE nodes can have the same hostnames and whose guests can have the same VMIDs. Console routing therefore cannot use a cluster name, node name, VMID, device IP, or legacy provider reference by itself.

### Threats in scope

- malicious, compromised, or buggy Wasm selecting an attacker endpoint, protected header, redirect, body, TLS policy, or SSH target;
- token, password, key, ticket, cookie, CSRF value, or redeemable reference disclosure through config, host-call parameters/results, linear memory, logs, errors, metrics, audit, or diagnostics;
- DNS rebinding, alternate textual IP forms, default-port ambiguity, redirect escape, Host/SNI confusion, and path or query normalization bypass;
- browser parameter tampering that selects a credential rule, controller, mode, node, VMID, agent, or route;
- collision or overwrite between integrations with identical native Proxmox identifiers;
- use of a service credential with more authority than the current user, making the broker a confused deputy;
- time-of-check/time-of-use changes to ownership, permission, credential policy, assignment, or session binding;
- old components accepting unsafe fields during a rolling upgrade.

Terminal content confidentiality from an already-authorized endpoint and compromise of the PVE itself are outside this change. Existing recording and remote-access policy changes remain responsible for terminal-data governance.

## Goals / Non-Goals

### Goals

- Keep all reusable Proxmox and SSH secret material outside Wasm-visible state.
- Make the host connector authoritative for every credential-bearing network field.
- Bind authorization and resolution to one exact actor, use, target, assignment, and session.
- make farm01 and tonka01 identities and ownership relationships collision-safe.
- Route a guest console only through its exact owning Proxmox controller and node.
- Fail closed during migration and mixed-version operation.
- Produce testable, redacted evidence before enabling demo console access.

### Non-Goals

- Replacing the external secret provider broker or introducing a Proxmox-specific secret store.
- Allowing arbitrary plugin-authored HTTP, WebSocket, or SSH requests with privileged credentials.
- Treating a guest's management IP as its Proxmox control-plane endpoint.
- Granting credential-use permission implicitly from device visibility or console-open permission.
- Solving generic SSH/RDP certificate enrollment, terminal recording policy, or every hypervisor provider in this change.
- Preserving authenticated Proxmox operation on an old agent through inline-secret compatibility.

## Decisions

### 1. Reuse the external-secret broker with a host-only Proxmox envelope

The control plane will place the broker grant and provider locator in the typed host-only portion of the plugin assignment. `PluginAssignmentConfig.host_params_json` (or its versioned typed successor) is consumed by trusted agent code and is never returned by Wasm `get_config`, copied into plugin environment variables, or included in plugin callbacks. The Wasm-visible parameters contain only non-secret presentation settings and semantic operation inputs.

The host-only envelope contains a signed or integrity-protected grant identifier, immutable assignment identity, provider integration/controller identity, allowed operation classes, target policy, body policy, purpose, expiry, maximum uses, and secret reference needed by the agent resolver. The secret reference is not a capability available to Wasm. Resolver output is delivered directly to the trusted connector in memory and is zeroed or dropped after use.

For inventory, Wasm may request a bounded semantic operation such as `cluster_status`, `node_status`, `guest_list`, or `guest_config` with an inventory object selector already present in the assignment. For console, Wasm may relay stream frames but cannot redeem the grant or author the provider request. The host connector maps the operation to the final method, path, body, and authentication mechanism.

Why: injecting `Authorization` into a generic plugin-authored URL still lets the plugin exfiltrate a token. A host-only grant plus a host-constructed semantic request removes both token visibility and target control.

Alternatives rejected:

- Passing a current-user bearer token to Wasm: it expands the plugin's authority and exposes a credential unrelated to the provider operation.
- Passing a Proxmox token or secret reference in `params_json`: Wasm can read, retain, replay, or disclose it.
- Letting the plugin build the final URL while the host only injects a header: target, path, redirect, and normalization attacks remain.

### 2. The trusted connector owns final HTTP, WebSocket, and SSH effects

Every privileged connector invocation is derived from the host-only grant and authoritative inventory state. Before resolving a secret and again immediately before dialing, the connector validates:

- exact allowed scheme and effective port;
- canonical hostname/origin and normalized address form;
- DNS answers against allowed addresses/CIDRs and a dial coupled to the validated answer;
- exact integration, controller, cluster, node, guest kind, and VMID target;
- TLS verification mode, SNI name, minimum policy, and approved trust roots;
- semantic operation, method, normalized path/query, and bounded body schema or digest;
- redirect policy, which defaults to deny; any permitted redirect is treated as a fresh fully authorized target;
- protected HTTP and WebSocket headers, including `Authorization`, `Cookie`, `Host`, ticket, and CSRF fields;
- WebSocket scheme, origin, upgrade path, query fields, and one-session provider ticket;
- SSH host, port, username/principal, address, and host-key verification policy.

The connector constructs protected fields itself. Wasm input cannot override them, cannot request `insecure_skip_verify`, and cannot substitute an IP, Host header, SNI value, redirect destination, SSH username, or provider ticket. For production Proxmox connections the target policy requires verified TLS; an explicitly separate development policy, if retained, cannot carry production credentials and is not enabled in demo.

All checks occur before resolver invocation where possible. Checks that depend on resolved material or DNS occur before network dial. A mismatch or missing binding yields a typed denial with no fallback.

For PVE SSH, the control plane selects one closed host-key policy:
`known_hosts` or `trust_on_first_use`. The value is removed from Wasm-visible
parameters and carried only in the server-generated host authority binding.
Missing, unknown, differently-cased, and `skip_verify` values invalidate an SSH
binding. API-token bindings carry no SSH host-key policy, preventing the same
field from becoming a generic plugin-controlled switch.

### 3. Introduce source-scoped `proxmox:v3` identities

The authoritative provider-instance tuple is:

```
(provider, integration_id, controller_id, native_cluster_id)
```

`integration_id` and `controller_id` are immutable ServiceRadar IDs, not display names, URLs, hostnames, or secrets. `native_cluster_id` is the normalized stable identifier reported by Proxmox. The canonical structured object identity adds `object_kind` and `native_object_id`:

```
proxmox:v3:<integration_id>:<controller_id>:<native_cluster_id>:<object_kind>:<native_object_id>
```

Components use one documented canonical encoding, and the database stores the structured columns in addition to the rendered reference. Object kinds distinguish `node`, `qemu`, and `lxc`; therefore QEMU VMID 100 and LXC VMID 100 are distinct. The integration/controller scope makes two otherwise identical clusters distinct.

All new writes and relationship keys use v3. Provider-neutral inventory consumers continue to use `provider_instance_ref` and `provider_ref`, but `provider_instance_ref` now resolves to the immutable structured source scope rather than a cluster display name.

Migration behavior:

1. Build v3 identities from the integration/controller source that produced each row.
2. Re-key hosts, guests, relationships, device links, and current-owner records transactionally and idempotently.
3. Retain v1/v2 references as read-only aliases only when source provenance yields exactly one v3 target.
4. Quarantine an alias with zero or multiple candidates. It cannot resolve a console, own a relationship, or accept an upsert.
5. Reject all new v1/v2 writes and any update that would overwrite an object from another source scope.

### 4. Derive guest console routing from authoritative ownership

A console request begins with a canonical ServiceRadar device UID. The server loads one unambiguous virtualization guest row and follows its current-owner relationship to the v3 provider instance, integration, controller, cluster, and owning PVE node. Trusted inventory state supplies the controller base origin and node selector. The guest's IP remains inventory data only and is never converted to `https://<guest-ip>:8006` for Proxmox API or WebSocket access.

The server ignores or rejects browser-supplied target kind, console mode, credential-rule ID, agent/gateway, provider reference, node, VMID, base URL, host, port, and TLS metadata. It selects an allowed mode from server policy and device capabilities. If the owner is absent, ambiguous, stale, changes before attach, or points outside the selected rule and assignment, the session fails and must be reissued. It never falls back to another PVE in the cluster.

For a native QEMU/LXC console, the host connector obtains a short-lived provider ticket from the exact owning PVE/controller API and uses it only for the exact WebSocket path. For PVE SSH, the connector dials the exact v3 node owner with verified host key policy. Generic SSH to a guest remains a separate remote-access route and cannot be selected as a fallback by the Proxmox console flow.

### 5. Separate console-open authority from credential-use authority

The initiating user must satisfy all of the following before any broker call:

1. authenticated current-user context;
2. `devices.console.open` on the canonical device;
3. `devices.console.credentials.use` for brokered console credentials;
4. the selected rule is enabled, targets the device and exact v3 provider instance, declares purpose `console_access`, and allows the actor's principal/roles/groups under its credential-use policy;
5. the selected agent/gateway assignment is active and owns that provider target.

The control plane records the authorization decision ID and actor in the session-bound grant. A system actor may perform mechanics after this decision but cannot widen the actor's target, purpose, operation, or credential-use authority. Authorization is checked at session creation and revalidated immediately before resolution/attach. Revocation, expiry, ownership change, or mismatch prevents resolution and closes any not-yet-established session.

This avoids passing a broad service token or the user's reusable ServiceRadar bearer token to Ansible, Wasm, the agent, or Proxmox. The broker validates a narrow signed decision rather than trusting caller-supplied claims.

### 6. Bind grants and provider tickets to one exact use

The broker grant and connector command carry and validate the following immutable binding set:

```
actor_id
authorization_decision_id
assignment_id and assignment_version
assignment_policy_fingerprint
session_id (for console)
device_uid
provider_ref_v3 and provider_instance_ref_v3
integration_id, controller_id, native_cluster_id
node_id, guest_kind, vmid (as applicable)
credential_rule_id and purpose
agent_id, logical gateway_id, and selected control-stream gateway_node
console_mode or inventory_operation
canonical_origin and target policy digest
issued_at, expires_at, maximum_uses
```

Console credential resolution and native provider tickets are single-session and single-use. Inventory grants may permit multiple bounded operations within one assignment lease, but each operation still has an allowlisted semantic operation and exact target. No grant is transferable between inventory and console purposes, devices, actors, agents, controllers, or clusters.

The assignment policy fingerprint is SHA-256 over a newline-delimited canonical
tuple with domain `serviceradar.proxmox.assignment-policy.v1`, assignment ID,
plugin ID, entrypoint, policy ID, decimal policy version, and credential-rule
ID. Session creation records the version and fingerprint. The broker copies
them into dedicated `ConsoleFrame` fields, and the agent compares them with the
active host authority before allocating a streaming slot or starting Wasm.
Policy-like fields in the JSON console payload are non-authoritative.

The broker resolves one current control-stream gateway node before sending the
open frame and pins every outbound frame to it. Agent-to-browser frames are
accepted only when the gateway-authenticated envelope supplies the same session
ID, agent ID, and gateway node. Missing or mismatched route tags are discarded;
an existing browser session is never silently repinned.

### 7. Mixed versions fail closed

The control plane and agent advertise support for the host-only envelope, Proxmox semantic connector contract, and v3 identities. Authenticated inventory and console assignments are issued only when all required capabilities are present.

- A new control plane does not send an inline-secret fallback to an old agent.
- A new agent rejects legacy Proxmox assignments containing raw secret material, a redeemable secret reference in Wasm params, plugin-authored protected headers, or v1/v2 authoritative identities.
- A new plugin on an old agent cannot receive a host-only grant and remains unavailable.
- New host authority bindings add required policy-binding fields. Strict older
  parsers reject those unknown fields; strict newer parsers reject older
  bindings that omit them.
- Compatible agents advertise `plugin-host-authority:v1`,
  `proxmox-semantic-connector:v1`, `proxmox-identity:v3`, and
  `proxmox-console-policy-binding:v1` on the authenticated control-stream
  hello. The gateway records those markers from that mTLS-owned stream; plugin
  results, browser input, and console JSON cannot assert compatibility.
- After applying a config, trusted agent host code reports the committed config
  version plus the exact assignment ID, plugin ID, policy version, and policy
  fingerprint for every successfully parsed Proxmox host binding. The proof is
  carried on `ConfigAck` and subsequent hello heartbeats and retained in live
  gateway control-session registry metadata.
- Before a broker sends an open, live gateway evidence must contain all four
  markers and the exact console-assignment proof. The persisted agent record
  must contain the same capability markers, acknowledge the same config
  version, and have no different pushed version pending. Missing evidence from
  an older control plane, gateway, agent, or plugin denies the open.
- Existing legacy records may be displayed during migration, but cannot authorize a console until mapped unambiguously to v3.

The UI reports an upgrade or migration prerequisite without exposing credential or topology details. Demo enablement waits until the control plane, target agents, and first-party plugin bundle all advertise the required versions.

Streaming executions capture a deterministic assignment generation after
host-only policy parsing. Removing the assignment or changing any stable
assignment, package, permission, public parameter, or host-authority field
cancels every execution of the prior generation. Trusted HTTP, WebSocket, and
SSH paths recheck that exact generation immediately before credential
resolution and again immediately before network dial, closing the
resolver-to-dial revocation window. Volatile broker lease refreshes may replace
material only when the stable host-authority fingerprint and generation remain
equal.

### 8. Audit evidence is structured and redacted

Audit events cover authorization allow/deny, rule selection, grant issue/reject, secret resolution outcome, connector validation, provider ticket issue/use, session attach/close, identity migration, ambiguous alias quarantine, and cross-source overwrite denial. They include stable IDs and policy/result codes, not raw credentials.

The redaction contract excludes tokens, passwords, private keys, passphrases, ServiceRadar bearer tokens, secret values, redeemable secret references, `Authorization`, cookies, CSRF values, provider tickets, credential-bearing query parameters, privileged request bodies, and terminal I/O. Operator errors name the phase and correlation ID only. Debug and test instrumentation obeys the same rule.

## Data Flow

```
Browser
  | device_uid + terminal dimensions
  v
web-ng/core
  | authorize open + credential use + rule policy
  | resolve v3 guest -> owner -> controller/node
  | issue exact signed session grant
  v
agent trusted host
  | validate assignment/session/actor/target bindings
  | resolve secret directly into trusted connector memory
  | construct and validate final request/session
  +-------------------------> exact owning PVE API/WebSocket/SSH
  |
  +-- non-secret semantic results/stream frames --> Wasm/console bridge

Wasm never receives the host-only grant, secret reference, resolved secret,
protected headers, provider ticket, or authority to choose the network target.
```

## Rollout and Migration

1. Add storage and indexes for structured v3 identities, current-owner relationships, legacy aliases, credential-use policy, authorization decision IDs, and exact session bindings.
2. Add capability negotiation and host-only assignment support before issuing the new assignments.
3. Backfill v3 identities per integration/controller, quarantine ambiguity, and compare counts and relationships without deleting legacy rows.
4. Deploy trusted connectors and first-party plugin versions together; keep authenticated Proxmox operations disabled for incompatible agents.
5. Migrate credential rules to explicit `console_access` actor-use policies and grant `devices.console.credentials.use` only to intended roles.
6. Run negative and migration suites, then prove farm01 and tonka01 coexist with overlapping native identifiers.
7. Enable the demo feature only after audit/redaction and exact-owner console proofs pass. Legacy aliases remain for bounded read compatibility and can be removed in a later change after usage reaches zero.

Rollback disables authenticated Proxmox assignments and console creation. It does not restore inline-secret delivery or v1/v2 authoritative writes.

## Risks / Trade-offs

- Semantic host connectors require more host code and version negotiation than generic HTTP host calls. This is intentional because generic plugin-authored requests cannot safely carry brokered provider credentials.
- Existing Proxmox assignments stop working until compatible components and v3 migrations are present. The fail-closed outage is preferable to preserving a credential-exposure path.
- Strict current-owner binding can require a new session after Proxmox migrates a guest between nodes. Reissuing is safer than silently retargeting a live credential grant.
- Some legacy identities cannot be migrated automatically. Quarantine and operator reconciliation preserve correctness at the cost of temporary console unavailability.
- Separate credential-use permission and rule policy add an operator configuration step. UI guidance and policy previews are required to make the denial actionable without weakening authorization.

## Open Questions

- What retention period is appropriate for unambiguous legacy aliases after all integrations emit v3 identities?
- Should a later provider-neutral change standardize semantic connector operation registries for other hypervisors, or should Proxmox remain the proving implementation first?
- Which Proxmox-native stable cluster identifier should be preferred when the API exposes multiple candidates? The implementation must document deterministic precedence and include the integration/controller scope regardless.

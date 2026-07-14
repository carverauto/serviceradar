## 1. Reconcile contracts and establish security gates

- [x] 1.1 Build a requirement-to-code-and-test matrix for this change and the overlapping requirements in `add-external-secret-provider-broker`, `add-proxmox-plugin-credential-rules`, `add-proxmox-guest-network-identity`, `fix-proxmox-inventory-plugin-reliability`, and `refactor-provider-neutral-hypervisor-enrichment`.
- [x] 1.2 Treat earlier Proxmox completion markers as superseded where they lack evidence for host-only custody, trusted target construction, v3 identity isolation, or exact guest ownership; block archival claims until this change's gates pass.
- [x] 1.3 Define versioned capability identifiers for the host-only assignment envelope, semantic Proxmox connectors, exact console binding, and `proxmox:v3` identities.
- [ ] 1.4 Add a release gate that rejects first-party Proxmox manifests or schemas exposing raw credentials, redeemable secret references, broker grants, protected headers, arbitrary targets, or TLS-disable fields to Wasm.

## 2. Move Proxmox credentials into host-only custody

- [ ] 2.1 Extend the typed assignment protocol with a host-only Proxmox broker envelope and ensure Wasm `get_config`, plugin callbacks, environment, diagnostics, and persistence projections cannot access it.
- [ ] 2.2 Update Proxmox provider-profile and assignment generation so inventory and console Wasm params contain only non-secret semantic inputs and no token, password, key, passphrase, ticket, cookie, CSRF value, redeemable reference, or broker authority.
- [ ] 2.3 Bind inventory grants to assignment version, integration/controller, v3 target, purpose, agent/gateway, operation set, target policy digest, expiry, and use limit.
- [ ] 2.4 Bind console grants to the current actor and authorization decision plus exact session, device, rule, v3 owner, controller/node/guest, agent/gateway, mode, origin, expiry, and one-use limit.
- [ ] 2.5 Deliver resolver output directly into trusted connector memory, clear it after use, and prevent it from entering Wasm-visible results, retries, logs, metrics, audit, crash output, or persisted agent config.
- [ ] 2.6 Reject legacy inline-secret and Wasm-visible secret-reference Proxmox assignments without a compatibility fallback.

## 3. Implement trusted Proxmox connectors

- [ ] 3.1 Define a bounded semantic operation registry for Proxmox inventory, provider ticket creation, WebSocket attach, and PVE SSH rather than accepting arbitrary privileged requests from Wasm.
- [ ] 3.2 Enforce exact scheme, canonical origin, effective port, normalized host/address, approved DNS answer/CIDR, integration/controller target, and dial-to-validation coupling before resolution and connection.
- [ ] 3.3 Enforce TLS verification, SNI, minimum TLS policy, and approved trust roots; remove production and demo support for plugin-selected `insecure_skip_verify`.
- [ ] 3.4 Construct and protect HTTP/WebSocket method, normalized path/query, body schema or digest, `Authorization`, cookies, CSRF, Host, upgrade fields, and provider tickets in trusted host code.
- [ ] 3.5 Deny redirects by default and fully reauthorize any explicitly allowed redirect as a new target before forwarding credentials.
- [ ] 3.6 Enforce exact SSH host, port, address, username/principal, session binding, and host-key verification policy; deny plugin or browser substitution.
- [ ] 3.7 Return bounded phase-specific errors and non-secret semantic results to Wasm while keeping credential-bearing provider responses host-owned.

## 4. Introduce collision-safe virtualization identities

- [ ] 4.1 Add structured `proxmox:v3` provider-instance and object identities containing immutable integration ID, controller ID, native cluster ID, object kind, and native object ID with a documented canonical encoding.
- [ ] 4.2 Add uniqueness constraints and upsert guards that prevent cross-integration, cross-controller, cross-cluster, and cross-kind overwrite.
- [ ] 4.3 Emit v3 identities and source provenance for every Proxmox cluster, PVE node, QEMU guest, LXC guest, and relationship.
- [ ] 4.4 Backfill hosts, guests, device links, and ownership relationships transactionally and idempotently from their producing integration/controller.
- [ ] 4.5 Create read-only legacy aliases only for one-to-one mappings; quarantine zero-match or multi-match aliases and deny their use for writes or consoles.
- [ ] 4.6 Add migration reconciliation reports for counts, duplicate native names/VMIDs, ambiguous aliases, relationship preservation, and prohibited overwrites.

## 5. Authorize and bind exact guest console routes

- [ ] 5.1 Add `devices.console.credentials.use` to the RBAC catalog and UI descriptions without implicitly granting it from device view or `devices.console.open`.
- [ ] 5.2 Extend Proxmox credential rules with explicit actor/principal/role/group use policy for purpose `console_access`, policy preview, and deny-by-default migration behavior.
- [ ] 5.3 Require authenticated current-user context, `devices.console.open`, `devices.console.credentials.use`, and a selected rule allow decision before any resolver invocation or privileged network effect.
- [ ] 5.4 Remove browser authority over target kind, console mode, credential-rule ID, provider/controller/node/VMID, route, agent/gateway, origin, port, and TLS fields; reject or ignore them and derive all values server-side.
- [ ] 5.5 Resolve a guest through one canonical device-to-v3-guest-to-current-owner relationship and exact controller base origin; never construct a PVE API target from guest IP or silently fall back to another node.
- [ ] 5.6 Persist and validate the full assignment/session/device/rule/actor/provider/controller/node/guest/agent/gateway/mode/origin binding at create, resolve, attach, and dial boundaries.
- [ ] 5.7 Obtain native QEMU/LXC console tickets in trusted host code and restrict each ticket to one session, exact owner, exact WebSocket path, short expiry, and one use.
- [ ] 5.8 Revalidate authorization, ownership, assignment version, and grant expiry immediately before resolution/attach; fail and require a new session after revocation or owner migration.

## 6. Add redacted audit and operational diagnostics

- [ ] 6.1 Emit structured allow/deny audits for authorization, rule selection, grant issue/use/reject, connector validation, provider ticket lifecycle, session lifecycle, identity migration, alias quarantine, and overwrite denial.
- [ ] 6.2 Redact tokens, passwords, keys, passphrases, bearer tokens, secret values/references, protected headers, cookies, CSRF, tickets, credential-bearing queries/bodies, and terminal I/O from all operator and diagnostic surfaces.
- [ ] 6.3 Add correlation IDs and safe reason codes so operators can distinguish permission, policy, ownership, version, TLS, target, and provider failures without seeing secrets.
- [ ] 6.4 Add metrics for denied binding mismatches, ambiguous identity aliases, incompatible versions, and connector policy failures using bounded non-secret labels.

## 7. Verify security and migration behavior

- [ ] 7.1 Add sentinel-secret tests that inspect Wasm config, host-call inputs/results, linear memory snapshots, logs, results, telemetry, audit, diagnostics, and persisted config for zero Proxmox/SSH secret exposure.
- [ ] 7.2 Add malicious-plugin tests for Authorization/cookie/ticket injection, target/Host/SNI substitution, alternate IP encodings, DNS rebinding, disallowed ports, path traversal/normalization, query smuggling, body substitution, redirects, TLS downgrade, and SSH host/user/host-key bypass.
- [ ] 7.3 Assert every denial occurs before resolver invocation or dial and does not retry through a less restrictive path.
- [ ] 7.4 Add actor, permission, rule-policy, purpose, assignment, session, device, provider, integration, controller, cluster, node, VMID/type, credential-rule, agent, gateway, mode, origin, expiry, and use-count mismatch tests.
- [ ] 7.5 Add migration tests with two source integrations that use identical cluster names, node names, QEMU VMIDs, and LXC VMIDs; prove distinct identities, relationships, upserts, and console owners.
- [ ] 7.6 Add legacy alias tests for unambiguous reads, ambiguous quarantine, rejected legacy writes, idempotent backfill, and rollback that does not restore unsafe credential delivery.
- [ ] 7.7 Add mixed-version matrices proving old control plane/new agent, new control plane/old agent, and incompatible plugin combinations fail closed with no secret or network effect.
- [ ] 7.8 Add concurrency tests for guest migration and authorization/rule revocation between session create, credential resolve, provider ticket issue, WebSocket attach, and SSH dial.

## 8. Prove farm01 and tonka01 in demo

- [ ] 8.1 Register or reconcile separate farm01 and tonka01 Proxmox integration/controller scopes and record their immutable IDs without placing credentials in test artifacts.
- [ ] 8.2 Sync both clusters through compatible edge agents and prove overlapping cluster/node names and VMIDs create distinct v3 provider instances, guests, device links, and current-owner relationships with no overwrite.
- [ ] 8.3 Capture host instrumentation proving inventory credentials and broker authority never enter Wasm-visible config, calls, results, logs, or diagnostics.
- [ ] 8.4 From guest device details, open one native console in each environment and prove the trusted connector targets the exact owning PVE/controller origin and node, never `https://<guest-ip>:8006`.
- [ ] 8.5 Demonstrate denials for wrong actor permission, credential-use policy, session, device, rule, agent, integration/controller, owner node, origin, mixed version, redirect, TLS policy, and replay before secret resolution or dial.
- [ ] 8.6 Verify lifecycle audits are complete and redacted, then enable the demo console action only for compatible, migrated, authorized devices.
- [ ] 8.7 Publish an operator runbook for integration identity, credential-rule purpose/use policy, RBAC assignment, migration diagnostics, certificate trust, and safe troubleshooting.

## 9. Validate and land

- [ ] 9.1 Run focused Elixir, Go, Wasm bundle, migration, connector, browser-console, and redaction test suites.
- [ ] 9.2 Run the repository security and quality gates required by the touched components.
- [ ] 9.3 Run `openspec validate harden-proxmox-console-credential-custody --strict` and resolve every error before review.
- [ ] 9.4 Attach the requirement matrix and farm01/tonka01 proof to the pull request; do not mark the change complete or enable demo until every security gate is evidenced.

## 10. Close Proxmox console transport bindings

- [x] 10.1 Carry the server-selected closed SSH host-key policy in host-only authority, support `known_hosts` and `trust_on_first_use`, and reject missing, unknown, `skip_verify`, browser, or Wasm overrides with Elixir and Go tests.
- [x] 10.2 Resolve and pin one control-stream gateway for each Proxmox broker, then reject inbound frames whose session, authenticated agent, or gateway-node binding is missing or different, with positive and negative broker tests.
- [x] 10.3 Persist the exact assignment policy version/fingerprint in the session, carry it in typed console-open fields, require an exact active-assignment match in the agent before startup or dial, regenerate protobuf bindings, and cover missing/mismatch/mixed-version behavior with focused tests.
- [x] 10.4 Advertise the four Proxmox security capabilities on authenticated control-stream hello, report host-parsed assignment proofs on hello/config ack, persist capability/config acknowledgement evidence, and require exact live plus persisted evidence before broker open.
- [x] 10.5 Bind streaming executions to a stable assignment generation, cancel them on removal/change, recheck before credential resolution and HTTP/WebSocket/SSH dial, and cover the resolver-to-dial revocation barriers.

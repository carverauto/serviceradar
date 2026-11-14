## Context
Agents advertising `credential_broker_resolve_by_binding` receive Proxmox host-authority bindings carrying `binding_id` and grant scope without an embedded `grant_id`. At execution time, the agent calls `ResolveCredentialGrant` with `(assignment_id, binding_id)`, and core authorizes the request against the current assignment before reusing or issuing a `CredentialBrokerGrant`.

Previously, `ProxmoxHostAuthority.binding_id/4` included the sorted `target_ids` map in the SHA-256 digest. Because `target_ids` contains mutable inventory fields (`device_uid`, `provider_ref`, `provider_instance_ref`, `cluster`, `native_cluster_id`, `controller_device_uid`, etc.) and reflects whichever target rows were materialized in the previous reconcile pass, routine inventory enrichment or target-set additions/removals rotated `binding_id` for an unchanged controller origin. Agents holding the prior config snapshot failed credential resolution until the next config poll.

## Goals / Non-Goals
- **Goals**:
  - Keep `binding_id` invariant across sibling target additions/removals and per-device inventory metadata updates for as long as the authority scope remains in the assignment's live target scope.
  - Preserve distinct `binding_id`s for distinct console authority scopes (per `(target_kind, node, vmid)` guest path ACL or per `node` controller target on a shared VIP).
  - Verify live target-scope membership explicitly and separately from `binding_id` during `plugin_host_binding_for_resolution/3`.
  - Ensure gateway credential-grant denial warnings print `failure_code`, `failure_kind`, `assignment_id`, and `binding_id` through `ServiceRadar.Logging.ConsoleFormatter`.
- **Non-Goals**:
  - Changing the Go agent wire schema (`serviceradar.plugin_host_authority.v1`) or weakening TLS origin/SAN validation.

## Decisions
- **Decision 1: Stable `binding_id` derivation**
  - `proxmox-inventory` (`run_check`): `SHA-256(assignment_id | credential_rule_id | origin)` (first 32 lowercase hex chars, prefixed with `proxmox-`).
  - `proxmox-console` (`run_console`):
    - Guest target (`target_kind` in `["qemu_guest", "lxc_guest"]`): `SHA-256(assignment_id | credential_rule_id | origin | "guest" | target_kind | node | vmid)`.
    - Host target (`node` present): `SHA-256(assignment_id | credential_rule_id | origin | "node" | node)` (falling back to `assignment_id | credential_rule_id | origin` when `node` is absent).
  - Candidate bindings are sorted deterministically by `{binding_id, canonical_target_ids}` and deduplicated via `Enum.uniq_by(& &1["binding_id"])` so Go's `decodePluginHostAuthority` never encounters duplicate `binding_id`s when multiple target rows map to the same controller origin.

- **Decision 2: Separate live target-scope membership verification**
  - `ProxmoxHostAuthority.live_target_scope_contains_binding?/6` evaluates the current assignment parameters (after source-scope enrichment and node-certificate SAN reconciliation) and confirms at least one live target resolves to `binding["origin"]` under `binding["credential_rule_id"]` and matches the binding's console target scope (`node`, `integration_id`, `controller_id`, and guest `{target_kind, vmid}` when applicable).
  - `AgentConfigGenerator.plugin_host_binding_for_resolution/3` checks `live_target_scope_contains_binding?/6` explicitly; once all targets for an origin (or console guest/node) leave the live scope, credential resolution is denied.

- **Decision 3: Console Logger allowlist and gateway denial metadata**
  - `ServiceRadar.Logging.ConsoleFormatter` already includes `failure_code` and `failure_kind` in `@printed_keys`; add `binding_id` (sorted alphabetically) and pass `assignment_id` and `binding_id` from `AgentGatewayServer.resolve_credential_grant/2` into `credential_grant_response/4` so gateway denial logs emit `agent_id`, `grant_id`, `assignment_id`, `binding_id`, `failure_kind`, and `failure_code`.

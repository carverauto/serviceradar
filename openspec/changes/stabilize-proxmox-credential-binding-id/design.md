## Context
Agents advertising `credential_broker_resolve_by_binding` receive Proxmox host-authority bindings carrying `binding_id` and grant scope without an embedded `grant_id`. At execution time, the agent calls `ResolveCredentialGrant` with `(assignment_id, binding_id)`, and core authorizes the request against the current assignment before reusing or issuing a `CredentialBrokerGrant`.

Previously, `ProxmoxHostAuthority.binding_id/4` included the sorted `target_ids` map in the SHA-256 digest. Because `target_ids` contains mutable inventory fields (`device_uid`, `provider_ref`, `provider_instance_ref`, `cluster`, `native_cluster_id`, `controller_device_uid`, etc.) and reflects whichever target rows were materialized in the previous reconcile pass, routine inventory enrichment or target-set additions/removals rotated `binding_id` for an unchanged controller origin. Agents holding the prior config snapshot failed credential resolution until the next config poll.

## Goals / Non-Goals
- **Goals**:
  - Keep `binding_id` invariant across sibling target additions/removals and per-device inventory metadata updates for as long as the authority scope remains in the assignment's live target scope.
  - Never offer the agent a console target that no delivered binding authorizes.
  - Verify live target-scope membership explicitly and separately from `binding_id` during `plugin_host_binding_for_resolution/3`.
  - Ensure gateway credential-grant denial warnings print `failure_code`, `failure_kind`, `assignment_id`, and `binding_id` through `ServiceRadar.Logging.ConsoleFormatter`.
- **Non-Goals**:
  - Changing the Go agent wire schema (`serviceradar.plugin_host_authority.v1`) or weakening TLS origin/SAN validation.

## Decisions
- **Decision 1: Stable `binding_id` derivation**
  - Both plugins: `SHA-256(assignment_id | credential_secret_id | origin | auth_method | verify_tls)` (first 32 lowercase hex chars, prefixed with `proxmox-`). `credential_secret_id` is resolved from the grant's `credential_secret_ref`; `auth_method` is the effective `api_token` or `ssh` mode; `verify_tls` is false only when `insecure_skip_verify` is set. A grant whose secret reference does not resolve builds no binding.
  - Candidate bindings are sorted deterministically by `{binding_id, canonical_target_ids}` and deduplicated via `Enum.uniq_by` on `binding_id` so Go's `decodePluginHostAuthority` never encounters duplicate `binding_id`s when multiple target rows map to the same controller origin.
  - The agent authorizes a console session only when the binding's `target_ids` match the session, so a console assignment keeps one target per binding: target rows whose candidate lost deduplication are removed from the public params. Inventory selects bindings by origin only and keeps every target.

- **Decision 2: Separate live target-scope membership verification**
  - `ProxmoxHostAuthority.live_target_scope_contains_binding?/6` evaluates the current assignment parameters (after source-scope enrichment and node-certificate SAN reconciliation) and confirms at least one live target resolves to `binding["origin"]` and, for console bindings, matches the binding's node or guest `{target_kind, node, vmid}` scope. Policy, credential-rule, SSH host-key and single-origin checks are already enforced when the bindings are rebuilt through `partition/5`.
  - `AgentConfigGenerator.plugin_host_binding_for_resolution/3` checks `live_target_scope_contains_binding?/6` explicitly; once all targets for an origin (or console guest/node) leave the live scope, credential resolution is denied.

- **Decision 3: Console Logger allowlist and gateway denial metadata**
  - `ServiceRadar.Logging.ConsoleFormatter` already includes `failure_code` and `failure_kind` in `@printed_keys`; add `binding_id` (sorted alphabetically) and pass `assignment_id` and `binding_id` from `AgentGatewayServer.resolve_credential_grant/2` into `credential_grant_response/4` so gateway denial logs emit `agent_id`, `grant_id`, `assignment_id`, `binding_id`, `failure_kind`, and `failure_code`.

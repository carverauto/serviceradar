# Change: Stabilize Proxmox Host-Authority Credential Binding Identity

## Why
`ServiceRadar.Plugins.ProxmoxHostAuthority` previously hashed all canonical `target_ids` fields (`device_uid`, `provider_ref`, `provider_instance_ref`, `cluster`, `native_cluster_id`, `object_kind`, `native_object_id`, `controller_device_uid`, `controller_provider_ref`, etc.) into each host-authority binding's `binding_id`. Whenever target-set membership or per-target inventory metadata changed between an agent's config poll and its `ResolveCredentialGrant` request, core rebuilt the assignment's bindings with a different `binding_id` and denied valid credential resolution with `:credential_binding_not_found`. In addition, gateway credential-grant denial warnings omitted `assignment_id` and `binding_id` (and `binding_id` was absent from `ServiceRadar.Logging.ConsoleFormatter`), obscuring binding-mode resolution failures in console logs.

## What Changes
- Derive `ProxmoxHostAuthority` `binding_id` strictly from the stable grant-authority identity -- `(assignment_id, credential_rule_id, origin)` for `proxmox-inventory`, `(assignment_id, credential_rule_id, origin, "guest", target_kind, node, vmid)` for guest-scoped `proxmox-console` bindings, and `(assignment_id, credential_rule_id, origin, "node", node)` for node-scoped `proxmox-console` bindings -- so target-set churn and inventory metadata updates do not rotate `binding_id`.
- Deduplicate candidate bindings deterministically per `binding_id` so multiple target rows resolving to the same authority scope produce one canonical binding envelope.
- Check live target-scope membership separately when resolving a credential by binding (`ProxmoxHostAuthority.live_target_scope_contains_binding?/6` invoked from `AgentConfigGenerator.plugin_host_binding_for_resolution/3`), refusing resolution when no live target in the current assignment scope maps to the binding's origin and target scope.
- Add `binding_id` to `ServiceRadar.Logging.ConsoleFormatter` `@printed_keys` (alongside `failure_code` and `failure_kind`) and attach `assignment_id` and `binding_id` to gateway credential-grant denial warnings.

## Impact
- Affected specs: `agent-config`
- Affected code:
  - `elixir/serviceradar_core/lib/serviceradar/plugins/proxmox_host_authority.ex`
  - `elixir/serviceradar_core/lib/serviceradar/edge/agent_config_generator.ex`
  - `elixir/serviceradar_core/lib/serviceradar/logging/console_formatter.ex`
  - `elixir/serviceradar_agent_gateway/lib/serviceradar_agent_gateway/agent_gateway_server.ex`

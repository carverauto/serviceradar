## 1. OpenSpec & Gateway Logging
- [x] 1.1 Validate `stabilize-proxmox-credential-binding-id` with `openspec validate stabilize-proxmox-credential-binding-id --strict`.
- [x] 1.2 Add `binding_id` to `ServiceRadar.Logging.ConsoleFormatter` `@printed_keys` and log `assignment_id` + `binding_id` alongside `failure_kind` + `failure_code` on gateway credential-grant denials (`AgentGatewayServer`).
- [x] 1.3 Add unit tests verifying gateway credential-grant denial logs print `failure_code`, `failure_kind`, `assignment_id`, and `binding_id` through `ConsoleFormatter`, and verify `//build:logger_metadata_contract_test`.

## 2. ProxmoxHostAuthority Stable Binding Identity & Live Scope Membership
- [x] 2.1 Derive `ProxmoxHostAuthority` `binding_id` from `assignment_id`, `credential_secret_id`, `origin`, `auth_method` and `verify_tls`, deduplicate candidate bindings deterministically per `binding_id`, and drop console target rows that lost deduplication from public params.
- [x] 2.2 Implement `ProxmoxHostAuthority.live_target_scope_contains_binding?/6` and invoke it explicitly in `AgentConfigGenerator.plugin_host_binding_for_resolution/3`.
- [x] 2.3 Add unit and database integration regression tests covering target-set churn, metadata updates, duplicate-origin deduplication, console public-target pruning, and live-scope target removal denial.

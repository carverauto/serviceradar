## Why

Operators need to know whether the switch interface an endpoint is plugged
into carries required configuration. The driving case is network access
control: an endpoint is compliant only if its access port has the expected
802.1X/NAC stanza. ServiceRadar already knows which switch and port an endpoint
uses (`switch_port_attachment`, populated from Armis and OpenText NNM), and
OpenText Network Automation can return one interface's stored configuration
(`show configlet`). Nothing connects the two, and the answer is not recorded on
the endpoint.

## What Changes

- Add an interface config check mode to the `opentext-nom` plugin. For each
  endpoint it reads the attachment (switch + port) from a configurable device
  field, expands shorthand interface names (`gi1/0/3` ->
  `GigabitEthernet1/0/3`), asks NA for that interface's stored configuration
  with `show configlet -host <switch> -start <block start> -end <block end>`,
  and evaluates operator-defined checks (required patterns, all/any) against
  the returned block. It never opens a device session.
- Checks, the SRQL target query, the attachment field, the interface block
  delimiters, shorthand expansions and the poll interval are all plugin
  configuration (JSON on the credential rule), so no bespoke UI is needed.
- Record each result on the endpoint as device metadata
  `config_check.<check>` = `{status, checked_at, switch, interface, missing}`
  through the atomic, merge-only `merge_metadata` path. Results never create
  devices. The value is queryable with SRQL.
- Target-policy input definitions gain an optional `fields` list so a plugin
  can receive operator-selected device fields (for example
  `switch_port_attachment` or `metadata.armis_access_switch`) that the fixed
  item allow-list drops today.
- Target-policy rules expose the poll interval as an operator control.
- **BREAKING (internal invariant):** an agent MAY hold more than one enabled
  assignment for the same plugin when they come from different provisioning
  sources (an inventory producer schedule and a target policy, or several
  target-policy chunks). Uniqueness moves from (partition, agent, plugin) to
  (partition, agent, plugin, provisioning source key). The agent already keys
  plugins by assignment ID.
- `opentext-nom` gains a second credential profile (a distinct provider) whose
  provisioning mode is `target_policy`, alongside the existing inventory
  profile.

## Impact

- Affected specs: `interface-config-compliance` (new), `wasm-plugin-system`,
  `device-inventory`.
- Affected code:
  - `go/cmd/wasm-plugins/opentext-nom` (config check mode, shorthand
    expansion, plugin_inputs parsing, result contract, manifest profile)
  - `elixir/serviceradar_core/lib/serviceradar/plugins/`
    (`validations/no_duplicate_enabled_assignment.ex`,
    `policy_assignment_reconciler.ex`, `plugin_input_payload_builder.ex`,
    `srql_input_resolver.ex`, `integration_descriptor.ex`)
  - `elixir/serviceradar_core/lib/serviceradar/credentials/`
    (`plugin_assignment_materializer.ex` interval and input fields)
  - a new result handler under `elixir/serviceradar_core/lib/serviceradar/network_config/`
    registered in `observability/plugin_result_ingestor.ex`
- Operators must enable the NA HTTP-JSON wrapper (already required by
  `opentext-nom`).

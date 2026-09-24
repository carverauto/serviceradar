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
- The check runs as a second `opentext-nom` producer schedule
  (`opentext-nom.interface.check`) provisioned by its own credential profile.
  It reuses the NA OAuth grant, the cadence control and the plugin
  configuration form that inventory already uses.
- Checks, the SRQL target query, the delivered device fields, the attachment
  field, the interface block delimiters and shorthand expansions are plugin
  configuration on the credential rule; the poll interval is the rule's
  cadence. No bespoke UI is needed.
- Producer schedules gain an optional `target_input` contract: the dispatcher
  resolves the SRQL device query held in the schedule params and delivers the
  rows, with operator-selected fields projected (for example
  `switch_port_attachment` or `metadata.armis_access_switch`), as
  `target_items` on the run.
- Record each result on the endpoint as device metadata through the atomic,
  merge-only `merge_metadata` path: a scalar `config_check_<check>` status
  (queryable with SRQL) and a `config_check_<check>_detail` map. Results never
  create devices.
- **Internal invariant change:** enabled assignments owned by different
  credential rules MAY coexist for the same plugin on one agent (the inventory
  rule and the check rule). Manual assignments and other policies keep the
  one-enabled-assignment rule, and reconciliation never adopts another rule's
  assignment.

## Impact

- Affected specs: `interface-config-compliance` (new), `wasm-plugin-system`,
  `device-inventory`.
- Affected code:
  - `go/cmd/wasm-plugins/opentext-nom` (config check mode, shorthand
    expansion, schedule target items, result contract, second producer
    schedule and credential profile, config schema)
  - `elixir/serviceradar_core/lib/serviceradar/plugins/` (`assignment_owner.ex`,
    `validations/no_duplicate_enabled_assignment.ex`,
    `policy_assignment_reconciler.ex`, `manifest.ex`,
    `producer_schedule_dispatcher.ex`, `plugin_input_payload_builder.ex`,
    `srql_input_resolver.ex`)
  - a new result handler under `elixir/serviceradar_core/lib/serviceradar/network_config/`
    registered in `observability/plugin_result_ingestor.ex`
  - `elixir/web-ng` plugin config form: a textarea control for string fields
- Operators must enable the NA HTTP-JSON wrapper (already required by
  `opentext-nom`).

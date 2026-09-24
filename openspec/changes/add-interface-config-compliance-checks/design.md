## Context

`ocsf_devices.switch_port_attachment` holds `{switch_hostname, port, ...}` for
endpoints, promoted from Armis (`armis_access_switch`) and OpenText NNM
(`facts.switch_port_attachment`). Ports arrive in source form, often shorthand
(`gi1/0/3`). OpenText NA's HTTP-JSON wrapper runs NA CLI commands; verified
against a live NA: `show configlet -deviceid <id> -start "vlan 1" -end "exit"`
returns `{"result": "<block>"}`, and `-host <hostname>` selects a device by
name. Target policies (`PluginTargetPolicy`, `plugin_inputs.v1`) already turn an
SRQL query into chunked device items delivered to a plugin assignment.

## Goals / Non-Goals

- Goals: per-endpoint interface compliance from NA's stored config;
  operator-defined checks without new UI; results queryable on the endpoint;
  polling cadence and target set in plugin configuration.
- Non-Goals: pushing configuration; a general config policy engine; parsing
  whole configs in Wasm; vendors other than those NA can return configlets for;
  a UI beyond the existing credential-rule form.

## Decisions

- **Same package, second credential profile.** The check is a mode of
  `opentext-nom` (user decision), provisioned by a second credential profile
  with its own provider (`opentext-nom-config-check`) and `target_policy`
  provisioning whose consumer is `opentext-nom-inventory`. Manifests already
  allow several profiles with distinct providers.
- **Assignment uniqueness by provisioning source.** Today one enabled
  assignment per (partition, agent, plugin) makes the inventory assignment and
  the policy assignment collide, and the reconciler's adopt path would
  overwrite one with the other; several policy chunks on one agent collide the
  same way. The rule becomes one enabled assignment per (partition, agent,
  plugin, source key), where the source key is the policy assignment key
  (policy + input + chunk) for policy rows and a fixed key for manual and
  producer-schedule rows. Adoption only adopts a row with the same source key.
  The agent keys runners by assignment ID, so it needs no change.
- **Projected input fields.** An input definition MAY list `fields` from a
  closed set of path forms: a top-level SRQL device column
  (`switch_port_attachment`) or `metadata.<key>`. Values are copied into the
  item under `fields`. Paths are validated when the policy is built;
  unknown forms are rejected rather than ignored. Item and chunk byte limits
  still apply.
- **Mode selection.** A run whose config is a `plugin_inputs.v1` payload is a
  config check run; otherwise the plugin keeps its inventory/action behavior.
  The check configuration arrives in the payload `template`.
- **Attachment parsing.** The configured field yields either a map with
  `switch_hostname`/`port` or a `switch:port` string (split on the last `:`).
  Missing or unparsable attachment yields status `unknown`, not a failure.
- **Shorthand expansion.** A built-in, case-insensitive prefix table
  (`gi`->`GigabitEthernet`, `te`->`TenGigabitEthernet`, `fa`->`FastEthernet`,
  `tw`->`TwoGigabitEthernet`, `fi`->`FiveGigabitEthernet`,
  `twe`->`TwentyFiveGigE`, `fo`->`FortyGigabitEthernet`,
  `hu`->`HundredGigE`, `eth`->`Ethernet`, `po`->`Port-channel`) that operators
  can extend or override. A port with no alphabetic prefix (ArubaOS-Switch
  `1/1/20`) is used as-is.
- **Block delimiters.** `start` is a template (default `interface {interface}`)
  and `end` a literal (default `!`; ArubaOS-Switch uses `exit`), both
  configurable.
- **Evaluation in the plugin.** Checks are simple and declarative (required
  literal or regex lines, `all`/`any`, case sensitivity), so the plugin
  evaluates them and returns verdicts, keeping config text out of results.
  The configlet body is not placed in result details.
- **Recording.** A dedicated handler accepts
  `serviceradar.interface_config_check.v1` results and, per device UID, runs
  `Device.merge_metadata` with `%{"config_check" => %{<check> => verdict}}`.
  It never creates devices; an unknown UID is skipped and counted. The merge is
  atomic and replaces only this plugin's check keys.
- **Polling.** The rule's `interval_seconds` (already read from rule metadata,
  default 300) becomes an operator control; the plugin config documents the
  default for compliance checks (3600).

## Risks / Trade-offs

- Relaxing the uniqueness invariant could let a bug create duplicate rows for
  one source -> the source key keeps exactly one row per source, and tests
  cover adopt/no-adopt paths.
- Switch hostnames from Armis may not match NA's hostname -> status `unknown`
  with reason `switch_not_found`; operators can point the attachment field at a
  source whose names match.
- NA calls are slow (15-30s each) -> per-run item cap and the existing chunking;
  OAuth tokens are cached by the agent.

## Migration Plan

Additive for existing plugins. Existing enabled assignments keep a single row
per (agent, plugin, source), so no data migration is needed.

## Open Questions

- Whether NA's `-type` helper argument can return interface blocks without an
  explicit end pattern (to verify against a live NA).

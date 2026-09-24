## Context

`ocsf_devices.switch_port_attachment` holds `{switch_hostname, port, ...}` for
endpoints, promoted from Armis (`armis_access_switch`) and OpenText NNM
(`facts.switch_port_attachment`). Ports arrive in source form, often shorthand
(`gi1/0/3`). OpenText NA's HTTP-JSON wrapper runs NA CLI commands. Verified
against a live NA:

- `show configlet -host <switch> -start <start> -end <end>` returns
  `{"result": "<block>"}` for a configured interface.
- For a known switch whose interface has no stanza (an unconfigured
  ArubaOS-Switch port) it returns HTTP 200 with `{}`.
- For a switch NA does not know it returns HTTP 400 with a message.

## Goals / Non-Goals

- Goals: per-endpoint interface compliance from NA's stored config;
  operator-defined checks without new UI; results queryable on the endpoint;
  targets and cadence in plugin configuration.
- Non-Goals: pushing configuration; a general config policy engine; parsing
  whole configs in Wasm; a UI beyond the existing credential-rule form.

## Decisions

- **Second producer schedule, same package.** `opentext-nom` gains a producer
  schedule `opentext-nom.interface.check` and a credential profile
  (`opentext-nom-config-check`, purpose `config_compliance`) that provisions
  it. Producer schedules already supply the NA OAuth token-URL derivation, the
  cadence control and the plugin configuration form; target policies do not
  (their grants cannot derive a token URL from plugin config, and their rules
  expose neither config nor interval), so they were not used.
- **Schedule target items.** A producer schedule MAY declare
  `target_input: {entity: devices, query_param, fields_param?, max_items}`.
  The dispatcher reads the SRQL query and field list from the schedule params
  (operator plugin config), resolves it once per dispatch, and adds
  `target_items: {entity, query, total, truncated, items}` to each run. Items
  are normalized device rows. `dispatch_scope` stays `assignment`: the check
  runs where NA is reachable (the rule's agent), not on each endpoint's agent.
- **Projected fields.** A field is a top-level SRQL device column or
  `metadata.<key>`, copied under the item's `fields`. The whole `metadata` map
  is rejected: arbitrary metadata can carry sensitive integration data.
- **Assignment ownership.** Producer-schedule provisioning creates one
  assignment per credential rule and agent, so the inventory rule and the check
  rule collide under the one-enabled-assignment-per-plugin rule. Ownership is
  derived from `policy_id`: two assignments owned by different credential rules
  (`network-credential-rule:<id>...`) may coexist; manual rows and any other
  policy id keep the original rule. A rule's drifted policy id still conflicts
  with its own row, and the target-policy reconciler never adopts another
  rule's assignment. The agent keys runners by assignment ID, so it needs no
  change.
- **Attachment parsing.** The configured field yields either a map with
  `switch_hostname`/`port` (or `raw`) or a `switch:port` string (split on the
  last `:`). Missing or unparsable: `unknown` / `attachment_missing`, no NA
  request.
- **Shorthand expansion.** A built-in table (`gi`, `te`, `fa`, `tw`, `fi`,
  `twe`, `fo`, `hu`, `eth`, `po`) matched exactly against a port's whole
  alphabetic prefix, case-insensitively, with operator overrides. A port with
  no alphabetic prefix, or with a full name, is unchanged.
- **Block delimiters.** `block_start` template (default
  `interface {interface}`) and `block_end` literal (default `!`; ArubaOS-Switch
  uses `exit`).
- **Verdicts.** An empty block from a known switch is evaluated as-is, so
  required patterns are missing: `non_compliant` with reason
  `interface_not_configured`. NA rejecting the command (unknown switch):
  `unknown` / `configlet_not_found`. Timeouts and 5xx: `unknown` /
  `configlet_request_failed`. NA auth or permission failure aborts the run.
  Configlets are memoized per (switch, interface) within a run.
- **Evaluation in the plugin.** Checks are declarative (literal or regex,
  `all`/`any`, case sensitivity), so the plugin returns verdicts and no
  configuration text.
- **Recording.** `NetworkConfig.InterfaceCheckIngestor` accepts
  `serviceradar.interface_config_check.v1` and writes, per device, two
  top-level metadata keys through `Device.merge_metadata`:
  `config_check_<check>` (scalar status) and `config_check_<check>_detail`.
  SRQL filters only top-level metadata keys (`metadata.<key>`, key limited to
  `[A-Za-z0-9_-]`, 64 characters), so the status is not nested and check names
  are limited to 44 characters. Unknown UIDs are skipped, never created, and
  only `config_check_*` keys can be written.
- **Configuration form.** The definition is a JSON string property rendered as
  a textarea (`x-serviceradar-ui-control: textarea`), because the schema form
  does not render nested objects. Inventory and retrieve drop the check-only
  keys before their strict parse.

## Risks / Trade-offs

- Relaxing the uniqueness rule could let two rows of one rule coexist -> the
  owner is the rule id, so drift within a rule still conflicts and adopts;
  covered by tests.
- Switch hostnames from Armis may not match NA's hostname -> `unknown` /
  `configlet_not_found`; operators can point `attachment_field` at a source
  whose names match.
- NA calls take 15-30s each -> memoization, `max_items`/`max_targets` caps, a
  30-minute schedule timeout, and OAuth tokens cached by the agent.

## Migration Plan

Additive. Existing enabled assignments keep one row per owner, so no data
migration is needed.

## Open Questions

- Whether NA's `-type` helper argument can return interface blocks without an
  explicit end pattern.

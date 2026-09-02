---
sidebar_position: 10
title: Add-on Config Contracts
---

# Add-on Config Contracts

Native add-on assignments carry operator parameters (`AddonAssignment.params`)
that core serializes as `config_json` and delivers to agents, where a typed
decoder (Go struct or Rust serde struct) parses them. A type-shape mismatch on
that path is an outage class: a single mistyped value used to fail the agent's
decode permanently, block config acknowledgement, and silently wedge the agent
(the 2026-07 netprobe `capture_interfaces` incident stopped flow attribution
fleet-wide). This page documents the contract rules that prevent it, the
compatibility forms delivery coerces, and the CI contract tests every bundled
add-on must keep green.

## Where the contract is enforced

1. **Write time.** Every `AddonAssignment` write path (manual assignment,
   add-on profile reconciliation, and profile authoring) validates params
   against the add-on package's `config_schema`
   (`ServiceRadar.Plugins.Validations.AddonAssignmentParams`). Invalid params
   are rejected before they persist.
2. **Delivery time.** The agent config generator coerces params against the
   package schema and then re-validates the coerced result right before
   `config_json` encoding. Params that still cannot conform **refuse
   delivery**: that add-on's config section is withheld from the agent config
   (never shipping JSON the agent decoder is known to reject), a
   `[:serviceradar, :addon_config, :delivery_refused]` telemetry event fires
   with the agent, add-on, assignment and field errors, and a deduplicated
   error log identifies the offending field. Fix the assignment params (or run
   the backfill task below) to resume delivery; recovery is logged.
3. **Agent side (defense in depth).** Decoders accept the documented
   compatibility forms below, so schema-compatible drift that still slips
   through degrades gracefully instead of wedging config apply.
4. **CI.** Contract tests decode representative core-emitted `config_json`
   with the real agent/add-on decoders for every bundled add-on (see below).

### Empty-schema policy

A package that declares **no** `config_schema` gives validation nothing to
type-check, so writes are allowed (blocking would break sample/dev add-ons) —
but core logs a warning once per package when non-empty params are stored
against a schemaless package, and delivery passes such params through
unchanged. Declare a `config_schema` in the add-on manifest to get typed
contracts; a schemaless add-on's params are shipped exactly as stored.

### Legacy rows

Rows persisted before the write-time guards existed are covered by the
backfill task:

```bash
# Dry run: classify every assignment (ok / coercible / invalid / unvalidatable)
mix serviceradar.validate_addon_params

# Rewrite coercible rows with their schema-coerced params
mix serviceradar.validate_addon_params --execute
```

Rows reported `invalid` stay undelivered (the delivery path refuses them)
until an operator fixes the params. There is currently no per-assignment
validation-status field to persist the refusal on — surfacing it on the
assignment record in the UI is follow-up work.

## Compatibility forms (delivery-side coercion)

Delivery coerces stored params toward the schema-declared types. Only values
that are **present** are touched — no defaults are injected for absent
top-level keys, no keys are added or removed at the top level, and `null`
passes through untouched (it means "unset" to agent-side decoders). The
documented forms:

| Schema type | Stored form tolerated | Delivered as |
|---|---|---|
| `array` (of strings) | scalar string `"ens18"` or CSV/newline list `"ens18, ens19"` | `["ens18"]` / `["ens18", "ens19"]` (trimmed, blanks dropped) |
| `integer` / `number` | numeric string `"500"` | `500` |
| `boolean` | `"true"` / `"false"` (any case) | `true` / `false` |
| `object` | object | recursively normalized against the nested schema (nested defaults apply) |

Agent-side, the netprobe decoder additionally accepts a plain JSON string for
`capture_interfaces` (decoded as a single-element trimmed list, empty string
as an explicit empty list), and the Rust add-on decoders are lenient about
unknown keys. **Add-on authors must not rely on these tolerances** — they are
last-resort degradation, not API. Declare the correct type in
`config.schema.json` and let the control plane enforce it.

Anything the coercion table cannot fix (e.g. `"not-a-number"` for an integer,
a missing schema-required field) refuses delivery as described above.

## CI contract tests

The committed fixtures under `go/pkg/agent/testdata/addonconfig_contract/`
are the exact `config_json` bytes core's delivery path emits for
representative assignments of every bundled add-on — including
compatibility-form inputs, so the fixtures always carry the coerced,
schema-typed shapes. They are decoded by the real decoders in CI:

| Add-on | Real decoder exercised | Test |
|---|---|---|
| netprobe | agent-side `netprobe.ApplyAddonConfigJSON` (Go) | `go/pkg/agent/addon_config_contract_test.go` |
| bumblebee-scan | `bumblebee.LoadConfig` (Go, strict), after the agent's real staged-base merge | `go/pkg/agent/addon_config_contract_test.go` |
| scalibr-endpoint-inventory | `scalibrinventory.LoadConfig` (Go, strict), after the staged-base merge | `go/pkg/agent/addon_config_contract_test.go` |
| anomaly-addon | `AddonConfig` serde decode (Rust) | `rust/anomaly-addon/src/config.rs` |
| otel-collector | `parse_config` (Rust) | `rust/otel-addon/src/addon.rs` |
| workload-identity | daemon `Config`/`load_config` (Rust) | `rust/workload-identity/src/bin/workload-identity.rs` |
| rdp-adapter | none — the binary consumes no config file (stdio wire protocol; its schema declares zero properties). The contract is that core delivers **no** config bytes. | `go/pkg/agent/addon_config_contract_test.go` |

Known honest gap: the anomaly-addon schema's `metric_feed` /
`metric_feed_sources` keys are core-side feed routing, not fields of the Rust
`AddonConfig`; the lenient decoder ignores them (asserted in the test
comments), and they are not contract-checked beyond that.

### Regeneration workflow (add-on authors)

When you change an add-on's `config.schema.json`, the representative params,
or the delivery-path coercion rules:

```bash
cd elixir/serviceradar_core
mix serviceradar.gen.addon_contract_fixtures
```

and commit the updated fixtures. Enforcement is two-sided:

- The ExUnit drift test
  (`test/serviceradar/edge/addon_config_contract_fixtures_test.exs`) fails
  when the committed fixtures no longer match what the delivery path emits.
- The Go/Rust contract tests fail when a committed fixture stops decoding
  with (or stops round-tripping values through) the real decoder.

A new bundled add-on must add: representative params in
`ServiceRadar.Plugins.AddonConfigContractFixtures` (cover every schema
property you can, plus at least one compatibility-form input per coercible
type), a decode test against its real decoder (Go package test or in-crate
Rust test with the fixture in `compile_data`), and the regenerated fixture.

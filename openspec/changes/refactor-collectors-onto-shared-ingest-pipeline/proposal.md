# Change: Run rules and binary encoding in the collectors, on shared crates

## Why

Core still does work that belongs at the collection point. `EventWriter`
decodes JSON and runs Zen rules for every log record that arrives as JSON
(`elixir/serviceradar_core/lib/serviceradar/event_writer/processors/logs.ex:202`),
and several collectors still publish one JSON message per record. That costs
CPU and allocations twice: once to encode at the collector and once to decode,
transform and re-encode in core.

The log collector already shows the better shape for syslog: it follows the
ruleset core publishes, applies it itself, and publishes OTLP batches that
`EventWriter` stores without running rules again. That path became the default
in #6863. Three things stop it from being the shape of every collector:

- **Rules reach the collector through datasvc gRPC.** An edge collector cannot
  use that path, and datasvc must not be exposed to the edge. No edge collector
  bundle carries a ruleset today, so edge syslog is still normalized in core.
  `openspec/project.md` already plans to phase datasvc out.
- **The code lives inside one collector.** Receive, rule following and batch
  publishing are in `rust/flowgger` and `rust/log-collector`. The trap daemon,
  the flow collector and the BMP collector each have their own socket loop and
  NATS output.
- **Core keeps a rules path for collector data.** As long as a collector can
  fall back to publishing JSON for core to normalize, core has to keep Zen on
  the ingest path.

## What Changes

- **Rule bundles move to their own NATS key-value bucket.** Core writes
  bundles there. A collector reads and watches the bucket over the NATS
  connection it already has. One release after the NATS reader ships, the
  collector's datasvc client, its datasvc role and its `[rules.datasvc]`
  configuration are removed. **BREAKING** for hand-maintained collector
  configuration.
- **Edge collectors read the hub's rules bucket through their leaf.** The
  leaf connection already reaches the hub's JetStream; the collector addresses
  the hub's JetStream domain over its local leaf. Nothing is replicated and
  nothing new is exposed to the edge. A running collector keeps its active
  ruleset while the site is disconnected.
- **A collector without a ruleset passes records through.** It publishes them
  in the binary batch format with the built-in field mapping and no rules, as
  an ordinary syslog collector would, on the same `logs.normalized.<kind>`
  subject and without the `Sr-Ruleset-Id` header. EventWriter stores such a
  batch without rules; the NATS publish permission on that subject, held only
  by collector identities and the edge leaf that forwards an edge collector's
  batches, is what authorizes it. It no longer publishes JSON
  for core to normalize.
- **Core stops running Zen on collector data.** `EventWriter` stores what
  collectors publish. Once each subject's overlap release has passed, Zen
  stays in core only for records core produces itself (`logs.internal.*`).
  **BREAKING**: a Zen rule authored for the trap subject stops being evaluated
  in the release after the new trap daemon ships. For each subject, core drops
  Zen one release after the collector that makes it unnecessary.
- **Shared Rust crates** hold what every collector needs: receive (portable
  batched sockets, with io_uring and AF_XDP backends where verified), rules
  (fetch, watch, verify, compile, apply) and publish (binary batches into NATS
  with stable retry). Each collector adopts the crates it needs and keeps its
  protocol parser and its record-to-column mapping: syslog uses all three,
  OTLP logs use rules and publish, the trap daemon uses receive and publish,
  the BMP collector uses publish, and the flow collector, which already
  publishes protobuf, uses receive.
- **Collectors move onto those crates one at a time**, in this order: syslog
  (already most of the way), OTLP logs, the SNMP trap daemon, the BMP
  collector, then the flow collector's receive path.
- **The trap daemon emits final fields itself and runs no rules.** Its seeded
  rule is fixed field mapping, not rule logic, so it does not use the rules
  crate, and the trap passthrough seed is removed in the release after the new
  trap daemon ships. It adopts the
  receive crate (io_uring and AF_XDP available) and publishes binary batches
  through the publish crate. The daemon emits today's stored row: severity,
  derived `source_ip`, `source` and `service_name` set to `snmp`, the rule's
  `body` text, and `attributes.snmp` source, version, varbinds, trap OID and
  detail. The one difference is that it stops storing the SNMP community
  string (`attributes.snmp.community`).

This change builds on `accelerate-log-ingestion` (rules at the collector,
binary batches) and `add-zero-copy-log-receivers` (receive backends) and
widens their scope from the log collector to every collector. It amends the
"Versioned ruleset activation" requirement in `accelerate-log-ingestion`,
which named datasvc as the transport.

## Impact

- Affected specs: `collector-rule-distribution` (new),
  `collector-ingest-pipeline` (new), `observability-rule-management`,
  `zen-rule-editor`; pending change `accelerate-log-ingestion`
  (`log-ingestion`).
- Affected code: `rust/zen-normalize`, `rust/flowgger`, `rust/log-collector`,
  `rust/otel`, `rust/trapd`, `rust/bmp-collector`, `rust/flow-collector`, new
  crates under `rust/`; `ServiceRadar.Observability.ZenRuleSync` and
  `Zen.RuleBundle`; `EventWriter.Processors.Logs`; edge leaf configuration and
  collector bundle generators; NATS users and permissions in the chart and
  Compose.
- Not affected: Falco ingestion (an external falcosidekick publishes it), the
  agent-relayed OTLP path, and core's internal logs.

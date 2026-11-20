## 1. Rules bucket and NATS reader

- [ ] 1.1 Core writes each rule bundle to a dedicated NATS key-value bucket, alongside the existing datasvc write. Bundle format and digest unchanged.
- [ ] 1.2 Add a NATS key-value implementation of the `Connector` and `Session` traits in `rust/log-collector/src/rules.rs`, with the same fetch-then-watch, timeout and backoff behaviour.
- [ ] 1.3 Grant the collector's NATS user read access to the rules bucket only, in the chart, Compose and the edge permission generators.
- [ ] 1.4 Switch the log collector to the NATS reader. Remove `[rules.datasvc]`, the datasvc client dependency and the collector's datasvc role.
- [ ] 1.5 Verify on the demo deployment: a rule edit reaches the collector through NATS; the collector keeps its ruleset across a NATS restart.

## 2. Edge

- [ ] 2.1 Prove on a real managed leaf that a key-value mirror of the rules bucket can be created in the leaf's domain with the permissions a managed leaf has, survives a disconnect and catches up. Record the result, and the fallback if it fails, in `design.md` before continuing.
- [ ] 2.2 Generate the mirror in the edge leaf configuration.
- [ ] 2.3 Add the rules subject to edge log-collector bundles.
- [ ] 2.4 Verify on an edge site: syslog is normalized at the edge, with the hub connection up and with it down.

## 3. Pass-through and core

- [ ] 3.1 The collector publishes binary batches with built-in mapping and no digest when it has no active ruleset. Remove the JSON fallback from the normalized pipeline.
- [ ] 3.2 Shared test cases cover a record stored with rules and without.
- [ ] 3.3 One release after 3.1 ships, EventWriter stops evaluating Zen for `logs.syslog`. JSON on that subject is stored with built-in mapping.
- [ ] 3.4 Core stops writing rule bundles to datasvc.

## 4. Shared crates

- [ ] 4.1 Move `follow()` and the NATS reader into the rules crate (from `rust/log-collector`, on top of `rust/zen-normalize`).
- [ ] 4.2 Extract the batch builder and NATS output from `rust/flowgger` into a publish crate. Flowgger uses it with no behaviour change.
- [ ] 4.3 Record a before-and-after measurement for syslog on the extracted crates.

## 5. OTLP logs

- [ ] 5.1 Apply the rules configured for `logs.otel` in the collector, for protobuf and JSON input. Record the cost on synthetic input.
- [ ] 5.2 EventWriter stops evaluating Zen for `logs.otel`.

## 6. SNMP traps

- [ ] 6.1 The trap daemon emits severity, `source_ip` and `attributes.snmp.*` itself. It does not store the community string.
- [ ] 6.2 Shared test cases hold the daemon's output to the row stored today, apart from the community string.
- [ ] 6.3 Remove the seeded trap rules; the rule editor stops offering the trap subject. Upgrade note for installs with a custom trap rule.
- [ ] 6.4 EventWriter stops evaluating Zen for `logs.snmp`.
- [ ] 6.5 Decide from measured trap volume whether traps move to binary batches. If so, use the publish crate.

## 7. BMP collector

- [ ] 7.1 Choose the binary message for BMP updates (existing schema or new protobuf) and record the choice in `design.md`.
- [ ] 7.2 Publish it through the publish crate; update the consumer; measure before and after.

## 8. Receive crate

- [ ] 8.1 Build the receive crate from the backends `add-zero-copy-log-receivers` specifies. Syslog adopts the portable backend first.
- [ ] 8.2 The flow collector adopts the receive crate.
- [ ] 8.3 Accelerated backends stay off by default; each is measured where it is enabled.

## 9. Verification

- [ ] 9.1 `openspec validate refactor-collectors-onto-shared-ingest-pipeline --strict` passes.
- [ ] 9.2 After 3.3, 5.2 and 6.4, the only subjects EventWriter evaluates Zen for are `logs.internal.*`.
- [ ] 9.3 Docs: collector configuration, edge onboarding and the rule editor pages describe the NATS rules bucket and the pass-through behaviour.

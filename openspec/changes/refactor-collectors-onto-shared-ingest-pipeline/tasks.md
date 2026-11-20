## 1. Rules bucket and NATS reader

- [x] 1.1 Core writes each rule bundle to a dedicated NATS key-value bucket, alongside the existing datasvc write, on rule changes and on reconcile. Per-rule keys, the subject index and the stored KV revision are unchanged. Bundle format and digest unchanged.
- [x] 1.2 Add a NATS key-value implementation of the `Connector` and `Session` traits in `rust/log-collector/src/rules.rs`, with the same fetch-then-watch, timeout and backoff behaviour.
- [ ] 1.3 Grant the collector's NATS user read access to the rules bucket only, in the chart, Compose and the edge permission generators.
- [ ] 1.3a Narrow the chart log-collector user from $JS.API.> to named grants for every stream and store the collector process uses (events, the rules bucket, and the RUM streams and object store), verified with the Rust client against a real broker.
- [ ] 1.4 Switch the log collector to the NATS reader.
- [ ] 1.5 One release after 1.4 ships, remove `[rules.datasvc]`, the collector's datasvc client dependency and its datasvc role.
- [ ] 1.6 Verify on the demo deployment: a rule edit reaches the collector through NATS; the collector keeps its ruleset across a NATS restart.

## 2. Edge

- [ ] 2.1 Verify on a real managed leaf that a client connected to the leaf can read and watch the rules bucket in the hub's JetStream domain with the permissions a managed leaf has, and that it keeps working after the leaf reconnects. Record the result in `design.md` before continuing.
- [ ] 2.2 Give the chart's hub NATS the JetStream domain the packaged configuration already uses, after confirming on a deployment that adding it leaves existing streams and consumers working.
- [ ] 2.3 Edge permission generators grant an edge collector read access to the rules bucket in the hub domain, and nothing else there.
- [ ] 2.4 Add the rules subject and the hub domain to edge log-collector bundles.
- [ ] 2.5 Verify on an edge site: syslog is normalized at the edge; a running collector keeps its ruleset while the hub connection is down; a collector started while it is down passes records through and picks up rules after reconnect.

## 3. Pass-through and core

- [ ] 3.1 The collector publishes binary batches on `logs.normalized.<kind>` with the schema header, built-in mapping and no `Sr-Ruleset-Id` when it has no active ruleset. EventWriter stores such a batch without rules, does not reject it, and records that no ruleset was applied. Remove the JSON fallback from the normalized pipeline.
- [ ] 3.2 Shared test cases cover a record stored with rules and without.
- [ ] 3.3 One release after 3.1 ships, EventWriter stops evaluating Zen for `logs.syslog`. JSON on that subject is stored with built-in mapping.
- [ ] 3.4a Before 3.4, confirm which consumers read rule bundles from datasvc. The survey behind this proposal found the log collector is the only one; verify that it still holds and that every such consumer has moved to the rules bucket.
- [ ] 3.4 Core stops writing rule bundles to datasvc once no consumer reads bundles from datasvc (3.4a), and not before one release after 1.4 ships. Per-rule keys and the subject index are a separate write and are unaffected.

## 4. Shared crates

- [ ] 4.1 Move `follow()` and the NATS reader into the rules crate (from `rust/log-collector`, on top of `rust/zen-normalize`).
- [ ] 4.2 Extract the batch builder and NATS output from `rust/flowgger` into a publish crate. Flowgger uses it with no behaviour change.
- [ ] 4.3 Record a before-and-after measurement for syslog on the extracted crates.

## 5. OTLP logs

- [ ] 5.1 Apply the rules configured for `logs.otel` in the collector, for protobuf and JSON input. Record the cost on synthetic input.
- [ ] 5.2 One release after 5.1 ships, EventWriter stops evaluating Zen for `logs.otel`.

## 6. SNMP traps

- [ ] 6.1 The trap daemon emits itself every field the seeded `snmp_severity` rule sets today: severity, derived `source_ip`, `source` and `service_name` set to `snmp`, the rule's `body` text (with its fallbacks), and `attributes.snmp.source`, `.version`, `.varbinds`, `.trap_oid` and `.detail`. It does not store `attributes.snmp.community`.
- [ ] 6.2 Shared test cases hold the daemon's output to the row stored today, apart from the community string.
- [ ] 6.3 The trap daemon publishes binary batches through the publish crate, as a collector without a ruleset does (3.1). It does not use the rules crate.
- [ ] 6.3a Grant the trap daemon's NATS user publish on `logs.normalized.snmp` in the chart, Compose and the edge permission generators, before 6.3 ships. Keep `logs.snmp` allowed until 6.5, so the previous trap daemon still publishes during the one-release window.
- [ ] 6.4 In the release that ships 6.3, the rule editor stops offering the trap subject. Upgrade note for installs with a custom trap rule.
- [ ] 6.5 One release after 6.3 ships, EventWriter stops evaluating Zen for `logs.snmp`. In the same release, remove the seeded trap rules (including `snmp_severity`) and stop seeding a passthrough rule and template for the trap subject; until then they stay, so the previous trap daemon's JSON is still stored as today.
- [ ] 6.6 Once 8.1 lands, the trap daemon adopts the receive crate, with the io_uring and AF_XDP backends available to it.
- [ ] 6.7 Record CPU and the number of traps lost during a synthetic trap storm, before and after 6.3 and 6.6.

## 7. BMP collector

- [ ] 7.1 Choose the binary message for BMP updates (existing schema or new protobuf) and record the choice in `design.md`.
- [ ] 7.2 Publish it through the publish crate; update the consumer; measure before and after.

## 8. Receive crate

- [ ] 8.1 Build the receive crate from the backends `add-zero-copy-log-receivers` specifies. Syslog adopts the portable backend first.
- [ ] 8.2 The flow collector adopts the receive crate. It keeps its protobuf output and does not adopt the rules or publish crates.
- [ ] 8.3 Accelerated backends stay off by default; each is measured where it is enabled.

## 9. Verification

- [ ] 9.1 `openspec validate refactor-collectors-onto-shared-ingest-pipeline --strict` passes.
- [ ] 9.2 After 3.3, 5.2 and 6.5, the only subjects EventWriter evaluates Zen for are `logs.internal.*`.
- [ ] 9.3 Docs: collector configuration, edge onboarding and the rule editor pages describe the NATS rules bucket and the pass-through behaviour.

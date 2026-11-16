# Change: Normalize and batch logs before durable publication

Status: approved for implementation by the product owner.

## Why

The pipeline repeats JSON serialization, performs Zen in consumers and awaits
one publish ACK per output worker. Source inspection identifies avoidable work;
its throughput impact needs measurement.

## What Changes

- Bound concurrent JetStream publication by count and bytes, preserving retry
  identity, duplicate-window deadlines and certificate policy.
- Replace per-record blocking-task dispatch with a persistent bounded handoff.
- Share one Rust normalization implementation between collector and NIF.
- Deliver versioned effective rules through datasvc and activate compiled
  snapshots outside the record path.
- Introduce bounded OTLP protobuf batches after consumer semantic parity.
- Preserve EventWriter redaction, attribution, promotion, catalog/live-log
  effects, replay and the selected StarRocks or CNPG backend.
- Profile Broadway against equivalent Rust consumers before replacing it.

## Impact

Changes span Flowgger, shared Rust normalization, rule distribution, the NIF
and EventWriter. Readers roll out before binary producers. JetStream remains
mandatory and CNPG log support remains available. Listener consolidation and
the publisher foundation do not require a wire change.

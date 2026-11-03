# Edge record dead-letter: inspect and replay

The agent gateway acknowledges an edge record to its agent once JetStream
stores it, so the agent no longer holds a copy. When EventWriter's projection
of a record keeps failing (any contract: sweep observations, metric batches,
unleased sweep results, and every contract added later), EventWriter moves
it to a dead-letter stream instead of retrying until the edge-record stream's
24-hour `MaxAge` evicts it.

This is not the security-quarantine route. Records signed by a revoked key
are covered by `docs/edge-record-quarantine-runbook.md`. The dead-letter only
holds records that are valid but could not be projected.

## How a record gets here

1. A delivery on `telemetry.edge-record.v1.bulk.pNN` (or the audit route
   `telemetry.edge-record-audit.v1.bulk.pNN`) fails. EventWriter NAKs it with
   a backoff of 10, 20, 40 and then 80 seconds.
2. The delivery that reaches the stream's `dead_letter_after_deliveries` (20
   by default, about 25 minutes of retries; `max_deliver - 1` if the consumer
   has a lower finite limit) fails too. EventWriter publishes a copy and waits
   for its PubAck:
   - subject `telemetry.edge-record-dlq.v1.bulk.pNN.<contract>.v<version>`,
     with the same `pNN` as the source and the contract id lower-cased, any run
     of characters outside `[a-z0-9_-]` replaced by `_`
     (`serviceradar_metrics_batch.v1`), or `unknown.v0` if the record does not
     decode;
   - stream `TELEMETRY_EDGE_RECORD_DLQ_V1_BULK` (R3, file, limits retention,
     `DiscardNew`, `MaxAge` disabled, 64 MiB; 32 MiB on `small` and 4 MiB on
     `tenant-2g`; override with
     `core.eventWriter.streams.telemetry_edge_record_dlq_v1_bulk`);
   - body: the record's exact original bytes;
   - headers: its original transport headers (`Sr-Edge-Delivery-Id`,
     `Sr-Edge-Transport-Provenance`, `Sr-Edge-Gateway-Id`) and the failure
     headers below.
3. Only after the PubAck does EventWriter ACK the source delivery. If the copy
   is not stored (the stream is full, missing or unreachable), the source is
   NAKed and retried, and the next delivery tries the copy again. Nothing is
   dropped while the source stream still holds the record.

| Header | Meaning |
| --- | --- |
| `Sr-Edge-Dlq-Source-Subject`, `-Source-Stream`, `-Source-Sequence` | where the record was delivered from |
| `Sr-Edge-Dlq-Source-Msg-Id` | the record's own `Nats-Msg-Id`; replay restores it |
| `Sr-Edge-Dlq-Stored-At` | when the source stream stored the record |
| `Sr-Edge-Dlq-Contract` | `<contract_id>/<version>` |
| `Sr-Edge-Dlq-Event-Id`, `-Agent-Id` | the record's event id and producing agent |
| `Sr-Edge-Dlq-Reason`, `-Reason-Detail` | the failure's class and its message (at most 256 bytes) |
| `Sr-Edge-Dlq-Attempts` | the delivery count when it was dead-lettered |
| `Sr-Edge-Dlq-First-Failed-At`, `-Last-Failed-At` | the first failure the dead-lettering node saw, and the last failure |

The copy's own `Nats-Msg-Id` is `edge-dlq:<source stream>:<source sequence>`.
The stream's duplicate window is 24 hours, the source stream's `MaxAge`, so a
delivery redelivered after a lost source ACK is stored once for as long as the
source can still redeliver it. EventWriter treats a duplicate PubAck as that
held copy only while the sequence is still in the stream. If the sequence was
removed (an operator removed the copy while the source ACK was lost), the
dead-letter counts as failed: it is logged, counted as `result="failed"`, and
the source is NAKed and stays on the edge-record stream rather than being
acknowledged without a copy.

## Alerts and metrics

- `serviceradar_event_writer_edge_record_dead_letter_count{contract, reason_class, result}`:
  `result="stored"` counts records moved to the dead-letter, and
  `result="failed"` counts copies that were not stored and left the source
  retrying.
- `ServiceRadarEdgeRecordDeadLettered` (warning): records were dead-lettered in
  the last 15 minutes, by contract and reason.
- `ServiceRadarEdgeRecordDeadLetterPublishFailed` (critical): a copy failed.
  The record stays on the edge-record stream, which evicts it after 24 hours.
  Check that the dead-letter stream exists and has room.
- `ServiceRadarEdgeRecordDeadLetterFull` (critical): the dead-letter stream is
  above 80% of `MaxBytes`. When full it refuses new copies.

For every record EventWriter logs one line naming both stream sequences:

```
Edge record dead-lettered: source_stream=TELEMETRY_EDGE_RECORD_V1_BULK source_sequence=<seq> source_subject=<subject> dlq_subject=<subject> contract=<id>/<version> event_id=<uuid> agent_id=<agent> attempts=<n> reason=<class> reason_detail=<message> dlq_stream=TELEMETRY_EDGE_RECORD_DLQ_V1_BULK dlq_sequence=<seq> dlq_duplicate=false
```

A failed copy logs `Edge record dead-letter publish failed; the source delivery
stays unacknowledged:` with the same fields and `publish_error=`.

## Inspect

From a NATS tools pod:

```
nats stream info TELEMETRY_EDGE_RECORD_DLQ_V1_BULK
nats stream view TELEMETRY_EDGE_RECORD_DLQ_V1_BULK --subject 'telemetry.edge-record-dlq.v1.bulk.*.serviceradar_metrics_batch.v1'
nats stream get TELEMETRY_EDGE_RECORD_DLQ_V1_BULK <dlq_sequence>
```

Or list what replay would read, with the failure headers parsed, from a core
node:

```
bin/serviceradar_core_elx rpc 'IO.inspect(ServiceRadar.EventWriter.EdgeRecordDeadLetter.Replay.list(limit: 20), limit: :infinity)'
```

`list/1` and `replay/1` take `subject:` (a filter on the dead-letter
subjects, for one contract as above), `from_sequence:` and `limit:` (default
100). A run reads only the messages the stream held when it started. Each
returns `next_sequence`; pass it back as `from_sequence` to page.

## Replay

Fix the cause first. `Sr-Edge-Dlq-Reason-Detail` and the EventWriter log
around `Last-Failed-At` usually name it. Then, from a core node:

```
bin/serviceradar_core_elx rpc 'IO.inspect(ServiceRadar.EventWriter.EdgeRecordDeadLetter.Replay.replay(limit: 20), limit: :infinity)'
```

For each message, replay republishes the original bytes and transport headers,
with a PubAck, to `Sr-Edge-Dlq-Source-Subject`. It fences the publish to the
source stream and restores the record's `Nats-Msg-Id`. Only after that
PubAck does it delete the dead-letter message. The EventWriter consumer then
projects the record as it does any delivery:

- a record whose earlier attempts never committed is projected now;
- a record the ledger already holds is a replay and writes nothing, so running
  replay twice, or replaying a message whose delete failed, changes nothing;
- a record that still fails retries and is dead-lettered again under a new
  dead-letter sequence. Nothing is lost. A replay run only reads the messages
  the stream held when it started, so it never picks up its own re-dead-letters.

Entry results:

- `:replayed`: republished and deleted;
- `:replayed_kept`: republished, but the delete failed (see `delete_error`);
- `{:error, :source_duplicate}`: the edge-record stream reported the record's
  `Nats-Msg-Id` as a duplicate within its duplicate window, so nothing new was
  stored. The message is kept; replay it again a few minutes later;
- `{:error, reason}`: not republished, and kept.

To drop a record you have investigated and will not replay:
`nats stream rmm TELEMETRY_EDGE_RECORD_DLQ_V1_BULK <dlq_sequence>`. The core
NATS identity cannot purge or delete the stream itself.

## Object references

A dead-lettered record can still be replayed, so any object it references out
of line (for example a staged artifact's object key) is still in use while the
record is in this stream. A projector must delete such an object only after its
ledger transaction commits, never on a failed attempt. Any retention pass that
deletes objects referenced by edge records must treat this stream as a reference
source. No contract in `ServiceRadar.Edge.ContractCatalog` carries an
out-of-line reference today, and no such pass exists yet. The change that adds
the first one must add that check.

## Not covered yet

The DLQ catalog, explicit resolved/redriven/waived states, an audited deleter,
redrive through a synthetic lane, the interactive class and a gateway-side poison
DLQ belong to `add-edge-record-stream-partitioning`.

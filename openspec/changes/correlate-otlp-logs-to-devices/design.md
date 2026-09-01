## Context

Two ingest paths land in `platform.logs`, and only one can be correlated to a device.

Syslog and traps arrive with a sender address. `normalize_source_ip/1` in
`event_writer/processors/logs.ex` pulls it from `source_ip`, `_remote_addr` or `source`, and
writes `logs.source_ip`. `device_inventory_identity_clause` then joins that column against
inventory, through three relations, to answer `in:logs device_id:"..."`.

OTLP arrives with attributes and no sender address. Nothing populates `source_ip`, and the
query deliberately does not read attributes -- the fixtures record why:

> `in:logs device_id:"..."` deliberately does NOT match on resource_attributes ... because
> an attribute ILIKE over last_24h logs times out.

Both facts are correct. Together they mean an OTLP producer cannot participate in device
correlation at all, however well it knows which device it is talking about.

Events do not have this problem. `rust/srql/src/query/events/filters.rs` matches an event to
a device on any of a documented key set in the payload, host keys and identity keys. That is
already the generic contract this change wants for logs.

## Goals / Non-Goals

- Goals
  - An OTLP producer can state which device its log concerns, and the device Logs tab finds
    it.
  - The read path is unchanged, so the query keeps its current plan and cost.
  - The contract matches the one events already publish.
- Non-Goals
  - Changing how syslog derives its source.
  - Attribute search at query time. That is the thing that did not work.
  - Any notion of *why* a producer touched a device. A log says which device; what the
    producer was doing is the producer's own vocabulary and stays in its payload.

## Decisions

### Decision: Resolve identity at ingest, not at query time
The processor already inspects each record to derive `source_ip`. Extending that derivation
to also consider a device attribute costs one more lookup per record, on a path that is
already parsing the record, and writes the same indexed column the query already uses.

Query time stays untouched. `device_inventory_identity_clause` does not learn a new branch,
`logs` gains no column, and the plan that works today keeps working.

- Alternatives considered:
  - **A new branch in the SRQL clause matching attributes.** This is the approach that was
    measured and rejected upstream. Nothing about it has got cheaper.
  - **A separate `log_device_links` table.** More faithful for a log about several devices,
    at the cost of a join the query does not currently do, for a case no producer has asked
    for. Worth revisiting if one does.

### Decision: Reuse the event key names exactly
`serviceradar.device_id`, `device_id`, `device_uid`, `uid` for identity;
`serviceradar.device_ip`, `host.name`, `hostname`, `host` for host. Same names, same
precedence.

A producer that instrumented for events is instrumented for logs. A reader who learned the
convention once has learned it. And the alternative -- a second, log-only spelling -- is the
kind of small inconsistency that becomes a support question forever.

`host.name` is also the OpenTelemetry semantic convention for the host a record concerns, so
a producer following the specification rather than our documentation lands in the right
place by accident. That is worth more than a name of our own choosing.

### Decision: An address resolves; an id is stored as given
A host key carrying an address goes into `source_ip` and correlates through the existing
inventory join. An identity key carrying a ServiceRadar device id has nothing to resolve --
it already *is* the answer the query is looking for.

Both are accepted, with identity preferred when both are present, because an id is exact and
an address can be reassigned.

### Decision: Silence rather than guessing
A record whose attribute is not a usable address and does not match a known device is stored
unattributed, exactly as it is today. No partial matching, no nearest host, no inference
from `service.name`. A log that appears under the wrong device is worse than one that
appears under none, because the first is believed.

## Risks / Trade-offs

- **A producer can attribute a log to a device it has nothing to do with.** True of events
  already, and of syslog, where anyone can forge a source address. → The contract is the
  same as the one events publish; this changes no trust boundary.
- **One more derivation on a hot ingest path.** → An attribute lookup on a record already
  being parsed, with no query-time cost. Worth measuring against a representative OTLP rate
  before merge.
- **Two producers could claim the same device.** That is correct and expected -- a switch
  can be described by its own syslog and by a tool that configured it.

## Open Questions

- Should a resource attribute count, or only a log record attribute? Resource attributes are
  per-batch, which suits a producer whose whole process concerns one device and not one
  whose logs span many. Proposed: accept both, with the record attribute winning.
- Should the derived identity be visible on the log row for debugging, or only used for
  correlation? Storing it is cheap and makes a mis-attribution diagnosable.

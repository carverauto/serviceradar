# serviceradar-bmp-collector

`serviceradar-bmp-collector` is the BMP publication stage for the routing intelligence pipeline:

`risotto decode -> bmp collector publish -> NATS JetStream (bmp.events.*)`

This crate currently focuses on the publication contract required by OpenSpec task `2.1`.
It accepts already-decoded BMP routing events as NDJSON (stdin or file), enforces the JetStream stream/subject contract, and publishes events to `bmp.events.<event_type>` subjects.

## Event shape

Each input line must be JSON matching `BmpRoutingEvent` in `src/model.rs`.

Example:

```json
{"event_id":"evt-1","event_type":"peer_down","timestamp":"2026-02-18T20:00:00Z","router_id":"router-a","peer_ip":"192.0.2.10","peer_asn":64513,"payload":{"raw_bmp_message_type":"PeerDown"}}
```

## Run

```bash
cargo run -p serviceradar-bmp-collector -- \
  --config rust/bmp-collector/bmp-collector.json \
  --input /path/to/bmp-events.ndjson
```

Or stream from stdin:

```bash
cat /path/to/bmp-events.ndjson | cargo run -p serviceradar-bmp-collector -- --config rust/bmp-collector/bmp-collector.json
```

## JetStream contract

- Stream: `BMP_CAUSAL` (configurable)
- Required subjects: includes `bmp.events.>`
- Publish subjects: `bmp.events.peer_up`, `bmp.events.peer_down`, `bmp.events.route_update`, `bmp.events.route_withdraw`, `bmp.events.stats`

This gives the Broadway/EventWriter consumer a stable ingestion boundary on `bmp.events.*`.

# Warehouse load retries

EventWriter's shared Stream Load client makes at most three attempts for a
transient connection failure, an unresolved load label, or HTTP 408, 429, 500,
502, 503, or 504. Backoff starts at 250 ms, doubles, and includes up to 20%
jitter. The call has a 90-second budget; a caller's shorter `http_timeout`
also bounds retries. Redirects and HTTP requests consume that same budget.

Transport retries start at the frontend again, retaining the original label,
encoded body, and load headers. An uncertain commit is polled through
`get_load_state`; only COMMITTED or VISIBLE permits acknowledgement. The client
does not resubmit a running load. StarRocks retains successful labels to prevent
duplicate loading, as described in its
[Stream Load protocol](https://docs.starrocks.io/docs/sql-reference/sql-statements/loading_unloading/STREAM_LOAD/).

After the budget or attempt limit is reached, the error returns to the processor
and Broadway fails the batch. EventWriter NAKs it for JetStream redelivery.
The final configured delivery emits the existing terminal-delivery log and
dead-letter telemetry before TERM. Neither retry exhaustion nor an unresolved
label is treated as a successful load.

For datasets still using CNPG followed by warehouse delivery, retries stay
inside the warehouse leg: a transient warehouse failure does not repeat the
completed CNPG insert. If retries exhaust and JetStream redelivers, the existing
idempotent CNPG writer runs again. Metrics use `(timestamp, gateway_id,
series_key)` with `on_conflict: :nothing`; warehouse primary keys also protect
replays regrouped into different batches. This is not a durable cross-delivery
completion ledger. Metrics backend cutover is separate work; this repair does
not change readers or backend selection.

Each failed attempt logs dataset, table, batch row count, label, attempt,
frontend/coordinator role, dialed host and port, underlying error, and whether
another attempt is planned. Partial-write errors retain the underlying
warehouse error alongside completed and missing destinations.

`event_writer_warehouse_load_failures` and, after a completed CNPG insert,
`event_writer_warehouse_partial_writes` are delta counters tagged by dataset.
They publish on `metrics.event_writer.warehouse` and require a JetStream
PubAck, with a bounded 500 ms wait. EventWriter persists the samples through
the normal metric pipeline. Their own load failures do not generate more
failure samples. Failed health publication is logged; local failure telemetry
and the Prometheus counter remain available while NATS is unavailable.

For recurring connection failures, inspect coordinator and frontend pod restart
reasons, memory usage against limits, compaction/load concurrency, and health
probe latency. A retry repair does not resolve memory exhaustion or overloaded
health endpoints. Investigate capacity before loosening probes or increasing
concurrent loads.

# Change: Correlate OTLP log records to devices via `serviceradar.device_id`

## Why

The OTLP collector (`rust/otel`) receives log export requests and publishes them
to NATS JetStream as raw protobuf chunks. Downstream consumers (Elixir core,
Go consumers) cannot efficiently attribute a log chunk to a device without
deserializing and scanning every record in the chunk.

Emitting clients stamp `serviceradar.device_id` as a log record attribute on
every record that belongs to a known device. The collector is the right place to
surface that identity at the NATS message envelope level — exactly as it already
does for authenticated sender identity via the `Sr-Ingest-Identity` header.
Adding a `Sr-Device-Id` header (one entry per unique device ID found in the
chunk) lets downstream consumers route, filter, or attribute log batches without
re-parsing the payload.

## What Changes

- **Add two constants to `output.rs`**: `SR_DEVICE_ID_HEADER` (`"Sr-Device-Id"`)
  and `DEVICE_ID_ATTRIBUTE` (`"serviceradar.device_id"`), parallel to
  `INGEST_IDENTITY_HEADER`.
- **Add `log_chunk_device_ids` helper in `nats/publish.rs`**: scans a log export
  chunk for unique `serviceradar.device_id` string values across all log record
  attributes; returns a deduplicated `Vec<String>`.
- **Refactor `NATSOutput::publish_chunk`**: change the `identity: Option<&str>`
  parameter to `headers: Option<async_nats::HeaderMap>`. This is a private
  method; all callers are in the same file.
- **Add `build_headers` helper**: takes identity and device ID slice, returns
  `Option<HeaderMap>` — `None` when both are absent so callers never publish a
  needless empty-header message.
- **Wire `publish_logs`**: per chunk, extract device IDs and pass combined
  headers (identity + device IDs) to `publish_chunk`. No change to the traces
  or metrics publish paths.
- **Tests**: unit tests for `log_chunk_device_ids` (extraction, deduplication,
  no-attribute baseline) and `build_headers` (combined output, identity-only,
  device-only, both-empty returns None).

## Non-changes

- No change to the chunker or NATS subject routing. Log records are not
  re-grouped by device; chunking remains size-driven.
- No change to the OTLP gRPC or HTTP protocol surface.
- No new NATS streams or subjects.
- Traces and metrics publish paths are untouched (pass identity-only headers).
- No personally identifiable information is introduced; `serviceradar.device_id`
  is an opaque UID (not a hostname, IP, or human-readable name).

## Impact

- **Affected code:** `rust/otel/src/output.rs`, `rust/otel/src/nats/publish.rs`
- **Affected specs:** `observability-signals` (MODIFIED)
- **Downstream consumers** that subscribe to the logs NATS subject can
  optionally read `Sr-Device-Id` header entries to attribute chunks without
  payload inspection; the header is additive and ignored by consumers that do
  not know it.

## 1. Constants

- [x] 1.1 Add `SR_DEVICE_ID_HEADER` and `DEVICE_ID_ATTRIBUTE` constants to `rust/otel/src/output.rs`.

## 2. Header building and device ID extraction

- [x] 2.1 Add `log_chunk_device_ids(chunk: &ExportLogsServiceRequest) -> Vec<String>` to `rust/otel/src/nats/publish.rs`: scans all log record attributes for `DEVICE_ID_ATTRIBUTE`, deduplicates, returns sorted-stable `Vec<String>`.
- [x] 2.2 Add `build_headers(identity: Option<&str>, device_ids: &[String]) -> Option<async_nats::HeaderMap>` in `rust/otel/src/nats/publish.rs`: stamps `Sr-Ingest-Identity` and/or one `Sr-Device-Id` entry per device ID; returns `None` when both inputs are absent.
- [x] 2.3 Refactor `NATSOutput::publish_chunk` to accept `headers: Option<async_nats::HeaderMap>` instead of `identity: Option<&str>`.

## 3. Wire device attribution into log publish

- [x] 3.1 In `NATSOutput::publish_logs`, call `log_chunk_device_ids` per chunk and pass `build_headers(ctx.identity.as_deref(), &ids)` to `publish_chunk`.
- [x] 3.2 Update `publish_traces`, `publish_raw_metrics`, and `publish_derived_metrics` callers to use `build_headers(ctx.identity.as_deref(), &[])` with the refactored signature.

## 4. Tests

- [x] 4.1 Unit test: `log_chunk_device_ids` extracts a device ID from a log record attribute.
- [x] 4.2 Unit test: `log_chunk_device_ids` deduplicates across multiple records with the same ID.
- [x] 4.3 Unit test: `log_chunk_device_ids` returns empty for a chunk with no `serviceradar.device_id` attribute.
- [x] 4.4 Unit test: `build_headers` stamps both `Sr-Ingest-Identity` and `Sr-Device-Id` when both are present.
- [x] 4.5 Unit test: `build_headers` returns `None` when both identity and device IDs are absent.

## 5. Validate

- [ ] 5.1 Run `openspec validate correlate-otlp-logs-to-devices --strict` and fix any issues.

# Change: Improve syslog ingestion fidelity and source provenance

## Why

The Flowgger-based syslog collector is currently deployed with `rfc3164` as a
single hard-coded input format. This rejects valid RFC5424 messages and vendor
messages emitted by ClearPass in its standard format. A rejected message is
not useful to an operator even when the payload is otherwise valid, and the
current behavior produces repeated parser errors for the same device.

Flowgger already captures the UDP peer address and emits it as `_remote_addr`,
but the EventWriter path does not copy that field into the persisted log
record. As a result, the source address is absent from the log detail UI even
when the collector received it. The source address can also be replaced by an
upstream load balancer, so the product needs to preserve and display the value
that was actually observed and document the cluster networking dependency.

## What Changes

- Add an `auto` syslog input mode that attempts RFC5424, RFC3164, and the
  ClearPass standard variant in a deterministic order.
- Make the parser accept normal RFC3164 and RFC5424 messages, including valid
  structured data, nil structured data, timezone offsets, and multiline or
  escaped payloads.
- Parse the ClearPass header form that uses an ISO-like timestamp with comma
  milliseconds and has no timestamp timezone in the header.
- Preserve an unrecognized syslog message as a log with its raw body and
  receive timestamp instead of dropping it. Mark the record and emit bounded
  parser diagnostics so operators can identify formats that need a dedicated
  decoder later.
- Keep explicit `rfc3164` and `rfc5424` modes for deployments that require
  strict parsing. Configure the ServiceRadar Helm collector and generated edge
  bundles to use `auto` by default.
- Normalize Flowgger's partition-qualified `_remote_addr` into a first-class
  `source_ip` field in the log storage and query/API contract while retaining
  the raw compatibility attribute.
- Display the source IP in log list/detail views and preserve it through the
  NATS, EventWriter, database, API, and SRQL paths.
- Add parser, ingestion, schema, UI, Helm, and end-to-end validation tests.
- Update operational documentation with supported formats, ClearPass output
  guidance, source-IP limitations, and verification steps.

CEF and LEEF are intentionally not semantic parsing targets in this change.
They will be accepted by the lossless fallback as opaque message bodies so
they are not discarded, but their fields will not be extracted into a CEF or
LEEF schema yet.

## Impact

- Affected spec: `observability-signals`.
- Affected components: `rust/flowgger`, the log collector Helm template,
  generated collector bundles, EventWriter, the platform logs schema/API,
  observability UI, and syslog documentation.
- The database change is additive: existing log records and `_remote_addr`
  attributes remain readable, while records without a usable source address
  continue to have a null `source_ip`.
- No new direct database write path is introduced. Logs continue to flow
  through NATS and EventWriter before persistence.
- The change does not alter SNMP trap authentication or add CEF/LEEF field
  extraction.

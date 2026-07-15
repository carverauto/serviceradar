# Implementation Tasks

Tasks are checked as implementation and validation work is completed.

## Contract and storage

- [x] Confirm the `observability-signals` contract for auto-detected formats,
  lossless fallback, and collector-observed source IP.
- [x] Add an additive nullable `source_ip` column and migration to
  `platform.logs`.
- [x] Update the log resource, API serialization, and SRQL/query projection
  for `source_ip`.
- [x] Preserve `_remote_addr` and any partition metadata for compatibility.

## Flowgger parsing

- [x] Add the `auto` input format and deterministic RFC5424/RFC3164/ClearPass
  decoder selection.
- [x] Harden RFC5424 parsing for structured-data escaping, multiple elements,
  nil structured data, timezone offsets, and full payload preservation.
- [x] Add a ClearPass standard decoder for the observed comma-millisecond
  header and escaped/multiline body variants.
- [x] Add lossless raw fallback records with detected-format and sampled parse
  diagnostics.
- [x] Add Rust unit fixtures for valid RFC3164, valid RFC5424, ClearPass
  standard detail/alert messages, opaque CEF/LEEF bodies, malformed headers,
  and IPv4/IPv6 peer metadata.

## Configuration and deployment

- [x] Change the Helm log collector default input format to `auto` while
  preserving explicit format overrides.
- [x] Change generated edge collector bundle defaults to `auto` and retain
  timezone configuration for ClearPass header timestamps.
- [x] Add Helm/template tests that assert the rendered default is `auto`.

## EventWriter and UI

- [x] Normalize qualified and unqualified `_remote_addr` values safely,
  including IPv6, into `source_ip` and ingest partition metadata.
- [x] Add EventWriter tests proving source IP survives malformed/unknown
  format fallback and does not break records with absent or invalid address
  metadata.
- [x] Display `source_ip` as Source IP in log detail and add query/API coverage.
- [x] Add list/filter coverage if the existing log query contract supports it
  without a separate pagination redesign.

## Documentation and verification

- [x] Document supported syslog formats, ClearPass configuration guidance,
  opaque CEF/LEEF handling, and source-IP semantics.
- [x] Document Kubernetes load-balancer source-IP preservation requirements,
  including the distinction between the collector peer and the original
  sender.
- [ ] Run focused Rust, Elixir, schema, API, UI, and Helm tests.
- [ ] Run a namespace-level end-to-end test with RFC3164, RFC5424, ClearPass,
  and opaque messages, verifying NATS, CNPG, and the UI.

The focused Rust, SRQL, EventWriter, and Helm checks pass. Full web/UI and
database-backed checks require a reachable PostgreSQL/CNPG test database, and
the namespace-level end-to-end check requires the deployed Kubernetes
environment.

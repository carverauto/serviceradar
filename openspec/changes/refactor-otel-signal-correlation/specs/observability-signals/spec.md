## ADDED Requirements

### Requirement: Canonical telemetry identifier contract

The system SHALL store and exchange OpenTelemetry identifiers in one canonical
textual form across all signals and layers: `trace_id` as 32-character
lowercase hexadecimal, `span_id` and `parent_span_id` as 16-character lowercase
hexadecimal, and an absent parent (root span) as SQL NULL. Writers SHALL
normalize protobuf byte IDs, JSON hex strings (any case), and JSON base64
strings to this form before persistence, and SHALL reject or quarantine records
whose identifiers cannot be normalized. Query layers SHALL case-fold hex input
before comparison.

#### Scenario: Protobuf log record IDs normalized once

- **WHEN** an OTLP `LogRecord` arrives with 16-byte `trace_id` and 8-byte
  `span_id` bytes fields
- **THEN** the stored `logs.trace_id` SHALL be the 32-char lowercase hex of
  those bytes and `logs.span_id` the 16-char lowercase hex
- **AND** the stored values SHALL equal the `otel_traces.trace_id`/`span_id`
  values for the same span

#### Scenario: Producer emitting ASCII-hex bytes is corrected

- **GIVEN** a producer that incorrectly places ASCII hex text in the OTLP
  `trace_id` bytes field
- **WHEN** the record is ingested
- **THEN** the writer SHALL detect the 32-byte ASCII-hex payload and normalize
  it to the canonical 32-char form rather than hex-encoding it a second time

#### Scenario: Root span parent representation

- **WHEN** a span arrives whose OTLP `parent_span_id` is empty or all-zero
  bytes
- **THEN** the stored `parent_span_id` SHALL be NULL
- **AND** rollup root-span detection SHALL match exactly `parent_span_id IS NULL`

### Requirement: Trace detail view with span waterfall

The web UI SHALL provide a trace detail view at a dedicated route keyed by
`trace_id` that renders the trace's spans as a parent/child waterfall ordered
by start time, including per-span service, operation, duration, kind, and
status, with error spans visually distinguished. The view SHALL render within
the observability shell and SHALL be reachable by clicking a trace row in the
traces pane.

#### Scenario: Trace row click opens trace detail

- **GIVEN** the traces pane lists a trace summary
- **WHEN** the user clicks the trace row
- **THEN** the UI SHALL navigate to the trace detail route for that `trace_id`
- **AND** SHALL NOT navigate to the logs pane

#### Scenario: Waterfall renders span hierarchy

- **GIVEN** a trace with a root span and child spans across multiple services
- **WHEN** the trace detail view loads
- **THEN** spans SHALL be displayed as a tree/waterfall using
  `parent_span_id`, with relative timing bars derived from span start/end times

#### Scenario: Missing spans are explained

- **GIVEN** a trace summary whose raw spans have been dropped by retention
- **WHEN** the trace detail view loads
- **THEN** the UI SHALL state that span data is no longer retained rather than
  rendering an empty page

### Requirement: Bidirectional trace, log, and metric correlation

The system SHALL support pivoting between correlated signals in both
directions: trace detail SHALL offer the trace's correlated logs (trace-scoped
and span-scoped); log detail SHALL link to its trace when `trace_id` is
present; span performance samples SHALL link to their trace and logs.
Correlation queries SHALL derive their time window from the source signal's
own timestamps (with padding), not a fixed relative window.

#### Scenario: Trace detail shows correlated logs

- **GIVEN** a trace whose spans emitted logs carrying the trace's `trace_id`
- **WHEN** the user opens the trace detail's logs panel
- **THEN** the logs SHALL be returned by a `trace_id` equality match and listed
  with severity and message

#### Scenario: Log detail links back to trace

- **GIVEN** a log record with a non-null `trace_id`
- **WHEN** the user views the log detail
- **THEN** the `trace_id` SHALL render as a link to the trace detail view

#### Scenario: Correlation window derives from the trace

- **GIVEN** a trace that started 4 days ago
- **WHEN** the user pivots from the trace to correlated logs
- **THEN** the generated query SHALL bound time around the trace's start/end
  timestamps rather than a hardcoded `last_24h`

### Requirement: Observability stat cards reflect stored rollups

Stat cards on the logs, traces, and metrics panes SHALL be computed from the
pre-computed rollups (continuous aggregates or maintained summary tables) via
the query layer, SHALL NOT be gated on runtime process-name checks, SHALL
display non-zero values whenever the backing rollup holds matching rows, and
SHALL be clickable, applying the corresponding filter to the pane's list. When
a backing rollup is missing or stale beyond its refresh interval, the pane
SHALL show an explicit staleness warning instead of silent zeros.

#### Scenario: Metrics cards show rollup values

- **GIVEN** `otel_metrics_hourly_stats` contains rows in the selected window
- **WHEN** the metrics pane renders
- **THEN** total/slow/error counts and duration percentiles SHALL reflect the
  rollup sums, not zero

#### Scenario: Card click filters the list

- **WHEN** the user clicks the "Errors" card on the traces pane
- **THEN** the traces list SHALL re-query filtered to error traces
  (`error_count > 0` / `status_code = 2`)

#### Scenario: Stale rollup is surfaced

- **GIVEN** the trace summary maintenance job has not run for longer than its
  scheduled interval plus grace
- **WHEN** the traces pane renders
- **THEN** a warning SHALL identify the stale/missing rollup asset

### Requirement: Trace context propagation across services

ServiceRadar's own services SHALL propagate W3C trace context across process
boundaries — gRPC and HTTP calls between Elixir, Go, and Rust services, and
async hops over NATS via message headers — so that cross-service operations
produce multi-span traces with correct parent/child relationships. The
pipeline SHALL expose a root-span ratio measure so operators can detect
propagation regressions.

#### Scenario: Cross-service call yields one trace

- **GIVEN** web-ng handles a request that calls core-elx which queries CNPG
- **WHEN** the spans are ingested
- **THEN** all spans SHALL share one `trace_id` with child spans referencing
  their parent `span_id`

#### Scenario: Propagation regression is detectable

- **WHEN** the share of root spans among ingested spans exceeds a configured
  threshold over a sustained window
- **THEN** the system SHALL emit an operator-visible health signal

### Requirement: Span samples and OTLP metrics are distinct

The system SHALL distinguish span-derived performance samples from OTLP metric
points. Span-derived RED aggregates (rate/error/duration) SHALL be computed
over ALL spans, not only slow outliers, so percentiles and error rates are
unbiased. OTLP sum/gauge/histogram points SHALL be stored with their metric
identity (name, type, unit, attributes) and rendered rate-aware (counters as
deltas/rates, not raw cumulative values). The UI SHALL label span samples and
metric points distinctly.

#### Scenario: Unbiased span aggregates

- **GIVEN** 1000 spans of which 10 exceed the slow threshold
- **WHEN** hourly RED aggregates are computed
- **THEN** totals and percentiles SHALL be computed over all 1000 spans

#### Scenario: Counter rendered as rate

- **GIVEN** a cumulative OTLP sum metric
- **WHEN** it is charted or listed in the metrics pane
- **THEN** the displayed value SHALL be a rate or delta over the selected
  window, not the raw cumulative total

### Requirement: Telemetry pipeline delivery accounting

The telemetry ingestion pipeline SHALL NOT silently drop signals: the OTLP
collector SHALL fail or retry exports it cannot durably hand off to the
message bus; consumers SHALL count records received, written, and rejected per
signal; and these counters SHALL be queryable so received-vs-written deltas
are observable per deployment.

#### Scenario: Failed publish is not acknowledged as success

- **GIVEN** the message bus is unavailable
- **WHEN** an OTLP export arrives at the collector
- **THEN** the collector SHALL either buffer-and-retry within bounded limits or
  return a non-success OTLP response, and SHALL NOT acknowledge while dropping

#### Scenario: Loss is measurable

- **WHEN** an operator compares collector-received versus database-written span
  counts for a window
- **THEN** the pipeline counters SHALL make any loss visible per signal

### Requirement: External producer data fidelity

The pipeline SHALL preserve external OTLP producers' data with full
fidelity: attribute maps (span, resource, scope, log, event) SHALL be stored
as structured JSON preserving every OTLP AnyValue type — including zero,
false, and empty-string values, nested kvlists, arrays, and bytes — never as
flattened delimiter-joined text; structured (kvlist/array) log bodies SHALL
be stored as JSON rather than discarded; log records carrying only
`severity_number` SHALL be classified into the standard severity buckets;
and all writers targeting the same table SHALL produce an identical encoding
for identical input.

#### Scenario: Attribute values with reserved characters survive

- **WHEN** a span arrives with `http.url = "https://x/p?a=1&b=2,c=3"` and
  `retry = 0` and `cache.hit = false`
- **THEN** all three attributes SHALL be stored and rendered with their
  exact values and types

#### Scenario: Structured log body preserved

- **WHEN** a log record arrives whose body is a kvlist
- **THEN** the stored body SHALL be its JSON representation and the logs
  pane SHALL display it

#### Scenario: severity_number-only log is classified

- **GIVEN** a log record with `severity_number: 17` and empty severity text
- **THEN** it SHALL be counted in the error severity bucket and filterable
  as an error

#### Scenario: Writer parity

- **WHEN** the same OTLP span is ingested via the Go writer and the Elixir
  writer
- **THEN** the stored rows SHALL be equivalent field-for-field, including
  attribute/event/link encodings

### Requirement: External metrics are queryable

OTLP metric points from external producers SHALL be queryable through the
standard query layer and visible in the UI with their metric identity:
listable/filterable by metric name, type, service, and time window;
cumulative monotonic sums rendered temporality-aware (rate/delta, not raw
running totals); exponential-histogram and summary points SHALL at minimum
be counted and surfaced (not silently dropped), with full decoding as a
stated follow-up if not immediate.

#### Scenario: External counter visible end-to-end

- **WHEN** an external app exports a cumulative sum metric
- **THEN** a query by its metric name SHALL return its points
- **AND** the UI SHALL render it as a rate or delta over the selected window

#### Scenario: Unsupported point types are not silent

- **WHEN** an exponential histogram point arrives
- **THEN** it SHALL be counted in pipeline accounting and SHALL NOT vanish
  without trace

## MODIFIED Requirements

### Requirement: OTEL log schema visibility in the UI

The web UI SHALL expose OTEL log fields (severity, body, service, scope,
attributes, resource attributes, and trace/span identifiers) in the logs pane
and log detail view. Trace and span identifiers SHALL be stored in the
canonical lowercase-hex form, SHALL be filterable in the logs pane via
`trace_id`/`span_id` query fields that survive query-builder round-trips, and
SHALL render as navigation links to the trace detail view when the referenced
trace exists.

#### Scenario: OTEL log fields visible

- **WHEN** a user opens a log record's detail
- **THEN** severity, body, service, scope, attributes, resource attributes,
  and trace/span identifiers SHALL be displayed

#### Scenario: Trace id filter round-trips

- **GIVEN** a logs query containing `trace_id:"<32-hex>"`
- **WHEN** the user edits and resubmits the query through the builder
- **THEN** the `trace_id` filter SHALL be preserved, not stripped

#### Scenario: Log trace id links to trace detail

- **GIVEN** a log whose `trace_id` matches an existing trace summary
- **WHEN** the log detail renders
- **THEN** the trace id SHALL link to the trace detail view

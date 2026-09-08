# Design: Improve syslog ingestion fidelity and source provenance

## Context

Flowgger receives syslog over UDP and currently selects one decoder from the
configured `input.format`. ServiceRadar's chart and generated collector
bundles select `rfc3164`, even though deployed senders may emit RFC5424 or
vendor-specific standard messages. ClearPass traffic observed in the cluster
has both of these shapes:

- RFC5424 with a version, RFC3339 timestamp, hostname, app name, process ID,
  message ID, and structured data.
- A ClearPass standard header with `YYYY-MM-DD HH:MM:SS,mmm`, the ClearPass
  node address, application name, numeric identifiers, and a free-form body.

The UDP input receives the peer IP, and the NATS GELF encoder emits it as
`_remote_addr`. NATS adds the partition as a prefix, for example
`default:192.0.2.34`. EventWriter currently copies only the JSON `attributes`
object into the persisted log attributes, so `_remote_addr` is not promoted
to the log's public source metadata or shown as a source IP in the UI.

## Goals

- Accept the common RFC3164 and RFC5424 forms without requiring a sender-wide
  format switch.
- Accept the observed ClearPass standard header and preserve its full body.
- Never discard a received message solely because its format is unknown.
- Preserve the observed source IP as a queryable, UI-visible field.
- Keep the existing NATS-first log pipeline and explicit decoder modes.
- Make parser behavior deterministic, testable, and diagnosable.

## Non-goals

- Semantic CEF or LEEF parsing.
- Replacing Flowgger or changing the NATS/EventWriter architecture.
- Recovering the original sender IP when an upstream Tanzu/vSphere load
  balancer has already SNATed the packet. The value displayed by ServiceRadar
  is the peer address observed by the collector.
- Adding source ports or a general network provenance model in this change.

## Decisions

### 1. Use an explicit `auto` decoder mode

The input configuration will support `format = "auto"`. Auto mode will use
cheap framing checks followed by decoders in this order:

1. RFC5424 when the PRI is followed by version `1` and an RFC3339 timestamp.
2. RFC3164 standard and existing custom forms.
3. The ClearPass standard header with comma millisecond precision.
4. A lossless raw fallback.

Each successful decoder returns a normal log record and a detected-format
marker. Explicit `rfc3164` and `rfc5424` modes continue to reject malformed
input according to their existing strict contract; only `auto` enables the
fallback behavior. This retains a useful strict mode while making the default
collector resilient.

The parser should avoid classifying a message solely from a prefix that can
also occur in a body. It should validate the complete header fields needed by
the selected decoder and then preserve the remainder exactly. RFC5424
structured data must handle escaped quotes, backslashes, closing brackets,
multiple elements, and `-` nil structured data.

### 2. Treat ClearPass standard messages as a supported vendor variant

The ClearPass decoder will accept the observed timestamp form with comma
milliseconds and parse the node address as the message hostname/source hint
when present. Because the header has no timezone, the configured collector
timezone is used only for the header timestamp. A timestamp embedded in the
payload remains part of the body unless a later vendor-specific enrichment is
added.

Multiline and escaped newline content will be retained in the body. The
decoder will not split one datagram into multiple records.

### 3. Make fallback lossless and bounded

If auto mode cannot parse a message, it will create a normal log record with:

- the collector receive timestamp;
- the complete original message as the body/raw message;
- the observed source IP, when available; and
- metadata identifying `syslog.format = "unknown"` and a parse-fallback
  indicator.

The collector will increment a bounded diagnostic counter and log a sampled
warning rather than emitting one unbounded error per message. This allows CEF,
LEEF, and future vendor formats to remain searchable without pretending that
their fields were parsed.

### 4. Promote source provenance at the EventWriter boundary

The existing `_remote_addr` field remains in the raw compatibility metadata.
EventWriter will recognize a partition-qualified value, separate the known
partition prefix from the address, validate the address as IPv4 or IPv6, and
write the address to the additive `source_ip` log field. The partition will be
retained as ingest metadata when it is present. Invalid or unavailable values
will not fail log ingestion.

The normalization must handle unqualified addresses too, because non-NATS or
older producers may not include a partition prefix. It must not split an IPv6
address on its colons or treat arbitrary message text as an address.

### 5. Expose source IP through the existing log contract

The `platform.logs` schema, Ecto/Ash resource, API/SRQL projection, and UI
will gain an optional `source_ip` field. The detail view will display it as
"Source IP" independently of the message body and raw attributes. The list
view may add a source-IP column or filter where the current query contract
supports it; at minimum, detail view visibility and queryability are required.

The migration is additive and backfill-free. Historical records keep null
`source_ip` unless a later backfill is explicitly designed from retained raw
attributes.

### 6. Configure resilient defaults without removing strict overrides

The chart's log collector configuration and the web-ng collector bundle
generator will default to `auto`. Existing configuration values that
explicitly request `rfc3164`, `rfc5424`, `gelf`, or another supported Flowgger
mode remain honored. Rendered chart and bundle tests will make the default
visible so a future template change cannot silently restore the hard-coded
RFC3164 behavior.

## Risks and trade-offs

- Auto detection can classify an unusual vendor message differently from a
  human expectation. Complete header validation, detected-format metadata,
  fixtures, and the raw body reduce this risk.
- Lossless fallback increases stored data for malformed or unsupported input.
  This is preferable to silent loss and can be bounded operationally with the
  existing log retention policy.
- A source IP observed after a load balancer is not necessarily the original
  sender. The UI and docs must label it as the collector-observed source, and
  the Kubernetes ingress runbook must cover `externalTrafficPolicy` and the
  Tanzu load-balancer preservation requirement.
- Adding a nullable database field requires coordinated schema, API, and UI
  changes. The field is additive to keep rollout compatible.

## Migration and rollout plan

1. Add parser contracts and fixtures behind unit tests.
2. Add the nullable `source_ip` schema/API field and EventWriter mapping.
3. Add UI rendering and query coverage.
4. Change chart and bundle defaults to `auto` and render-test them.
5. Deploy to a non-production namespace and send RFC3164, RFC5424, ClearPass,
   and an opaque CEF/LEEF fixture. Verify NATS, persisted logs, and UI detail.
6. Confirm the displayed address matches the collector-observed peer. If it is
   a load-balancer VIP, use the Tanzu ingress runbook to request source-IP
   preservation; do not claim the application can recover a SNATed address.

## Open questions

- Should the eventual list view show source IP as a column, or should the
  first release expose it only in detail and SRQL/API results? The contract
  must support both without another migration.
- Should the raw fallback marker be a dedicated database field or remain in
  log attributes? The implementation should choose the least disruptive
  option while keeping it queryable and visible during troubleshooting.

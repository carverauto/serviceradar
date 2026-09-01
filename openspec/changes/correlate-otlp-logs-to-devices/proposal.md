# Change: Let an OTLP producer say which device a log is about

## Why
A device's Logs tab answers "what happened to this thing". It answers it only for producers
that look like syslog.

`in:logs device_id:"..."` correlates through `platform.ocsf_devices`,
`platform.device_identifiers` and `platform.discovered_interfaces`, and every branch joins
on one column:

```sql
logs.source_ip IS NOT NULL AND logs.source_ip = d.ip
```

`source_ip` is derived at ingest by `normalize_source_ip/1`, which reads `source_ip`,
`_remote_addr` or `source` -- syslog and trap shapes. An OTLP producer has no way to set it,
and attributes are deliberately not consulted because an ILIKE over a day of logs times out.

So a service that acts on a device -- a configuration tool, an orchestrator, a scanner --
can send ServiceRadar a perfectly good log about that device and have it be invisible from
the device. Events already solve this: `EVENT_DEVICE_IDENTITY_KEYS` and
`EVENT_DEVICE_HOST_KEYS` let any producer name the device in the payload. Logs have no
equivalent.

## What Changes
- Accept a device identity from an OTLP log record's attributes, using the **same key names
  events already accept**, so a producer instrumented for one is instrumented for both.
- Resolve that identity **at ingest** into the indexed column the query already joins on,
  rather than searching attributes at query time. This is what makes it affordable: the
  read path does not change, and `in:logs device_id:"..."` keeps its current plan.
- Leave every existing producer untouched. A log with no device attribute behaves exactly
  as it does today, and syslog's derivation is unchanged.
- Document the attribute contract in the OTEL ingest guide, beside the endpoints and
  quickstarts, as something any producer can adopt.

## Impact
- Affected specs: `observability-signals`
- Affected code: the OTLP log path into `logs.*` subjects, the Elixir log processor's
  identity derivation, and `docs/docs/otel.md`
- No schema change: `logs.source_ip` already exists and is already indexed for this join
- No change to SRQL, the device Logs tab, or any existing producer

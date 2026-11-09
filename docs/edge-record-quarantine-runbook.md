# Edge record audit and security-quarantine routes

The agent gateway decides one of three publications for each authorized edge
record. Each has its own JetStream stream, so a non-authoritative record can
never reach the stream an authoritative projector reads.

| Publication | Subject | Stream | Wire disposition | What reads it |
| --- | --- | --- | --- | --- |
| primary | `telemetry.edge-record.v1.bulk.pNN` | `TELEMETRY_EDGE_RECORD_V1_BULK` | `ACCEPTED_AUTHORITATIVE` | EventWriter `EDGE_RECORD`: ledger and domain rows |
| audit | `telemetry.edge-record-audit.v1.bulk.pNN` | `TELEMETRY_EDGE_RECORD_AUDIT_V1_BULK` | `ACCEPTED_AUDIT_ONLY` | EventWriter `EDGE_RECORD_AUDIT`: ledger row only |
| security quarantine | `telemetry.edge-record-security-quarantine.v1.bulk.pNN` | `TELEMETRY_EDGE_RECORD_SECURITY_QUARANTINE_V1_BULK` | `ACCEPTED_QUARANTINE` | EventWriter `EDGE_RECORD_SECURITY_QUARANTINE`: a log line and a counter, nothing written |

- **Audit** is a valid historical record delivered under its delivery grant
  after its producer assignment's epoch moved on (a stale fence). An exact
  registered rollover may also drain to audit when the original assignment
  has been deleted and no current fence remains. Ordinary renewal cannot grant
  that exception; original mapping evidence and retained valid signing keys are
  still required. The gateway
  stamps it `LATE_FENCED_DELIVERY`; EventWriter records its ledger row and
  delivery slot and writes no domain rows. EventWriter refuses a record on the
  audit subject that is not stamped late-fenced.
- **Security quarantine** is a record signed by a production or source key the
  trust snapshot marks compromise-revoked (`historically_revoked`). It needs no
  delivery grant. It is a dead-letter stream: `MaxAge` is disabled and
  `DiscardNew` refuses a publish once the stream is full, so a quarantined
  record is never aged or evicted out. A refused publish leaves the agent's
  sequence unresolved, and the agent keeps the bytes.

All three streams are R3 (capped to `nats.replicas`) and sized by the JetStream
profile (`helm/serviceradar/files/jetstream-profiles.yaml`; override with
`core.eventWriter.streams.telemetry_edge_record_audit_v1_bulk` and
`core.eventWriter.streams.telemetry_edge_record_security_quarantine_v1_bulk`).
Only the BULK class is provisioned, like the primary route.

## Seeing quarantined records

`ServiceRadarEdgeRecordSecurityQuarantine` fires when the security-quarantine
stream holds any bytes, and `ServiceRadarEdgeRecordSecurityQuarantineFull` when
it passes 80% of `MaxBytes`. The gateway also counts non-authoritative
publications in
`serviceradar_agent_gateway_edge_record_non_authoritative_publication_count{publication}`.

For each quarantined record EventWriter logs one line:

```
Edge record held in security quarantine: stream=TELEMETRY_EDGE_RECORD_SECURITY_QUARANTINE_V1_BULK stream_sequence=<seq> subject=<subject> authenticated_agent_id=<agent> contract_id=<id> contract_version=<version> event_id=<hex> gateway_id=<id> network_scope_id=<hex> production_issuer_key_id=<hex> record_sha256=<hex> sequence=<seq> spool_id=<hex>
```

The fields after `subject` are alphabetical. `contract_id` is the only free-text
field taken from the record. Every string field is escaped (`\n`, `\r`, `\t`, or
`\uXXXX`), so one record is always one line.

`stream_sequence` is the JetStream sequence of the message. Fetch it, with
its transport headers, from a NATS tools pod:

```
nats stream info TELEMETRY_EDGE_RECORD_SECURITY_QUARANTINE_V1_BULK
nats stream get TELEMETRY_EDGE_RECORD_SECURITY_QUARANTINE_V1_BULK <stream_sequence>
nats stream view TELEMETRY_EDGE_RECORD_SECURITY_QUARANTINE_V1_BULK
```

The message body is the exact `EdgeRecordV1` bytes the agent sent.
`Sr-Edge-Transport-Provenance` names the agent, network scope, spool and
sequence. `production_issuer_key_id` in the log line is the key whose
revocation quarantined it.

Acknowledging the EventWriter consumer does not remove a message. Delete one
only after the record has been investigated, with
`nats stream rmm TELEMETRY_EDGE_RECORD_SECURITY_QUARANTINE_V1_BULK <seq>`.
The full DLQ catalog, retention policy and redrive are a later change.

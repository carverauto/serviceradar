# Managed collector gRPC certificate policy

Managed inbound gRPC listeners use the same authenticated, root-owned policy
file installed by the host agent. Configure the following optional field to
adopt managed peer enforcement:

| Listener | Policy file field |
| --- | --- |
| Trap collector | `grpc_security.cert_policy_file` |
| RPerf checker | `security.tls.cert_policy_file` |
| OTEL and log collector | `grpc_tls.cert_policy_file` |

For example, the installed policy path may be
`/etc/serviceradar/managed-components/policy.json`. The file and all parent
directories must be root-owned and not group/world writable. A configured
missing, malformed, or stale initial policy prevents the managed listener from
starting. Omitting the field preserves the existing listener configuration.

Managed listeners require client certificates, normal CA verification and a
fresh allowlist entry for the peer's full-DER SHA256 fingerprint. OTEL's
`grpc_tls.client_auth` must be `required` and `ca_file` must be configured;
`none` and `optional` remain available only for unmanaged external OTLP ingest.
Ingestion-token authentication and request-size limits continue to apply.

The shared incoming transport reloads policy every 250 milliseconds, disables
TLS session resumption, and rejects new connections after policy expiry.
Revocation, policy expiry, or peer certificate expiry shuts down the exact
accepted TCP socket, including already-open HTTP/2 streams. Other peers remain
connected. A failed socket shutdown is logged and retried; these transport
checks do not themselves publish a UI enforcement receipt.

The local NATS leaf outage exception does not apply to inbound gRPC. Local
collector-to-leaf ingestion can continue under its separately enrolled binding,
while managed gRPC listeners continue requiring fresh policy. Certificate and
key rotation requires the installer-owned service restart because rustls keeps
the loaded local identity in memory.

The `//rust/cert-policy:cert_policy_test` target exercises real Tonic health
Watch streams with synthetic certificates: selective revocation, unaffected
same-serial control traffic, denied reconnection, policy expiry, restoration,
and rejection of an allowlisted certificate signed by an untrusted issuer.

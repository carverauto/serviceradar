# Local leaf certificate policy during WAN outages

Managed collectors normally require fresh certificate policy. An enrolled local
NATS leaf can continue receiving local telemetry during a WAN outage using the
last verified policy, including after a collector restart. This exception does
not apply to hub, core, gateway, or arbitrary NATS servers.

The privileged installer writes a binding for the collector service instance,
for example `/etc/serviceradar/managed-components/synthetic-collector/local-leaf.json`:

```json
{
  "version": 1,
  "endpoint": "tls://localhost:4222",
  "server_spiffe_id": "spiffe://example.com/nats-leaf/synthetic"
}
```

This is synthetic example data. The installer must obtain the endpoint and leaf
identity from the enrolled edge-site configuration. The file and its installation
path must be root-owned and not writable by group or world. Each service keeps
its own binding; a host-wide default leaf is not inferred.

Configure the binding beside the existing managed policy path:

| Collector | Local binding field |
| --- | --- |
| Flow collector | `security.cert_policy_local_leaf_file` |
| Trap collector | `nats_security.cert_policy_local_leaf_file` |
| OTEL and log collector | `nats.tls.cert_policy_local_leaf_file` |
| Flowgger syslog | `output.nats_cert_policy_local_leaf_file` |
| BMP collector | `nats_cert_policy_local_leaf_file` |

The corresponding `cert_policy_file` field remains required. Omit the local
binding field for fresh-policy enforcement. A malformed, missing, or mismatched
configured binding fails connection setup; it never silently disables policy.

The configured NATS address must contain exactly the enrolled host and port.
Both `tls://` and the existing `nats://` address spelling are accepted because
managed connections force TLS. WebSocket addresses, embedded URL credentials,
additional endpoints, and discovered-server fallback are not accepted in local
binding mode. The binding itself uses `tls://`.

After ordinary certificate-chain and hostname verification, the receiver checks
the exact SPIFFE URI and full-DER SHA256 fingerprint. The fingerprint must still
be allowed by the last authenticated policy. The stable SPIFFE binding permits
normal certificate rotation only when the new certificate has also been
introduced by authenticated policy. Known revocations remain effective during
an outage; unsigned, invalid, expired updates cannot add permissions.

Stale local admission is reported as `StaleLocal` by the connection guard and
logged when freshness changes. A fresh snapshot that removes the leaf closes
its active connection. Certificate or intermediate expiry also closes the
connection, even if stale policy otherwise permits local ingestion. The shared
store's ordinary authorization API remains fresh-policy-only.

The host agent retains the last verified policy file when refresh fails. TLS
consumers do not verify signing keys themselves; they require that privileged
installer to authenticate updates before atomically replacing the file. Updating
certificate or private-key files requires the service restart owned by the
certificate installer, because an existing rustls connection configuration holds
its previous local identity in memory.

The focused `//rust/cert-policy:cert_policy_test` target uses real rustls and
async-nats sockets to verify stale restart, revocation, active certificate
expiry, endpoint and SPIFFE mismatch rejection, and unaffected control traffic.

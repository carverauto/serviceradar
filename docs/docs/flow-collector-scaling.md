# Flow Collector Scaling and Exporter Authentication

The collector publishes converted NetFlow, IPFIX and sFlow telemetry to NATS
JetStream. EventWriter persists it to the configured telemetry backend.

## Secure defaults and upgrade migration

NetFlow v9 and IPFIX UDP source addresses do not authenticate exporters.
Spoofing an exporter's address, port and domain can replace its templates,
sampling state or pending records. IP allowlists and disabling persistence do
not close this local poisoning path.

Template-based UDP is rejected before parser admission by default. The whole
datagram is checked, including trailing packets after a valid legacy prefix.
Template-free NetFlow v5 and sFlow UDP remain available.

Before upgrading:

1. Remove all `template_store` overrides, including retained Helm values.
   Non-null shared-store configuration fails startup with a migration error.
   The collector never reads, writes or deletes old KV entries.
2. Configure mutually authenticated native IPFIX TLS/TCP for capable exporters.
   Approve each client certificate's SHA-256 leaf fingerprint explicitly.
3. For UDP-only devices, set `allow_unauthenticated_templates: true` on the
   relevant `netflow` listener only if accepting spoofing risk on a separately
   protected network. This mode is insecure. State is listener-local, starts
   cold on restart and is never shared through KV.

Existing v9/IPFIX UDP stops ingesting with secure defaults. Opening port 4740
alone does not configure TLS. The existing NATS `security` block authenticates
the collector to NATS, not the exporter.

## Native IPFIX TLS configuration

Use `protocol: ipfix_tls`, default address `0.0.0.0:4740`. Supply a server
certificate/key, client CA bundle and nonempty map of approved leaf fingerprints
to exporter IDs. Chain/validity verification and private-key possession happen
before authorization and parser creation. CA-trusted but unlisted clients and
plaintext IPFIX are rejected. TLS 1.2/1.3 are supported; early data and session
resumption are disabled.

Invented Helm example; replace the fingerprint before use:

```yaml
flowCollector:
  enabled: true
  ipfixTlsSecretName: flow-ingress-server-tls
  config:
    template_store: null
    listeners:
      - protocol: ipfix_tls
        subject: flows.raw.ipfix
        cert_file: /etc/serviceradar/ipfix-tls/server.pem
        key_file: /etc/serviceradar/ipfix-tls/server-key.pem
        client_ca_file: /etc/serviceradar/ipfix-tls/client-ca.pem
        exporters:
          "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef": exporter-01
        max_sessions: 64
        max_sessions_per_exporter: 2
        handshake_timeout_secs: 10
        read_timeout_secs: 60
        max_message_size: 65535
        max_sources: 128
        max_templates: 2000
  service:
    ports:
      ipfixTls:
        enabled: true
        port: 4740
        targetPort: 4740
```

The optional Secret mount holds collector server-side TLS material and the
public client CA bundle. Exporter private keys stay on exporters; public
fingerprints are configuration. This adds no device/integration credential
store; those credentials use the unified CNPG credential model.

Calculate lowercase colon-free SHA-256 over the leaf DER certificate:

```bash
openssl x509 -in exporter-client.pem -outform DER | openssl dgst -sha256
```

During rotation, map both old and new fingerprints to the same exporter ID.
They share its session allowance. Roll the collector to apply configuration
changes and terminate sessions authorized by a removed mapping. Exporters must
validate the collector server certificate and trust its CA.

## Session ownership and capacity

Each authenticated connection owns its templates, options templates, pending
records, sampling rates and observation-domain parsers. Sessions with identical
source IPs, domains and template IDs cannot overwrite or withdraw each other's
state, even if approved as the same exporter. Disconnect, read failure,
listener cancellation and restart discard that state. Every new connection
requires templates again per [RFC 7011 section 8](https://www.rfc-editor.org/rfc/rfc7011#section-8).

Only complete version 10 messages are parsed. Length must be 16-65535 bytes and
within the configured maximum. One deadline covers header and body, including
idle or partial-message stalls. Invalid, truncated and timed-out messages
terminate the connection. Multiple messages per TCP write and fragmented writes
are supported through message-length framing.

| TLS setting | Default | Supported bound |
|---|---|---|
| `max_sessions` | 64 | 1-4096, including handshakes |
| `max_sessions_per_exporter` | 2 | Positive, no greater than total |
| `handshake_timeout_secs` | 10 | 1-600 seconds |
| `read_timeout_secs` | 60 | 1-3600 seconds |
| `max_message_size` | 65535 | 16-65535 bytes |
| `max_sources` | 128 | 1-10000 observation domains per session |
| `max_templates` | 2000 | 1-10000 templates per domain |
| `exporters` | required | 1-4096 fingerprints; IDs 1-64 ASCII characters |
| `pending_flows` | disabled | At most 10000 pending flows, TTL at most 3600s |

Total permits are acquired before handshake; exporter permits after
authentication. All exits release them. A busy exporter cannot consume another
exporter's allowance. Listener shutdown cancels its child sessions.

The bootstrap Helm Job establishes stream ownership before pods start. TCP
load balancing keeps each session on one pod; new sessions can use other
replicas but start cold. More replicas spread sessions; higher CPU/memory
limits supply per-pod headroom. Size memory for the product of admitted
sessions, observation domains, templates and pending records.

Each listener has a bounded publisher channel (`channel_size`, default 10000)
feeding the common JetStream publisher (`batch_size` 100,
`publish_timeout_ms` 5000). Overflow rejects the newest message. Each handler
retains at most 65536 transport/domain/sampler-rate identities; existing entries can still be
updated, and a rate included in the current record takes priority. TLS handlers
are session-local. Insecure UDP `max_sources` defaults to 10000; eviction
prefers identities owned by the creating IP, then global LRU.

## Metrics and rollout verification

Prometheus is served at `/metrics` on `metrics_addr`, default `0.0.0.0:50046`.
Security labels contain only configured protocol/listener addresses, never
peer identities or fingerprints.

| Metric | Meaning |
|---|---|
| `flow_collector_tls_authenticated_sessions_total` | Approved authenticated connections |
| `flow_collector_tls_active_sessions` | Active authenticated sessions |
| `flow_collector_tls_auth_rejections_total` | Failed, expired or unapproved authentication |
| `flow_collector_tls_session_limit_rejections_total` | Total or exporter capacity reached |
| `flow_collector_ipfix_frame_rejections_total` | Invalid, partial or timed-out TLS message |
| `flow_collector_udp_template_rejections_total` | Default gate rejected template or non-legacy input |
| `flow_collector_sources` | Live domain parsers across listener sessions |
| `flow_collector_sampler_rate_rejections_total` | Sampler inserts rejected at capacity |
| `flow_collector_channel_full_drops_total` | Publisher overflow |
| `flow_collector_flows_converted_total` | Valid converted records |

Deprecated `template_store_*` metrics remain zero for dashboard compatibility.
Remove shared-bucket/restoration alerts. Missing templates on reconnect are
expected until that session announces them.

After new pods are ready, use an approved synthetic exporter and confirm its
records reach the expected JetStream subject. Reconnect without templates;
confirm no records until reannouncement. CA-trusted unlisted clients, plaintext
TLS-port traffic and default UDP v9/IPFIX must produce rejection counters and
no flow records. Give every observation a deadline and an explicit failure
branch. Device interoperability remains separate from synthetic transport
regressions.

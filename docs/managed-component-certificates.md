# Managed component certificate lifecycle

Managed enrollment binds an existing edge site or collector package to an enrolled
agent. Each host can own one instance of each fixed service: NATS leaf, log collector,
flow collector, BMP collector, and trapd. Syslog and OTEL share the log service;
NetFlow and sFlow share the flow service. Distinct services have distinct identities.

The administrative API requires `settings.edge.manage`:

1. Read `GET /api/admin/managed-components/bootstrap` for the deployment policy
   verification key and NATS authorization readiness. Pin the key through the trusted
   enrollment channel; the public policy endpoint is not a key-discovery service.
2. Register using `POST /api/admin/managed-components` with `host_agent_id`, `service`,
   and either `edge_site_id` or `collector_id`. A leaf also needs a collector-facing
   `advertise_url` such as `tls://leaf.example.test:4222`. The first registration
   requires an authenticated online agent session to establish its partition.
   Collector `server_hosts` are explicit administrator-approved DNS/IP SANs; defaults
   include localhost, loopback and the package hostname when supplied.
3. Install only the returned fixed-name configuration files. Registration does not
   issue certificates or start a service. Private keys are generated on the host.
   Repeating the same registration returns the existing component and generation.
4. `POST /api/admin/managed-components/:id/rotate` starts preparation and issuance.
   Poll `GET /api/admin/managed-components/:id`, matching `lifecycle.operation_id`
   from the rotate response. Component generation changes only on re-enrollment;
   ordinary renewal has a fresh operation ID within the same generation.

`installed` and `activated` describe the helper's atomic file installation and
service activation receipt. They do not prove receiver enforcement. The authority
retains predecessors until independently authenticated receiver observations cover
all successor roles. A leaf has upstream-client and local-server roles, so hub-side
observation alone cannot retire its previous pair.

Core persists the operation before sending commands. Lost replies reuse the same
preparation request, and the agent returns its durable CSR/installation receipt.
A minute-based reconciliation job discovers unfinished operations and due renewals;
per-operation jobs then progress the exchange. A failed activation is visible as a
failed operation and requires a new rotate request after correcting the host issue.

`POST /:id/revoke` blocks issuance and revokes the current generation. `POST
/:id/reenroll` creates a new generation; only newly recorded issuance may authorize.
It does not erase old revocations or reinstall old certificates. Registration cannot
silently move an existing component to another host, service or set of server names.

The public `GET /.well-known/serviceradar/certificate-policy` returns base64 `payload`
and `signature`. Decode payload bytes without re-encoding before Ed25519 verification.
The signature covers `serviceradar.certificate-policy.v1`, one zero byte, then the
exact JSON bytes. The JSON contains version, UTC generation/expiry timestamps,
allowed full-DER SHA256 fingerprints. Authenticated agent distribution additionally
includes NATS subject permissions keyed by fingerprint; the public endpoint omits them. The web cache lasts at most five seconds; failed refreshes never return
an expired cached policy. Hub receivers enforce freshness. Trusted local edge
configuration may continue with the last verified policy during WAN loss and must
report that policy as stale.

These interfaces do not themselves prove a deployment's active connection closure,
local NATS authorization reload, or all collector listener enforcement. Those require
the receiver and host acceptance checks in the managed-component OpenSpec proposal.

Managed leaf JetStream domains are stable per site (`edge_` plus the site UUID without
dashes). Bound collectors address that domain; their exact stream API permissions
cover both the addressed and broker-mapped subject forms. Unbound collectors use
the hub's default domain.

Infrastructure adoption is separate from host registration. An authorized operator
must supply effective `publish` and `subscribe` arrays and preserve optional
`publish_deny` and `subscribe_deny` arrays from the existing broker configuration.
Empty allow arrays mean no permission. Unadopted infrastructure gets no implicit
NATS grant; adoption never unblocks a revoked component or records a certificate.
Permission updates require the current certificate generation.

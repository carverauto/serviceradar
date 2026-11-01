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

Infrastructure adoption is separate from host registration. Existing cluster
collectors and other static NATS clients use component type `nats-client` with
their current explicit broker permissions. This records their public certificate
without an enrolled host or an agent-managed renewal operation; new edge services
continue to use host enrollment. The CLI's `edge.manage` scope permits managed
bootstrap/detail reads, registration, and rotation, subject to the operator's
`settings.edge.manage` permission. Infrastructure adoption, hub configuration,
and certificate revocation retain their administrative authentication boundary.
Permission-only
adoption stores effective `publish` and `subscribe` arrays, plus optional
`publish_deny` and `subscribe_deny` arrays. An empty allow array on that path
means no permission. That path does not record a certificate, and it does not
unblock a revoked component. Permission updates require the current certificate
generation. Unadopted infrastructure gets no implicit NATS grant.

`POST /api/admin/managed-components/adopt` records one existing public
infrastructure certificate. The JSON body carries `component_id`,
`component_type`, `partition_id`, optional `server_hosts`, `certificate_pem`,
and a static NATS `permissions` block. `publish` and `subscribe` are objects
with optional `allow` and `deny` arrays. An empty or omitted allow is stored
as `[">"]` and the deny list is kept. A non-empty allow is copied unchanged.
The PEM may contain only certificates. A private key is refused and nothing
is written. The response returns the component, the stored grant, and the
certificate fingerprint. It does not return the PEM. The route does not enable
broker authorization callout. The service-certificates inventory shows that
stored grant for an infrastructure component. An empty allow there is no
permission. A host service does not show this grant.

`POST /api/admin/managed-components/:id/certificates` records a successor
public certificate for that component. The JSON body carries `certificate_pem`
only. The component's current generation and stored grant stay unchanged.
The predecessor stays authorized until that fingerprint is revoked. The
response uses the same component and certificate fields as adoption and does
not return the PEM. A component with no certificate, a host service, a blocked
component, and a private key are refused. The route uses the same API key
pipeline and `settings.edge.manage` permission as adoption. Broker
authorization callout stays disabled.

`POST /api/admin/managed-components/:id/certificates/:fingerprint/revoke`
revokes that one fingerprint. The component stays unblocked. Its generation
and stored grant stay unchanged. Other fingerprints on the component stay
authorized. A fingerprint recorded for another component is refused. The
route uses the same API key pipeline and `settings.edge.manage` permission.
Broker authorization callout stays disabled.

The service-certificates inventory history offers the same fingerprint
revocation. The component stays unblocked. Its generation and stored grant
stay unchanged. The component Revoke control still blocks renewal until
re-enrollment. Broker authorization callout stays disabled.

`POST /api/admin/nats/certificate-authorization/bootstrap` stores signing material
only for the deployment account (`:nats_account_name`). A missing or unusable
deployment account returns `nats_account_unconfigured`. A different requested
name returns `nats_account_mismatch`. An existing record for another account
stays in place. Readiness includes the stored account name and stays unready
while that name disagrees with the deployment account. An authorization
request in that state is answered with `nats_account_mismatch` and no user
JWT, and the session is not remembered. A matching account is still decided
from the certificate policy. Broker authorization callout stays disabled.

`serviceradar-cli edge install` for a leaf or collector continues when the
hub authorizer is disconnected. `static_mtls` with an empty reason, or with
reason `connecting`, `auth_connection_unavailable`,
`auth_subscription_failed`, `policy_unavailable`, `not_configured`,
`authorizer_unavailable`, or `core_unavailable`, continues. An unset mode
continues while the hub is not configured. `static_mtls` still requires the
deployment account name. The command does not create the account or require
a JWT account seed. It stops before package installation for
`jwt_account_signer_unconfigured`, `unsupported_auth_mode`,
`nats_account_mismatch`, any other authentication mode, and `nats.ready`
without `static_mtls`. Broker authorization callout stays disabled.

A stored `operator_jwt` authentication mode reports readiness reason
`jwt_account_signer_unconfigured`. The authorizer does not open a broker
connection and does not create an account signer. `edge install` stops
before package installation because that readiness is false. Broker
authorization callout stays disabled.

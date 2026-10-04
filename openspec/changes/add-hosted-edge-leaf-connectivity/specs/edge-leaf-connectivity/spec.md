## ADDED Requirements

### Requirement: Chart exposes an opt-in NATS leafnode listener
The Helm chart SHALL render a NATS `leafnodes {}` listener only when
`nats.leafnodes.enabled` is true. The listener port SHALL default to 7422 and be
configurable with `nats.leafnodes.port`, and it SHALL be exposed as a container
port and on the `serviceradar-nats` Service. The listener SHALL terminate TLS in
nats-server with the NATS runtime certificate. It SHALL verify leaf client
certificates against the internal CA, and SHALL bind a leaf only when its
certificate carries the role URI SAN
`spiffe://serviceradar.local/nats-leaf/<partitionId>`. A bound leaf is placed in
the platform account. When `hostedRuntime.publicEndpoints.natsLeafHost` is set,
the chart's NATS certificate generator SHALL add it as a SAN, together with each
entry of `nats.leafnodes.tls.extraDnsNames`.

#### Scenario: Leafnodes disabled by default
- **WHEN** the chart is rendered with default values
- **THEN** the NATS config contains no `leafnodes` block and the Service exposes no port 7422

#### Scenario: Leafnodes enabled
- **WHEN** `nats.leafnodes.enabled` is true
- **THEN** the NATS config contains a `leafnodes` block on port 7422 with TLS `verify_and_map`, and a leaf user mapped to the platform account by the partition role URI
- **AND** the `serviceradar-nats` Service exposes port 7422

#### Scenario: Leaf host is a certificate SAN
- **WHEN** `hostedRuntime.publicEndpoints.natsLeafHost` is `acme.nats.serviceradar.cloud`
- **THEN** the generated NATS certificate request includes `DNS:acme.nats.serviceradar.cloud`

### Requirement: Gateway API route for NATS leaf traffic
When `gatewayApi.natsLeaf.enabled` is true, the chart SHALL render a Gateway TCP
listener and a TCPRoute that forwards raw TCP to the NATS leafnode Service port.
It SHALL do this the same way as `gatewayApi.agentGateway.grpc`, in both managed
and attach modes. If `networkPolicy.enabled` is also true, the chart SHALL admit
leafnode ingress to NATS from the envoy gateway namespace.

#### Scenario: Managed gateway leaf route
- **WHEN** `gatewayApi.natsLeaf.enabled` is true in managed mode
- **THEN** the Gateway has a TCP listener named `nats-leaf` on port 7422
- **AND** a TCPRoute attaches to that listener and targets `serviceradar-nats` port 7422

#### Scenario: Attach mode requires parent refs
- **WHEN** `gatewayApi.natsLeaf.enabled` is true in attach mode without `gatewayApi.natsLeaf.parentRefs`
- **THEN** rendering fails with an error naming `gatewayApi.natsLeaf.parentRefs`

### Requirement: Effective leaf upstream URL
web-ng SHALL use `SERVICERADAR_NATS_LEAF_UPSTREAM_URL` as the leaf upstream URL
when it is set. The chart SHALL render that variable as
`tls://<natsLeafHost>:<natsLeafPort>` when
`hostedRuntime.publicEndpoints.natsLeafHost` is set. `natsLeafPort` defaults to
7422.

#### Scenario: Hosted leaf host renders the upstream URL
- **WHEN** `hostedRuntime.publicEndpoints.natsLeafHost` is `acme.nats.serviceradar.cloud`
- **THEN** web-ng receives `SERVICERADAR_NATS_LEAF_UPSTREAM_URL=tls://acme.nats.serviceradar.cloud:7422`

### Requirement: Leaf servers are provisioned with internal-CA certificates
The leaf provisioning worker SHALL obtain two certificates from the
agent-gateway CA: a leaf client certificate that carries the partition role URI
SAN, and a local server certificate whose SANs cover `localhost`, `127.0.0.1`
and the edge site's local NATS host. It SHALL store both, their keys and the CA
chain through the `NatsLeafServer` `provision` action. If no gateway CA is
reachable, the leaf server SHALL stay `pending` and the job SHALL retry.

#### Scenario: Successful provisioning
- **WHEN** a leaf server is provisioned while an agent-gateway is reachable
- **THEN** the leaf server becomes `provisioned`, with leaf and server certificates, encrypted keys and a CA chain

#### Scenario: No gateway available
- **WHEN** no agent-gateway node is reachable
- **THEN** the job returns an error for retry and the leaf server stays `pending`

### Requirement: Leaf bundles carry no placeholder credentials
The edge-site bundle SHALL contain `nats/nats-leaf.conf`, the certificates,
`setup.sh` and `README.md`. The bundle's leaf config SHALL use the leaf server's
stored upstream URL. If a NATS account name and seed are configured, the bundle
SHALL contain `creds/account.creds` minted through
`ServiceRadar.NATS.AccountClient`, and the config SHALL reference it. Otherwise
the bundle SHALL leave the creds file and the config's `credentials` line out.
The bundle SHALL NOT contain placeholder JWTs or seeds.

#### Scenario: No NATS account configured
- **WHEN** a bundle is generated and no NATS account seed is configured
- **THEN** the tarball has no `creds/account.creds` and `nats-leaf.conf` has no `credentials` line

#### Scenario: NATS account configured
- **WHEN** a bundle is generated with a configured NATS account
- **THEN** `creds/account.creds` contains the creds file returned by AccountClient

### Requirement: Leaf setup script targets the serviceradar-nats unit
The bundle `setup.sh` SHALL install the config to `/etc/nats/nats-server.conf`,
backing up any existing file first. It SHALL install certificates to
`/etc/nats/certs` with `nats:serviceradar` ownership, validate the config with
`nats-server -t`, and then enable and restart `serviceradar-nats.service`. It
SHALL work from any working directory on Oracle Linux 9.

#### Scenario: Setup restarts the packaged unit
- **WHEN** `setup.sh` runs as root on a host with the serviceradar-nats RPM installed
- **THEN** it enables and restarts `serviceradar-nats` and never references a `nats-server` unit

### Requirement: Edge site JSON API
web-ng SHALL expose edge sites under `:api_key_auth`, and every action SHALL
require the `settings.edge.manage` RBAC permission. The routes are:

- `GET /api/admin/edge-sites`
- `POST /api/admin/edge-sites`, which creates the site and enqueues leaf provisioning
- `GET /api/admin/edge-sites/:id`
- `DELETE /api/admin/edge-sites/:id`
- `POST /api/admin/edge-sites/:id/bundle`, which returns an `application/gzip` tarball

The bundle endpoint SHALL return 409 `{"error":"leaf_not_ready"}` until the leaf
server is provisioned. Each site SHALL be serialized as
`{id,name,slug,status,nats_leaf_url,leaf_server:{status,upstream_url}|null,inserted_at}`.
web-ng SHALL also expose `GET /api/admin/agents`, which returns
`{data:[{uid,name,gateway_id,status,last_seen,version,partition}]}`.

#### Scenario: Create an edge site
- **WHEN** an authorized caller posts `{name: "NYC Office"}` to `/api/admin/edge-sites`
- **THEN** the response is 201 with `data.slug` `nyc-office` and a pending leaf server

#### Scenario: Bundle before provisioning
- **WHEN** the bundle is requested while the leaf server is `pending`
- **THEN** the response is 409 with `{"error":"leaf_not_ready"}`

#### Scenario: Missing permission
- **WHEN** a caller without `settings.edge.manage` lists edge sites
- **THEN** the response is 403

### Requirement: edge.manage narrow CLI scope
`edge.manage` SHALL be a narrow CLI scope. It SHALL reach only:

- the edge package routes
- the collector routes
- the NATS account and credentials routes
- the edge site routes
- `GET /api/admin/agents`

The CLI device-code flow SHALL be able to request it by default.

#### Scenario: Narrow token reaches edge sites
- **WHEN** a token scoped only to `edge.manage` calls `GET /api/admin/edge-sites`
- **THEN** the request passes the narrow-scope confinement

#### Scenario: Narrow token cannot reach unrelated routes
- **WHEN** a token scoped only to `edge.manage` calls `POST /api/admin/plugin-packages`
- **THEN** the response is 403 `insufficient_scope`

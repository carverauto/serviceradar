# Change: Hosted edge NATS leaf connectivity

## Why

Hosted tenants need an edge site's NATS leaf server to reach the tenant's NATS
cluster, and the JS CLI needs a narrow API for edge sites. None of that works
today:

- The chart has no `leafnodes {}` listener, no Service port 7422 and no Gateway
  route, so a leaf has nothing to dial.
- `ProvisionLeafWorker` calls `NatsLeafServer.provision` with only
  `config_checksum`. The action also requires the leaf and server certificates
  and the CA chain, so provisioning fails and bundle generation stops with
  `:no_leaf_key`.
- The bundle's `creds/account.creds` holds `PLACEHOLDER_JWT` and
  `PLACEHOLDER_SEED`.
- `setup.sh` manages a `nats-server` unit. The `serviceradar-nats` RPM ships
  `serviceradar-nats.service`, and the script's `chown nats:nats` fails
  silently because the RPM creates `nats` in the `serviceradar` group.
- The leaf upstream URL is hardcoded to `tls://nats.serviceradar.cloud:7422`.
- There is no JSON API for edge sites and no CLI scope for edge work.

Tracked by carverauto/serviceradar-control#154. The control-plane counterpart is
the `add-tenant-edge-connectivity-launch-validation` change in
carverauto/serviceradar-control. The values keys and routes below are that
change's shared contract.

## What Changes

- **Chart:** add `nats.leafnodes`. When enabled it renders a `leafnodes {}`
  block that terminates TLS in nats-server and verifies leaf client certificates
  against the internal CA. Leaves bind to the platform account through the
  role URI SAN
  `spiffe://serviceradar.local/nats-leaf/<partitionId>`. The block also adds
  container and Service port 7422. The NATS runtime certificate gains
  `hostedRuntime.publicEndpoints.natsLeafHost` and
  `nats.leafnodes.tls.extraDnsNames` as SANs.
- **Chart:** add `gatewayApi.natsLeaf`, a Gateway TCP listener plus a TCPRoute
  to NATS on 7422. When network policy is enabled, the chart also adds a
  NetworkPolicy that admits the envoy namespace. This mirrors
  `gatewayApi.agentGateway.grpc`.
- **Chart:** render `SERVICERADAR_NATS_LEAF_UPSTREAM_URL` for web-ng from
  `hostedRuntime.publicEndpoints.natsLeafHost` and `natsLeafPort`.
- **Chart:** add `hostedRuntime.publicEndpoints.natsLeafHost`, `natsLeafPort`
  and `natsLeafServerName`.
- All new chart features are off by default.
- **Leaf provisioning:** `ProvisionLeafWorker` gets a leaf client certificate
  and a local server certificate from the agent-gateway CA, using the new
  `nats_leaf` component type. It stores both through the `provision` action.
- **Leaf bundle:** `creds/account.creds` is minted with
  `ServiceRadar.NATS.AccountClient` when a NATS account is configured. Otherwise
  the bundle and `nats-leaf.conf` leave the credentials out and the leaf
  authenticates with mTLS only. Placeholder credentials are never shipped.
- **Leaf bundle:** `setup.sh` targets `serviceradar-nats.service` on Oracle
  Linux 9. It sets `nats:serviceradar` ownership, validates the config with
  `nats-server -t` before restarting, and runs from any working directory.
- **API:** add `EdgeSiteController` under `:api_key_auth` with RBAC
  `settings.edge.manage`. It serves:
  - `GET|POST /api/admin/edge-sites`
  - `GET|DELETE /api/admin/edge-sites/:id`
  - `POST /api/admin/edge-sites/:id/bundle`, which returns 409 `leaf_not_ready`
    until the leaf is provisioned
- **API:** add `GET /api/admin/agents`, a read-only edge view of agents.
- **API:** `POST /api/admin/edge-packages` returns the signed `edgepkg-v3`
  `onboarding_token`. mTLS agent packages are issued through an online
  agent-gateway, as in the UI. `POST /api/admin/collectors` mints and returns
  the `collectorpkg-v2` `enrollment_token`. `GET /api/admin/version` returns
  the running release.
- **Auth:** add the narrow CLI scope `edge.manage`. It is in the NarrowScopes
  allowlist and in the default `cli_allowed_scopes`, and a migration appends it
  to existing rows, so the device-code flow can request it.

## Impact

- Affected specs: `edge-leaf-connectivity` (new).
- Affected code:
  - `helm/serviceradar` (nats, gateway-api, network-policy, web, cert script,
    values)
  - `elixir/serviceradar_core/lib/serviceradar/edge/*`
  - `elixir/serviceradar_agent_gateway` (`CertIssuer`)
  - web-ng (controllers, router, NarrowScopes, CLI auth defaults, edge-site
    LiveView)
  - a `platform.authorization_settings` default migration
- Hosted mode: the control plane issues `nats.pem`. Its SANs must include
  `natsLeafHost` before `nats.leafnodes.enabled` is turned on.
- Interaction with `refactor-agent-nats-credential-provisioning`: this change
  adds no central account seed or platform credential to agent bundles. Leaf
  creds come only from the leaf-scoped AccountClient mint, and only when the
  operator has configured an account.
- PKCE `/api/v1/cli/auth/authorize` and the `authorization_code` grant are implemented for `serviceradar-cli auth login --web`.

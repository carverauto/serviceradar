## 1. Chart (PR 1)

- [x] 1.1 Add `nats.leafnodes` values, the `leafnodes {}` config block, and container and Service port 7422, all off by default.
- [x] 1.2 Add `hostedRuntime.publicEndpoints.natsLeafHost` and `nats.leafnodes.tls.extraDnsNames` to the generated NATS certificate SANs.
- [x] 1.3 Add a `gatewayApi.natsLeaf` Gateway TCP listener and TCPRoute, plus a NetworkPolicy that admits the envoy namespace.
- [x] 1.4 Render `SERVICERADAR_NATS_LEAF_UPSTREAM_URL` for web-ng from the hosted public endpoint facts.
- [x] 1.5 Add helm unittest coverage for defaults-off, enabled leafnodes, the gateway route, attach-mode validation, the NetworkPolicy, the SANs and the web-ng env var.
- [x] 1.6 Document the hosted-mode SAN requirement in `TENANT_RUNTIME.md`.

## 2. Leaf provisioning (PR 2)

- [ ] 2.1 Add the `nats_leaf` component type to the agent-gateway `CertIssuer`, issuing client certs with the partition role URI SAN and server certs with local SANs.
- [ ] 2.2 Make `ProvisionLeafWorker` issue both certs through a reachable gateway and call `provision` with all required arguments.
- [ ] 2.3 Mint leaf creds through `AccountClient` when a NATS account is configured, and drop creds from the bundle otherwise.
- [ ] 2.4 Rewrite `setup.sh` and the README for `serviceradar-nats.service`, `nats:serviceradar` ownership and `nats-server -t` validation.
- [ ] 2.5 Read `SERVICERADAR_NATS_LEAF_UPSTREAM_URL` into `:nats_leaf_upstream_url` in web-ng.
- [ ] 2.6 Share one bundle builder between the edge-site LiveView and the API.

## 3. Edge-site API and CLI scope (PR 2)

- [ ] 3.1 Add `EdgeSiteController` (index, create, show, delete, bundle) under `:api_key_auth` with `settings.edge.manage`.
- [ ] 3.2 Add `GET /api/admin/agents` (read-only edge view).
- [ ] 3.3 Add the `edge.manage` NarrowScopes allowlist.
- [ ] 3.4 Add `edge.manage` to the default `cli_allowed_scopes` (resource default, migration default, controller and LiveView fallbacks).
- [ ] 3.5 Add controller and confinement tests.

## 4. Deferred

- [ ] 4.1 PKCE `/api/v1/cli/auth/authorize` for `serviceradar-cli login --web`. It needs an authorize page, code storage and a PKCE `authorization_code` grant in `CliAuthController.token`, so it is deferred. Until then the CLI falls back to the device-code flow.
- [ ] 4.2 Per-leaf revocation. Leaves authenticate with a shared partition role SAN, so revocation currently relies on certificate expiry.
- [ ] 4.3 Leafnode subject permissions. The leaf binds to the platform account with account-wide access, and a dedicated edge account with explicit imports is a follow-up.
- [ ] 4.4 Local listener client authentication for collectors that have no CA-issued client certificate.

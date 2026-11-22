# Managed component certificate lifecycle

Managed enrollment binds an existing edge site or collector package to an enrolled
agent. Each host can own one instance of each fixed service: NATS leaf, log collector,
flow collector, BMP collector, and trapd. Syslog and OTEL share the log service;
NetFlow and sFlow share the flow service. Distinct services have distinct identities.

The combined log collector owns a single health listener at `health.listen_addr`.
When syslog is enabled, it uses the mTLS settings from the Flowgger configuration's
`grpc` section and reports both `log-collector` and `flowgger` health on that
listener. Embedded Flowgger does not open another health socket. Invalid TLS
configuration or an occupied health port fails collector startup. Standalone
Flowgger continues to own its configured gRPC listener.

Packaged Linux enrollment, `srctl enroll` as root, publishes that enrollment where
the privileged helper can trust it. Enrollment makes `/etc/serviceradar` and
`/etc/serviceradar/host-trust` root-owned directories that no other user can write,
then writes `identity.json` (agent id and partition only) and `ca.pem` (the
enrollment CA chain) there as root-owned regular files. The service account still
owns `agent.json` and `/etc/serviceradar/certs`, including `ca-chain.pem`, so
renewal can replace `component.pem` there while host-trust stays unchanged. The
helper and `edge install` trust that host-trust identity and CA. A host enrolled
before this record existed needs a new agent package and `srctl enroll` as root
to publish it. Package upgrade keeps an existing host-trust directory root-owned
at mode `0755`, leaves the certificate directory service-owned, and refuses a
symlink at `/etc/serviceradar/host-trust`.

The administrative API requires `settings.edge.manage`:

1. Read `GET /api/admin/managed-components/bootstrap` for the deployment policy
   verification key, NATS authorization readiness (`data.nats`), and hub
   readiness (`data.hub`, or `null` when core is unavailable). Pin the key
   through the trusted enrollment channel; the public policy endpoint is not a
   key-discovery service.
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

The Edge Sites and Data Collectors pages show managed deployment state from the
current enrollment's installation operation. `installed` means the host acknowledged
installation and activation; it is not a connection heartbeat. A component stays
`installed` while a renewal in the same enrollment is in progress or after it fails;
the details view shows the renewal state and error separately. A blocked component
shows `revoked`, and re-enrollment shows `pending` until a new operation starts.
An older enrollment's receipt cannot mark the new enrollment installed. Lists,
details, and status filters use this same state and refresh every ten seconds.
Unmanaged deployments retain their existing provisioning status. The edge sites
API (`/api/admin/edge-sites`) exposes this same `deployment_status` and `managed`
distinction for `serviceradar-cli edge site list`, `edge site show`, and
`edge install leaf` (falling back to raw site and leaf fields on older instances).
Use Service Certificates for managed rotation, revocation, and re-enrollment.

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

Hub authorization grants expire at the broker independently of the short admission
policy snapshot. Set `SERVICERADAR_NATS_CERTIFICATE_GRANT_TTL_SECONDS` on core to a
positive integer (default `43200`, or 12 hours). Each grant receives uniform +/-20%
jitter and is capped at certificate expiry. At the default, the maximum fallback
bound is 14 hours 24 minutes if every authorizer disappears. New admissions still
require fresh policy. Revocation and de-adoption use targeted system-account KICK
requests immediately, without waiting for expiry. Each hub grant's user name is
the certificate fingerprint, a dot, and a SHA-256 of its publish and subscribe
permissions, the same scheme as the local leaf grants. About every ten seconds
the authorizer lists presented-certificate sessions and disconnects one whose
broker-reported `authorized_user` differs from the grant its certificate would
receive now (an older stored or static grant, or an earlier release's
bare-fingerprint name); the reconnect receives the current grant. It disconnects
at most 64 such sessions per scan and waits five minutes before disconnecting a
certificate again for the same stale name. The first upgrade to a release with
named grants therefore reconnects every hub session once. A failed database read
keeps the authorizer's last state; its stale snapshot still stops new
admissions. The authorizer needs publish
access to `$SYS.REQ.SERVER.*.KICK` and `$SYS.REQ.SERVER.*.CONNZ`, plus its reply inbox;
the managed Helm authorization configuration supplies those permissions.

Scheduled expiry reconnects the client or leaf. Publishers need acknowledged
JetStream writes and stable message IDs when retrying; consumers need durable
state and acknowledgements. A successful reconnect alone does not prove delivery.
The stock-broker regression exercises repeated expiry, subscription recovery,
leaf-to-hub publishing and durable consumer progress on both the packaged broker
and the newer server module. Local leaf authorization retains its separate offline
policy contract; this setting changes hub grants only.

Managed local leaf grants also default to 12 hours with +/-20% jitter, capped
at certificate expiry. The root-owned
`/etc/serviceradar/managed-components/local-nats.json` configures their nominal
`grant_ttl_seconds` (1 through 31536000). This is separate from policy freshness:
WAN loss still permits local ingestion under the last verified policy. The agent
asks its privileged helper to reconcile local sessions every five seconds; the
helper reads that policy, lists the local `EDGE` account, and kicks fingerprints
that no longer have a grant or whose session was granted different subject
permissions; the reconnect receives the current permissions. It holds the
system-account seed root-only and never accepts a caller-selected broker, client
ID, or fingerprint to disconnect.

For a leaf installed before the system credential was introduced, rerun managed
leaf installation with the updated agent/helper, then restart the local NATS
service once to activate its system-account configuration. Bootstrap preserves
the existing issuer and callout keys. Grants keep the 30-second lifetime until a
reconciliation has listed sessions through the running broker's system account;
the helper records that broker and issues long grants only to it, so it never
extends sessions without targeted revocation support. Later certificate
rotations continue using the supported reload path. A default grant surviving the old 30-second boundary, scheduled
expiry with durable-consumer progress, targeted revocation and permission
narrowing preserving another collector, and short grants before system-account
activation are covered by the stock-broker regression.

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
continue to use host enrollment. The CLI's `edge.manage` scope permits
`GET /api/admin/managed-components/bootstrap`,
`GET /api/admin/managed-components/:id`, `POST /api/admin/managed-components`,
and `POST /api/admin/managed-components/:id/rotate`, subject to the operator's
`settings.edge.manage` permission. Infrastructure adoption, hub certificate
authorization bootstrap, successor recording, fingerprint revocation, component
revoke, and re-enrollment stay outside that narrow scope.
Permission-only adoption stores effective `publish` and `subscribe` arrays, plus optional
`publish_deny` and `subscribe_deny` arrays. An empty allow array on that path
means no permission. That path does not record a certificate, and it does not
unblock a revoked component. Permission updates require the current certificate
generation. Unadopted infrastructure gets no implicit NATS grant.

With broker authorization callout enabled, the broker sends every built-in
cluster identity to the callout as well. The chart defines those identities and
their static permissions once (`templates/_nats_static_users.tpl`). It renders
them into the broker configuration and into the `serviceradar-nats-static-users`
ConfigMap, which core reads from `SERVICERADAR_NATS_STATIC_USERS_FILE`. An
adopted infrastructure certificate whose subject names one of those identities
is granted that identity's static block, projected the same way adoption
projects it, instead of its stored grant. Admission does not change: the
fingerprint must still be adopted, unrevoked and carry a stored grant. A subject
a release adds to the chart therefore reaches the callout grant without
re-adopting the component. Host-enrolled components, leaves and any other
subject keep their stored grant. Without the file, every adopted component keeps
its stored grant. If the file exists but has not yet been read successfully,
adopted infrastructure certificates are refused (`static identity grants
unavailable`) rather than granted their stored grant, and no session is
disconnected for its grant; host-enrolled components are unaffected.

When core and the chart's NATS are enabled, Helm mounts the public certificate
inventory on core and sets the three paths below. Core can adopt eligible
certificates even with broker authorization callout disabled. On a non-hosted
installation with `certs.generator.enabled` set to `true`, the chart owns the
runtime certificate Secret and projects every chart NATS client certificate.

On a hosted installation or one with the generator disabled, the supplier of
the runtime certificate Secret lists the files it carries in
`certs.inventoryCertificates`. The accepted filenames are the `file` entries in
[`serviceradar.natsChartIdentities`](../helm/serviceradar/templates/_helpers.tpl).
By default the list is empty and core mounts an empty directory. Each listed
file must exist in the Secret for the volume to mount.

For installations without the Helm chart, configure the static users file
described above and supply all three inventory paths to core.

| Core environment variable | Contents |
| --- | --- |
| `SERVICERADAR_NATS_INFRASTRUCTURE_CERTS_DIR` | Directory of public PEM files, each containing the client certificate followed by any intermediate issuers in order. |
| `SERVICERADAR_NATS_CHART_IDENTITIES_FILE` | YAML list of chart client certificate subjects. Static users outside this list are excluded from coverage. |
| `SERVICERADAR_NATS_INFRASTRUCTURE_ROOT_FILE` | Deployment root CA certificate in PEM format. |

If any of the three paths is unset or empty, reconciliation returns empty
coverage without accessing the database. With all three set, an unreadable or
invalid subject list, static users file, or root certificate stops the pass
before any writes.
Core matches each client by its certificate subject. For a listed subject with
a static grant and a valid chain to the deployment root, core records the first
certificate as a `nats-client` with that grant. Its component ID depends only on
the subject. Core uses `SERVICERADAR_OTX_PARTITION` when it has a non-empty
value. Otherwise it uses the `:serviceradar` application setting
`:nats_chart_identity_partition_id`, which defaults to `default`.

First adoption pauses while any recorded infrastructure certificate lacks a
stored subject. Use the original-PEM procedure below to fill it. A recorded
certificate continues to hold its subject after revocation. The existing
rotation procedure handles replacements for held subjects.

Core logs changes in coverage for each listed subject. An identity counts as
adopted when the certificate authority allows its inventory fingerprint.
`recorded_not_authorized` means the fingerprint is on record but the authority
excludes it. `held_unrecorded` means another recorded certificate holds the
subject and the inventory fingerprint is absent from the record. Copies of the
same certificate count once. If several distinct fingerprints name one subject,
core skips first adoption for that subject and reports it as adopted only when
the authority allows them all. Files with an unlisted subject or an undecodable
certificate appear under `unlisted` in the reconciliation report. Coverage is
advisory and does not block admission; core exposes it in hub readiness under
`chart_identities` (`null` when inventory reconciliation has not completed,
failed, or is unavailable). For `held_unrecorded` identities, `chart_identities`
attaches `rotation_reason` when `RuntimeCertificateRotation` refused that
certificate fingerprint (non-atom transient errors collapse to
`transient_error`) or `rotation_unavailable` when the rotation process or
manifest is unavailable.

Core assembles hub readiness (`ServiceRadar.NATS.HubReadiness`) from
`SERVICERADAR_NATS_CERTIFICATE_AUTHORIZATION_ENABLED` (`enforcement_configured`),
`SERVICERADAR_NATS_LEAF_LISTENER_ENABLED` (`leaf_listener`), mounted signing
seed status (`signing_keys_provisioned`), authorizer readiness
(`authorizer_answering` and `authorizer_reason`, with
`signing_keys_not_provisioned` taking precedence whenever mounted seeds are
configured and incomplete or unreadable), and `chart_identities`. Web-ng adds
`leaf_upstream_url` (`true` only when `SERVICERADAR_NATS_LEAF_UPSTREAM_URL` is
explicitly configured as a non-empty value; the hard-coded hosted fallback is
never reported as configured) and serves the combined object as `data.hub` on
`GET /api/admin/managed-components/bootstrap` (`null` when core is unavailable)
and as `{"schema_version": 1, "hub": ...}` on `GET /v1/hub/readiness` over the
cluster-only control-plane runtime listener (`503` with
`{"status": "core_unavailable"}` when core is unavailable).

`POST /api/admin/managed-components/adopt` records one existing public
infrastructure certificate. The JSON body carries `component_id`,
`component_type`, `partition_id`, optional `server_hosts`, `certificate_pem`,
and a static NATS `permissions` block. Each supplied host must contain a
non-whitespace character and must be free of NUL bytes. `publish` and
`subscribe` are objects with optional `allow` and `deny` arrays. On first
adoption, an empty or omitted allow is stored as `[">"]` and the deny list is
kept. A non-empty allow is copied unchanged. Repeating adoption for the same
component and fingerprint preserves the component's current grant.
The PEM may contain only certificates. A private key is refused and nothing
is written. The response returns the component, the stored grant, and the
certificate fingerprint. It does not return the PEM. The route does not enable
broker authorization callout. The service-certificates inventory shows that
stored grant for an infrastructure component. An empty allow there is no
permission. A host service does not show this grant.

Core stores the subject from the public certificate when it records an
infrastructure certificate. For an infrastructure certificate recorded before
subjects were stored, submit its original PEM again for the same component.
Once the caller is authorized and the fingerprint matches, core fills the
missing subject before checking admission. A revoked, expired or superseded
certificate can therefore gain a subject even when the request returns an
error. This update grants no access. Host-enrolled issuance leaves the
subject null.

`POST /api/admin/managed-components/:id/certificates` records a successor
public certificate for that component. The JSON body carries `certificate_pem`
only. The component's current generation and stored grant stay unchanged.
The predecessor stays authorized until that fingerprint is revoked. The
response uses the same component and certificate fields as adoption and does
not return the PEM. A component with no certificate, a host service, a blocked
component, and a private key are refused. The route uses the same API key
pipeline and `settings.edge.manage` permission as adoption.

When the [in-chart certificate generator](docs/tls-security.md#in-chart-certificate-generator)
reissues runtime certificates (for example when `certs.runtimeLayoutVersion`
changes, a required file is missing, or a required leaf does not verify against
`root.pem`), the pre-upgrade hook runs before core rolls. When the Secret passes
those checks, any kept certificate that lacks a requested DNS, URI, or IPv4 name
is reissued alone from the same root CA while every other certificate keeps its
fingerprint. On any reissue, the generator writes `runtime-cert-rotation.json`
into the runtime certificate Secret. For each reissued public certificate, that
record holds the fingerprint it replaced, its own fingerprint, and its PEM with
the root CA. It holds no key. The core
migrations pre-upgrade hook, and then core whenever the mounted record changes,
records each replacement as the successor of the component that holds the
replaced fingerprint. A replacement is recorded only when the replaced
certificate is recorded, unrevoked and at the current generation, and only when
both have the same issuer. A certificate that was never adopted is skipped. The
replaced certificates stay authorized until you revoke them. Revoke them once no
pod presents them. A rotation from before this record existed has no record, so
record its successors with this route. The chart refuses the callout together
with `certs.regenerator.enabled`, because the regenerator reissues the root CA.

`POST /api/admin/managed-components/:id/certificates/:fingerprint/revoke`
revokes that one fingerprint. The component stays unblocked. Its generation
and stored grant stay unchanged. Other fingerprints on the component stay
authorized. A fingerprint recorded for another component is refused. The
route uses the same API key pipeline and `settings.edge.manage` permission.

The service-certificates inventory history offers the same fingerprint
revocation. The component stays unblocked. Its generation and stored grant
stay unchanged. The component Revoke control still blocks renewal until
re-enrollment.

## Enabling hub certificate authorization

On Helm-managed deployments, enable broker certificate authorization through
`nats.certificateAuthorization.enabled` in staged steps. See the
[TLS guide](docs/tls-security.md#in-chart-certificate-generator) for certificate
generator details.

### 1. Upgrade with enforcement disabled

Upgrade with `nats.certificateAuthorization.enabled: false` first so core can
reconcile its chart identity inventory before the broker requires callout
admission:

- **Generator-owned runtime Secret** (`certs.generator.enabled: true` on a
  non-hosted install): the chart projects the fixed public certificate
  inventory defined by `serviceradar.natsChartIdentities` and
  `chart-identities.yaml` into core, and the pre-upgrade hook verifies every
  projected file before core rolls. If an older runtime Secret lacks any
  inventory certificate, the hook regenerates the runtime certificates once and
  writes `runtime-cert-rotation.json` before core starts; a complete, valid
  Secret is preserved.
- **Supplier-owned runtime Secret** (hosted installs or
  `certs.generator.enabled: false`): core projects only the filenames listed in
  `certs.inventoryCertificates`, which defaults to `[]` (mounting an empty
  directory). Core starts, adopts nothing, and reports each chart identity as
  not adopted (`no_inventory_certificate`). To enable automatic adoption, place
  the public client certificates in the runtime Secret and list their filenames
  in `certs.inventoryCertificates`. Every listed key must exist in the Secret
  for core to mount its volume and start; never list a private key. When
  `certs.generator.enabled: true` with a distinct `certs.issuerSecretName`, the
  inventory stays fixed and generator-owned while the Secret supplier owns the
  callout signing keys.
- **Legacy certificate rows without a subject**: if any recorded `nats-client`
  infrastructure certificate lacks a stored subject (from a release before
  subject storage was added), first adoption pauses and reports
  `legacy_certificates_without_subject`. Re-record each legacy certificate by
  submitting its original PEM to `POST /api/admin/managed-components/adopt` for
  the same component, or remove the obsolete component.
- **Verify coverage**: run `serviceradar-cli edge hub status` or inspect
  `data.hub.chart_identities` on `GET /api/admin/managed-components/bootstrap`
  (and core's reconciliation logs: `Chart identity <subject> is adopted...` and
  `Chart identity <subject> is not adopted: <reason>`). Hand-adopted inventory
  certificates that are recorded and unrevoked count toward coverage even if
  their legacy row has no stored subject, while omitted chart identities log a
  warning even if previously hand-adopted. Alias static users
  (`serviceradar-flowgger`, `serviceradar-otel`,
  `serviceradar-netflow-collector`) and `O=ServiceRadar` are not chart
  identities and are excluded from coverage.

### 2. Confirm signing key ownership and the five `nats-callout-*` keys

Callout signing uses five keys split between the issuer Secret
(`certs.issuerSecretName`, defaulting to `certs.runtimeSecretName`) and the
runtime certificate Secret (`certs.runtimeSecretName`):

| Key | Secret | Role |
| --- | --- | --- |
| `nats-callout-issuer.seed` | Issuer Secret | NATS account nkey seed (`SA...`) used by core to sign authorization callout JWT responses. |
| `nats-callout-auth.seed` | Issuer Secret | NATS user nkey seed (`SU...`) for core's auth callout subscriber connection in account `AUTH`. |
| `nats-callout-system.seed` | Issuer Secret | NATS user nkey seed (`SU...`) for core's system-account connection in account `SYS`. |
| `nats-callout-authorization.conf` | Runtime Secret | Top-level broker `authorization: {auth_callout: ...}` configuration fragment with the derived public keys. |
| `nats-callout-accounts.conf` | Runtime Secret | Broker `SYS` and `AUTH` account definitions with the derived public user keys and permissions. |

Signing key ownership follows the issuer Secret:

- **Generator-owned signing set** (non-hosted install with
  `certs.generator.enabled: true` and `certs.issuerSecretName` resolving to the
  same Secret as `certs.runtimeSecretName`): on upgrade (even with enforcement
  disabled), if all five `nats-callout-*` entries are absent, the pre-upgrade
  hook generates the three seeds and both matching fragments together. If all
  three seeds are present, it preserves them and rebuilds only missing or stale
  fragments. If any `nats-callout-*` entry remains while a seed is missing
  (including fragments alone), the hook fails without writing, names each
  missing seed, and directs the operator to restore the missing seeds or
  deliberately remove every remaining `nats-callout-*` entry to provision a new
  set.
- **Supplier-owned signing set** (every other configuration: distinct
  `certs.issuerSecretName`, hosted installs, or self-managed installs with
  `certs.generator.enabled: false`): any running generator leaves all five
  entries untouched, and the Secret supplier must populate the three `.seed`
  keys in the issuer Secret and both matching `.conf` fragments in the runtime
  Secret before enabling enforcement. In a self-managed install where
  `certs.generator.enabled: false` and `certs.issuerSecretName` is unset or
  equal to `certs.runtimeSecretName` (a shared Secret), the Secret supplier must
  populate all five `nats-callout-*` entries in that shared Secret before
  enabling enforcement.

With `nats.certificateAuthorization.enabled: false`, the chart omits both the
core seed projection and the NATS fragment projections.

### 3. Enable enforcement

Set `nats.certificateAuthorization.enabled: true` and upgrade. For edge leaf
connections, also set `nats.leafnodes.enabled: true` and configure
`hostedRuntime.publicEndpoints.natsLeafHost` so web-ng receives
`SERVICERADAR_NATS_LEAF_UPSTREAM_URL` (the chart renders the `leafnodes`
listener only when both `nats.leafnodes.enabled` and
`nats.certificateAuthorization.enabled` are `true`, and `nats.pem` must carry
the configured public leaf host SAN).

Note these chart value rules:

- `nats.certificateAuthorization.infrastructureAdopted`, `issuerPublicKey`,
  `authUserPublicKey`, and `systemUserPublicKey` were removed. After upgrading,
  the chart ignores public keys pasted into those values from a bootstrap
  record; core reads the mounted seeds in `SERVICERADAR_NATS_CALLOUT_SEEDS_DIR`
  (`/etc/serviceradar/nats-callout-seeds`), ignores any stored database signing
  record, and logs once that the stored record is unused.
- The chart refuses `nats.certificateAuthorization.enabled: true` together with
  `certs.regenerator.enabled: true`, because `cert-regenerator-job` issues a
  new root CA that adopted components cannot rotate onto.

### 4. Verify readiness and troubleshoot

Run `serviceradar-cli edge hub status` or query
`GET /api/admin/managed-components/bootstrap` and verify that `data.nats`
reports `auth_mode: "static_mtls"`, `ready: true`, and `reason: null`, and that
`data.hub` reports `enforcement_configured: true`, `authorizer_answering: true`,
and expected `chart_identities` coverage (plus `leaf_listener: true` and
`leaf_upstream_url: true` when onboarding edge leaves).

Common failure modes and checks:

- **`signing_keys_not_provisioned`**: Core mounts the three `.seed` keys from
  the issuer Secret with `optional: true`, so core starts even if a seed is
  missing or unreadable and reports `reason: "signing_keys_not_provisioned"` in
  `data.nats` on `GET /api/admin/managed-components/bootstrap` (even during a
  broker outage or when a broker fragment is also missing). Provision or restore
  the missing seed(s) in the issuer Secret (or delete all remaining
  `nats-callout-*` entries if using the generator to mint a fresh set).
- **NATS pod mount failures for `nats-callout-*.conf`**: NATS mounts
  `nats-callout-authorization.conf` and `nats-callout-accounts.conf` as required
  Secret items when enforcement is enabled. If either `.conf` key is missing,
  Kubernetes blocks the affected NATS pod from mounting its certificate volume
  and starting, naming the missing key in pod events regardless of core's
  mounted seeds. An empty fragment exits the NATS startup check before starting
  `nats-server`. Inspect pod mount errors and events with:

  ```bash
  kubectl describe pod -n <namespace> <nats-pod>
  kubectl get events -n <namespace> --field-selector involvedObject.name=<nats-pod> --sort-by=.lastTimestamp
  ```

- **Surviving broker vs. disconnected authorizer**: In a multi-replica NATS
  StatefulSet, if one broker pod fails to start due to a missing `.conf`
  fragment while core has all three seeds mounted and continues answering
  through a surviving broker, `data.nats.ready` remains `true`. If all three
  seeds are mounted on core but core loses its authorizer connection to NATS,
  `data.nats.ready` becomes `false` with the readiness reason (such as
  `connecting`, `auth_connection_unavailable`, `auth_subscription_failed`, or
  `authorizer_unavailable`); inspect NATS pod events and core health before
  retrying.

### 5. Disable enforcement

To turn enforcement back off, set `nats.certificateAuthorization.enabled: false`
and upgrade. The chart omits the `auth_callout` and `AUTH` includes from
`nats-server.conf` (restoring static certificate mapping and disabling the
leafnodes listener) and omits the signing projections from core and NATS.
Existing adopted components, recorded certificates, and
`runtime-cert-rotation.json` records remain intact, and core's inventory
projection continues to follow `certs.generator.enabled` and
`certs.inventoryCertificates`.

### Hub status API and CLI preflight

- **Hub readiness payload (`GET /api/admin/managed-components/bootstrap`)**:
  includes `data.hub` with `enforcement_configured`, `authorizer_answering`
  (with `authorizer_reason` when false, such as `signing_keys_not_provisioned`,
  `connecting`, or `authorizer_unavailable`), `signing_keys_provisioned`,
  `chart_identities` (total, adopted, `legacy_certificates`, uncovered
  identities with reasons and optional `rotation_reason`, and `unlisted` files;
  or `null` when inventory reconciliation has not completed, failed, or is
  unavailable), `leaf_listener`, and `leaf_upstream_url`. The cluster-only
  control-plane runtime listener also exposes `GET /v1/hub/readiness` returning
  `{"schema_version": 1, "hub": ...}` (`503` with
  `{"status": "core_unavailable"}` when core is unavailable).
- **`serviceradar-cli edge hub status`**: reads `data.hub` under the CLI's
  existing `edge.manage` scope and prints hub readiness along with a warning
  and reason for each uncovered chart identity.
- **`serviceradar-cli edge install leaf` preflight stop checks**: before
  installing packages or writing host files, `edge install leaf` evaluates
  `data.hub` in this exact order and stops on the first failing check, naming
  the cause and its resolver:
  1. Hub status missing or unreadable -> wait and retry, and check core's health.
  2. Enforcement not configured (`enforcement_configured` is not `true`) ->
     enable `nats.certificateAuthorization.enabled`.
  3. Enforcement configured, but any of the three mounted seeds is absent
     (`signing_keys_not_provisioned`) -> provision the missing signing seeds in
     the issuer Secret (or remove remaining `nats-callout-*` entries for
     generator-owned provisioning).
  4. Enforcement configured, but the authorizer is otherwise not answering
     (`authorizer_answering` is not `true`) -> check NATS and core health, then
     retry (showing the readiness reason).
  5. Leaf listener not configured (`leaf_listener` is not `true`) -> enable
     `nats.leafnodes.enabled`.
  6. Leaf upstream URL not configured (`leaf_upstream_url` is not `true`) -> set
     `hostedRuntime.publicEndpoints.natsLeafHost`.

  In a multi-replica NATS cluster where core has all three seeds mounted and
  continues answering through a surviving broker, an otherwise ready hub stays
  ready and leaf installation proceeds; if core loses its authorizer
  connection, `authorizer_answering` becomes `false` and `edge install leaf`
  stops before host changes. `chart_identities` coverage warnings remain
  advisory only and do not block leaf installation.

## Non-chart bootstrap and `serviceradar-cli edge install`

For installations without the Helm chart,
`POST /api/admin/nats/certificate-authorization/bootstrap` stores signing
material only for the deployment account (`:nats_account_name`). A missing or
unusable deployment account returns `nats_account_unconfigured`. A different
requested name returns `nats_account_mismatch`. An existing record for another
account stays in place. When no signing seed directory is configured, core uses
the stored record. Readiness then includes the stored account name and stays
unready while that name disagrees with the deployment account. An authorization
request in that state is answered with `nats_account_mismatch` and no user JWT,
and the session is not remembered. A matching account is still decided from the
certificate policy. On chart installs with mounted seeds, core ignores this
stored database record.

`serviceradar-cli edge install collector` continues when the hub authorizer is
disconnected (`static_mtls` with an empty reason, or with reason `connecting`,
`auth_connection_unavailable`, `auth_subscription_failed`,
`policy_unavailable`, `not_configured`, `authorizer_unavailable`, or
`core_unavailable`). An unset mode continues while the hub is not configured.
`static_mtls` still requires the deployment account name. The command does not
create the account or require a JWT account seed. It stops before package
installation for `jwt_account_signer_unconfigured`, `unsupported_auth_mode`,
`nats_account_mismatch`, `signing_keys_not_provisioned`, any other
authentication mode, and `nats.ready` without `static_mtls`.
`serviceradar-cli edge install leaf` requires all six ordered `data.hub`
preflight checks above to pass before making any host change (with
`chart_identities` coverage remaining advisory only).

When core uses a stored `operator_jwt` configuration, it reports readiness
reason `jwt_account_signer_unconfigured`. The authorizer does not open a broker
connection and does not create an account signer. `edge install` stops before
package installation because that readiness is false.

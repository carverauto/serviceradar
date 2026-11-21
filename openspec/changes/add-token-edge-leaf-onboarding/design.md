## Context

From the tree at the time of writing (nothing here was run):

- `EdgeSite :create` creates a `NatsLeafServer` and enqueues
  `ProvisionLeafWorker`, which asks the agent gateway for two certificates
  with server-generated keys (`edge/edge_site.ex:236-254`,
  `edge/workers/provision_leaf_worker.ex`, `edge/nats_leaf_certificate_issuer.ex:44-68`).
  No managed component or certificate record is written for them.
- `NatsLeafServer :connect` and `:disconnect` have no callers. `EdgeSite`
  becomes active only through them.
- The hub address copied into a new site comes from
  `:nats_leaf_upstream_url`, defaulting to a hard-coded hosted hostname
  (`edge/edge_site.ex:238-243`).
- The site page's primary button builds the bundle
  (`live/admin/edge_sites_live/show.ex:67-86`); it is offered for managed
  sites too, and both `setup.sh` and the managed install write
  `/etc/nats/nats-server.conf`.
- `edge install leaf` (`js/cli/src/edge/install.ts:119-255`) needs an operator
  bearer token with the edge scope and performs: read the site, read hub
  bootstrap, install the `serviceradar-nats` package, pin the policy key,
  register the managed component, write the leaf configuration, run the agent
  updater's local NATS bootstrap, request certificate rotation, wait for
  activation. Registration still reads the leaf server row for the hub
  address.
- The agent onboarding token (`edgepkg-v3`) is an Ed25519-signed envelope
  around a package id, a download secret and a partition; the package row
  holds the secret's hash, an expiry and a single-use consume transition, and
  every redemption attempt is written as a security event
  (`edge/onboarding_token.ex`, `edge/onboarding_packages.ex:208-251`,
  `controllers/api/edge_controller.ex:472-545`). The package's component type
  is limited to gateway, agent, checker and sync, and it has no site
  reference.
- A managed leaf's hub grant is publish and subscribe `>`
  (`edge/managed_component_nats_permissions.ex:4`).
- The hub authorizer scans hub connections, including leaf connections, with
  their certificate fingerprints on each tick
  (`nats/managed_certificate_authorization.ex:388-492`).

## Goals / Non-Goals

- Goals: one deployment path; one token from the UI; no operator login on the
  edge host; no private key leaves the host; truthful status; least privilege
  for the leaf on the hub.
- Non-Goals: collectors; changing agent onboarding; a separate NATS account
  per site; opening the hub's leaf port to the network.

## Decisions

### Decision 1: Remove the bundle path

Keeping it would leave a button that produces a leaf the hub refuses, a second
writer of the leaf's configuration file, and private keys generated and stored
on the server. The managed path already replaces every part of it. Removal
covers the UI button, `POST /api/admin/edge-sites/:id/bundle`,
`edge site bundle`, `EdgeSiteBundles`, `EdgeSiteBundleGenerator`, the
`setup.sh` and README generation, `NatsLeafCertificateIssuer` and
`NatsLeafCredentials`, and the encrypted key attributes on the leaf server
row once nothing reads them.

`ProvisionLeafWorker` exists to issue those certificates. Without them a new
site needs no background provisioning, which also removes the "provisioning
forever when no gateway is reachable" state. The direct-leaf identity block
that only the bundle configuration rendered is carried by the managed
configuration instead, or removed with its unreachable eligibility check; see
task 1.2.

### Decision 2: A leaf onboarding token on the existing package machinery

A leaf token is an onboarding package of a new component type, `nats_leaf`,
with a reference to the edge site. Reused from the agent onboarding package:
the `edgepkg-v3` envelope and signing key, the hashed secret with its expiry
(24 hours by default) on the package row, revoke, the package events and the
security events.

Not reused: the `:deliver` transition and its single-use consume
(`edge/onboarding_packages.ex:217-232`), the join token and certificate
bundle, the existing token-gated download and bundle routes
(`POST /api/admin/edge-packages/:id/download` and
`POST /api/edge-packages/:id/bundle`), and the operator-role token actor
those routes mint (`controllers/api/edge_controller.ex:522-530`). Left as they
are, those routes would spend a leaf token on first call and turn it into an
operator for every site. So:

- the existing download and bundle routes refuse a package whose component
  type is `nats_leaf` and record a security event;
- leaf redemption has its own route and its own actor, scoped to one site and
  one registered component, able to do only the calls listed below;
- a leaf package has its own transitions: `:bind` moves `:issued` to `:bound`
  and stores the agent id at the first successful registration, and
  `:complete` moves `:bound` to the existing `:activated` status when the leaf
  is reported active. `:revoke` and `:expire` apply from `:issued` or
  `:bound`. The only status added is `:bound`, which joins the status
  constraint (`edge/onboarding_package.ex:336`). A leaf package never enters
  `:delivered`;
- a leaf package stores no join token and no bundle.

Expiry is enforced at redemption. Every presentation of a leaf token compares
the package's token expiry timestamp (`download_token_expires_at`) with the
current time, whatever the status (`:issued` or `:bound`), and refuses and
records an expired token even if no background job has run. Redemption is not
gated on the `:active` read or `is_usable`
(`edge/onboarding_package.ex:120-122`, `:503`), which check status only. The
hourly expiry job is bookkeeping: its `:needs_expiration` selection
(`edge/onboarding_package.ex:143-146`) requires `:issued` and an expired join
token, so it is extended to also select `nats_leaf` packages in `:issued` or
`:bound` by the token expiry timestamp alone, since a leaf package has no join
token. Their stored status then becomes `:expired`.

What differs is what redemption does. An agent package delivers a join token
and a certificate bundle. A leaf package delivers no key material. Redeeming
it authorizes exactly the calls the CLI makes today with an operator login,
for that one site:

1. read the site and hub readiness;
2. register the leaf as a managed component on the enrolled host agent the
   CLI names;
3. request certificate issuance and read that component's status until it is
   active.

The token is bound to a host on first use, not spent on first use. Until
step 2 succeeds a failed attempt (hub not ready, host not enrolled) can be
retried with the same token. Before any registration has succeeded there is
no bound identity, and the named agent only has to be enrolled with a live
gateway session. When a registration first succeeds, core stores on the
onboarding package the agent id it registered the leaf on; that stored value
is the bound identity. Every later presentation is compared with the stored
value. The same agent id may resume an interrupted install until the token
expires (checked on every presentation, above) or is revoked: registration is idempotent for the same site and agent
id, and the token authorizes requesting issuance for, and reading the status
of, the component it registered. Any other agent id is refused and recorded
as a security event, including a host whose agent identity changed after a
reinstall, which needs a new token. When the leaf is reported active the
package takes the `:complete` transition, and the token authorizes nothing
further.

Alternatives considered:
- A short-lived operator bearer token scoped to the edge routes. Rejected: it
  would authorize every site and every edge package, on a host we are only
  just beginning to trust.
- A new token format and table. Rejected: the envelope, storage and audit
  already exist and are tested.

### Decision 3: Bind to the host through its enrolled agent

The token does not name a host, because the operator issuing it usually does
not know the agent's identifier. The CLI reads the host's enrolled agent
identity as it does today and sends it; core accepts the registration only if
that agent exists, is enrolled and has a live authenticated gateway session.
When the first registration succeeds, core stores that agent id on the
onboarding package as the bound identity (Decision 2), and every later
presentation must name the stored agent id. The CLI's issuance request,
authorized by the token, makes that agent generate the keys on the host and
send the signing requests over its session. A token replayed from a machine
with no enrolled agent can register nothing, and one naming any agent id
other than the stored one is refused.

### Decision 4: Status comes from the hub

On each scan the authorizer already has the fingerprints of connected leaf
sessions. It marks the leaf server connected when its recorded certificate is
present. A scan tick does not yield a complete listing: connection reads are
paged with offsets carried across ticks, and a failed read returns an empty
list (`nats/managed_certificate_authorization.ex:508-531`, `:599-612`). A leaf
is therefore marked disconnected only after a successful, complete pass over
every server's connection pages shows its certificate absent; a failed or
partial read leaves the last known status in place. The page stops inferring
status from provisioning state.

The existing state machines cannot carry this as they stand, so they change:

- `NatsLeafServer`: a new row is `:pending`, and `:connect` is allowed today
  only from `:provisioned` or `:disconnected`
  (`edge/nats_leaf_server.ex:62`). The only way out of `:pending` is
  `:provision`, performed by the `ProvisionLeafWorker` this change removes.
  The `:provisioned` state is dropped from the state machine, with the
  `:provision` and `:reprovision` transitions: the states are `:pending`,
  `:connected` and `:disconnected`. `:connect` is legal from `:pending` and
  from `:disconnected`: the first hub session moves `:pending` to
  `:connected`, and a returning session moves `:disconnected` back to
  `:connected`. Existing rows in `:provisioned` are migrated to `:pending`.
- `EdgeSite`: `update_edge_site_status` always calls `:activate` for a live
  leaf (`edge/nats_leaf_server.ex:424-428`), and `:activate` runs only from
  `:pending` (`edge/edge_site.ex:60`). A connect for a site in `:pending`
  takes `:activate`; a connect for a site in `:offline` takes `:come_online`
  (`edge/edge_site.ex:62`); a disconnect for a site in `:active` takes
  `:go_offline`.

### Decision 5: The hub address is configured or the site cannot be created

The hard-coded hosted default is removed. With no configured leaf address the
create action fails with a message naming the setting, the page explains it
before the form is submitted, and the API returns the same reason. An existing
site's address is refreshed from configuration when its token is issued, so a
site created before the address was corrected is not stuck with the old one.

### Decision 6: A narrow hub grant for the leaf

The leaf's grant lists what an edge site needs and nothing else. The list is
built in task 1.3 from the subjects edge components actually use, and proven
by a broker test in which a leaf with that grant carries an edge collector's
traffic and is refused a subject outside it. It must cover, at least: the
data subjects edge collectors and agents publish, the JetStream API and
delivery subjects for the streams they publish to, read access to the rule
bundle bucket through the hub's JetStream domain (the path
`refactor-collectors-onto-shared-ingest-pipeline` relies on), and reply
subjects. It must not cover agent configuration subjects of other agents,
internal log subjects or the system account.

A separate account per site was considered and deferred: JetStream across
accounts needs an import and export for every stream and API subject the edge
uses, and it would make the rule bucket read path considerably harder. A
grant in the existing account closes the exposure now.

## Risks / Trade-offs

- **Removing the bundle path breaks any install using it.** By the analysis
  above no such leaf can be connected to a chart hub; a hosted leaf could not
  either, because the hosted hub never enabled authorization. Task 1.1 checks
  live deployments for edge sites before removal.
- **The narrow grant can be too narrow.** Mitigated by building it from
  observed subjects and by the broker test; a refused subject is visible in
  the broker log and in the connection's status.
- **The bound agent id is named, not proven.** The agent id is named by the
  CLI, not proven by it, so a token holder can direct the first install at
  any enrolled host with a live gateway session. That host's own agent
  performs the install and no key is returned to the presenter, and the token
  still deploys at most one leaf for one site.
- **Status depends on core's authorizer being connected.** When it is not,
  the page shows status as unknown, not as disconnected.

## Migration Plan

1. Token issue and redemption, CLI `--token`, status, the hub address check
   and the narrow grant ship together; the bundle path is removed in the same
   release, since the two cannot be offered side by side safely.
2. Existing sites keep their rows; unused key attributes are dropped by a
   migration after the code that read them is gone.
3. `edge install leaf` keeps accepting an operator login for automation.

## Open Questions

- Whether the direct-leaf identity feature (assignment-scoped certificates
  authorized on the leaf) is kept. It is live on the write path: every add-on
  assignment create and update runs `SetDirectLeafAccess`
  (`plugins/addon_assignment.ex:122`, `:134`), and `:issue_direct_access`
  stores a gateway-issued certificate and private key
  (`plugins/addon_assignment.ex:166`, `issue_direct_leaf_access.ex:24-53`); the
  mix task is one caller of that action. What is unreachable is its
  eligibility gate, which requires an `:active` site and a `:connected` leaf
  (`direct_leaf_eligibility.ex:62-70`) that nothing sets today. Task 1.2
  leaves the keep-or-remove choice with the owner.

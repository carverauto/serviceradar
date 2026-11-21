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
with a reference to the edge site. Everything else is reused unchanged: the
`edgepkg-v3` envelope and signing key, the hashed secret, expiry (24 hours by
default), the single-use consume transition, revoke, the package events and
the security events.

What differs is what redemption does. An agent package delivers a join token
and a certificate bundle. A leaf package delivers no key material. Redeeming
it authorizes exactly the calls the CLI makes today with an operator login,
for that one site:

1. read the site and hub readiness;
2. register the leaf as a managed component on the enrolled host agent the
   CLI names;
3. request certificate issuance and read that component's status until it is
   active.

The token is consumed by step 2 succeeding. Until then a failed attempt (hub
not ready, host not enrolled) can be retried with the same token. After it,
the token is spent and the component's own status calls are authorized by the
host agent's enrolled identity, which the CLI already reads from the host.

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
Certificates are then requested by that agent over its session. A token
replayed from a machine with no enrolled agent can register nothing.

The issue dialog may optionally pin a host agent. When it does, redemption
from any other agent is refused.

### Decision 4: Status comes from the hub

On each scan the authorizer already has the fingerprints of connected leaf
sessions. It marks the leaf server connected when its recorded certificate is
present and disconnected when it has been absent for a full scan interval, and
the existing transitions set the site active or offline. The page stops
inferring status from provisioning state.

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
  authorized on the leaf, managed today only by a mix task) is kept. Its
  eligibility check requires states nothing currently sets, so it has not
  been reachable. Task 1.2 decides with the owner.

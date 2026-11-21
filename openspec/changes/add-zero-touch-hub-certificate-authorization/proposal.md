# Change: Turn on hub certificate authorization with one enforcement setting

## Why

An edge NATS leaf can only connect to a chart-installed hub after the hub's
certificate authorization (the NATS auth callout answered by core) is enabled.
The chart renders the leaf listener only with the callout, because NATS places
a leaf with no authorization block in the global account
(`helm/serviceradar/templates/nats.yaml:187-204`).

Enabling the callout today is a hand procedure with three parts
(`docs/managed-component-certificates.md`):

1. **Adopt every existing NATS client.** One `POST
   /api/admin/managed-components/adopt` per component, each with that
   component's public certificate and a copy of its static permissions. There
   is no bulk call and no list call. Neither core nor web-ng can read another
   component's certificate, so the operator has to extract each one from the
   runtime Secret, which also holds the CA keys by default on self-managed installs.
2. **Create the signing keys.** `POST
   /api/admin/nats/certificate-authorization/bootstrap` returns three public
   nkeys.
3. **Edit Helm values.** Paste the three nkeys, set
   `certificateAuthorization.enabled`, and set `infrastructureAdopted: true`,
   which is a promise the chart cannot check.

A client missed in step 1 is refused by the broker as soon as step 3 rolls
out. Regeneration is already handled for a certificate that was adopted: the
generator writes `runtime-cert-rotation.json` and
`ServiceRadar.Edge.RuntimeCertificateRotation` records each reissued
certificate as the successor of the adopted one, from the core migrations hook
before workloads roll. That path skips a certificate that was never adopted.
What is missing is the first adoption of the chart's certificates.
No CLI command covers steps 1 and 2; their routes are outside the CLI's edge
scope on purpose. The hosted control plane enables the leaf port for tenants
but never the callout, so a hosted tenant has the port and no listener.

The result is that leaf onboarding, which the CLI otherwise does in two
commands, depends on a risky manual hub procedure that has not been run on a
chart install. The owner asked for one-touch provisioning that is secure.

## What Changes

The hand steps are removed rather than wrapped in CLI commands. A CLI command
that extracts certificates from the cluster would need Kubernetes access to
the runtime Secret, exposing every component's private key to the caller.

- **Core is given the public certificates of the chart's NATS clients.** They
  are already in the runtime certificate Secret. Core mounts the public
  certificate file of each chart identity from that Secret by explicit list,
  with no key, the way it already mounts `runtime-cert-rotation.json`. No new
  object is created and the certificate generator's permissions do not change. A chart identity is a subject for which the generator issues
  a distinct NATS client certificate. The alias users `serviceradar-flowgger`,
  `serviceradar-otel` and `serviceradar-netflow-collector`, whose certificate
  files are copies of another identity's certificate, and the `O=ServiceRadar`
  user are not chart identities: they are not counted in adoption coverage and
  never block a leaf install.
- **Core adopts chart identities from that inventory by itself.** A
  certificate qualifies when it chains to the deployment root, is valid, is
  not revoked, and its subject is a chart identity present in the static
  users file. Adoption is one ordered rule: first, if any infrastructure
  certificate row lacks a stored subject, the inventory adopts nothing and
  reports that state with the remedy; otherwise, for each qualifying
  certificate whose subject is not held (no recorded certificate on any
  component carries it, revoked or not), core creates the component and
  records the certificate. This is the first
  adoption the existing rotation record lacks, and it complements that record
  rather than replacing it. To make that check possible, recorded
  certificates gain a stored subject. When the subject is held, the inventory
  writes nothing: replacing an adopted certificate stays solely with the
  existing rotation record, unchanged, so revocation is unchanged. Hand
  adoption remains, unchanged, for clients the chart does not define.
- **Signing key provisioning follows issuer Secret ownership.** When the
  issuer and runtime Secret names match, the generator provisions all five
  signing entries together only when none exist. On upgrade or rerun, it
  preserves all three existing seeds and uses them to repair missing or stale
  fragments. If any entry remains but a seed is missing, the job fails without
  writing and names the seeds to restore. The operator can instead deliberately
  remove the remaining signing entries to provision a new set. For a distinct issuer, its owner provisions the seeds
  in the issuer Secret and the fragments in the runtime Secret. The generator
  leaves both sets alone and keeps its existing Role. Only with enforcement
  on does core project the seeds and NATS project the fragments. The chart
  documents the fixed signing projections. If core lacks any mounted seed,
  hub status reports `signing keys not provisioned` and leaf install stops, even if core
  also lost its broker connection.
  A missing broker fragment blocks startup of the affected NATS pod regardless of core's seeds.
  Kubernetes names the missing key in its mount error. An otherwise ready
  hub stays ready and leaf install proceeds while core answers through a
  surviving broker. If all seeds are present but core loses its authorizer connection, hub status
  reports the authorizer is not answering and leaf install stops.
  Core uses the mounted seeds and logs once if a stored signing record is
  unused. Installs without a chart retain the bootstrap API and stored keys.
- **One value turns enforcement on:** `nats.certificateAuthorization.enabled`.
  `infrastructureAdopted`, `issuerPublicKey`, `authUserPublicKey` and
  `systemUserPublicKey` are removed. **BREAKING** for a values file that sets
  them; none is known to. Once the signing seeds are present and hub
  status reports every chart identity adopted, enforcement needs no further
  manual step for those identities, however their certificates came to
  be recorded. Those clients can reconnect while at least one broker is serving and core's authorizer is connected. A chart identity that hub status reports as not adopted stays
  refused after enforcement is on until its reported reason is resolved (for
  example rows without a subject blocking new adoption, a refused or skipped
  rotation, a revoked subject, or a failed qualification check); hub status
  shows it with its reason before enforcement is turned on.
- **The hub reports whether it can accept a leaf**: core reports whether
  enforcement is configured and whether its authorizer is answering, how many chart
  identities are adopted and which are not and whether the hub broker has the
  leaf listener; web-ng reports whether the leaf upstream URL is configured;
  the CLI shows both: `serviceradar-cli edge hub status`.
- **`edge install leaf` stops before changing the host when the hub cannot
  accept the leaf**, naming the cause and what resolves it: the enforcement
  value, provisioning missing seeds, checking NATS and core health, `nats.leafnodes.enabled`, the leaf
  host setting, or the per-subject reason a chart identity is not adopted. It
  also stops when the hub status is missing or unreadable. Today it
  continues and the leaf never connects.

## Decision needed from the owner

Whether enforcement is on by default. See design.md, Decision 4. The proposal
as written keeps it off by default for this release and has the hosted control
plane set it for tenants, because with enforcement on every new NATS
connection depends on core and its database being up.

## Impact

- Affected specs: new capability `hub-certificate-authorization`.
- Related active changes: `add-managed-component-certificates` (task 3.4,
  adoption of existing installations, and 4.1, readiness errors, are delivered
  by this change for chart identities) and `add-hosted-edge-leaf-connectivity`.
- Affected code: `helm/serviceradar` (generator script and job, `nats.yaml`,
  `core.yaml`, values, chart tests), `elixir/serviceradar_core` NATS
  certificate authorization modules, the web-ng managed component controller,
  `js/cli` edge commands, `docs/managed-component-certificates.md`.
- Follow-up outside this repository: `serviceradar-control` supplies the
  public inventory certificates and both broker fragments in the hosted runtime
  certificate Secret and the three seeds in the hosted issuer Secret. It
  sets the inventory certificate list, which defaults to empty in hosted mode.
- Not in scope: Docker Compose and packaged hubs, a dedicated edge account for
  leaf subject isolation, and opening the leaf port to the outside, which
  stays an operator or control-plane action.

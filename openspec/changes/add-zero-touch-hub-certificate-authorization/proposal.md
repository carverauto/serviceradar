# Change: Turn on hub certificate authorization with one setting and no hand steps

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
   runtime Secret, which also holds the CA keys.
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
the Secret that holds the CA keys, which is the opposite of secure.

- **The chart publishes a public inventory of its own NATS client
  certificates.** The certificate generator already holds every certificate.
  It writes a ConfigMap with the public certificate of each chart identity and
  no key material, as it already publishes public certificates in
  `runtime-cert-rotation.json`. Core mounts it next to the static users file it
  already reads. A chart identity is a subject for which the generator issues
  a distinct NATS client certificate. The alias users `serviceradar-flowgger`,
  `serviceradar-otel` and `serviceradar-netflow-collector`, whose certificate
  files are copies of another identity's certificate, and the `O=ServiceRadar`
  user are not chart identities: they are not counted in adoption coverage and
  never block a leaf install.
- **Core adopts chart identities from that inventory by itself.** A
  certificate is adopted when it chains to the deployment root, is valid, and
  its subject is a chart identity. This is the first adoption the existing
  rotation record lacks; it complements that record and does not replace it.
  Core keeps reconciling, so a chart certificate that the rotation record did
  not adopt is still adopted without an operator. Hand adoption remains,
  unchanged, for clients the chart does not define.
- **The chart owns the callout signing keys.** The generator creates the three
  nkeys once, stores the seeds in a Secret mounted only into core, and writes
  the public half into a configuration fragment the broker includes. Nothing
  is pasted into values. The existing API bootstrap stays for installs that
  have no chart.
- **One value turns enforcement on:** `nats.certificateAuthorization.enabled`.
  `infrastructureAdopted`, `issuerPublicKey`, `authUserPublicKey` and
  `systemUserPublicKey` are removed. **BREAKING** for a values file that sets
  them; none is known to.
- **Core reports whether the hub can accept a leaf**, including how many chart
  identities are adopted and which are not, whether the hub broker has the
  leaf listener, and whether the leaf upstream URL is configured, and the CLI
  shows it: `serviceradar-cli edge hub status`.
- **`edge install leaf` stops before changing the host when the hub cannot
  accept the leaf**, with the reason and the one setting to change. Today it
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
  inventory and the signing Secret for hosted tenants, as it already supplies
  the certificate Secret, and sets the one value. Until it does, hosted
  tenants are unchanged.
- Not in scope: Docker Compose and packaged hubs, a dedicated edge account for
  leaf subject isolation, and opening the leaf port to the outside, which
  stays an operator or control-plane action.

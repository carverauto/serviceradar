## Context

Facts this design rests on, from the tree at the time of writing:

- The broker configuration is a shell heredoc in the NATS container arguments
  (`helm/serviceradar/templates/nats.yaml:153-268`). There is no included file
  and no reload path, so any change to it is a StatefulSet rollout.
- The callout needs three public nkeys in that configuration: the issuer
  account key, and the user keys of the two connections core's authorizer
  opens (`AUTH` and `SYS`).
- Core's authorizer (`ServiceRadar.NATS.ManagedCertificateAuthorization`)
  connects with those nkey users, so it does not itself pass through the
  callout. It admits a certificate when the fingerprint is adopted, unrevoked
  and has a stored grant; for a chart identity it then applies the chart's
  static permission block from the static users file, not the stored grant.
- The certificate generator job creates every certificate into one Secret and
  regenerates all of them when the layout version changes or a required file
  is missing. Each pod mounts only its own certificate and `root.pem`. Core's
  Role cannot read Secrets or ConfigMaps.
- When the generator reissues certificates it writes
  `runtime-cert-rotation.json` (public certificates and the fingerprints they
  replace, no key material) into the runtime Secret.
  `ServiceRadar.Edge.RuntimeCertificateRotation` records each reissued
  certificate as the successor of an adopted predecessor, from the core
  migrations hook before workloads roll and again on a 30 second reconcile. A
  certificate whose predecessor was never adopted is skipped.
- Three static users (`serviceradar-flowgger`, `serviceradar-otel`,
  `serviceradar-netflow-collector`) have no certificate of their own; their
  files are copies of another identity's certificate. One static user,
  `O=ServiceRadar` (publish allow `>` with deny `logs.normalized.>`, subscribe
  allow `>`), matches no chart-generated certificate.
- `edge install leaf` proceeds when the hub authorizer is not connected.
- The address new edge-site leaves dial comes from
  `SERVICERADAR_NATS_LEAF_UPSTREAM_URL`, which the chart renders only when a
  leaf host is set. When it is unset the code falls back to a hard-coded
  hosted address.

A chart identity, for this capability, is a subject for which the generator
issues a distinct NATS client certificate. The three alias users and
`O=ServiceRadar` are not chart identities: they are not counted in adoption
coverage and never block the leaf install gate.

## Goals / Non-Goals

- Goals: no hand adoption of chart identities; no pasted keys; one setting;
  safe to turn on; survives certificate regeneration; the operator can see
  hub readiness before installing a leaf.
- Non-Goals: changing how host-enrolled components, leaves or collectors are
  admitted; changing revocation; Compose and packaged hubs; edge account
  isolation; network exposure of the leaf port.

## Decisions

### Decision 1: The chart publishes its public certificates; core adopts them

The generator writes a ConfigMap, `serviceradar-nats-infrastructure-certs`,
holding one PEM certificate per chart identity. It contains no private key and
not the CA key. Core mounts it read-only, like the static users ConfigMap. It
is a separate ConfigMap and not another key in the runtime Secret, from which
core mounts only its own items. The precedent for the generator publishing
public certificates is `runtime-cert-rotation.json`, a JSON document inside
the runtime Secret that holds public certificates and the fingerprints they
replaced, with no key material.

Core reconciles on the authorizer's existing tick. Each certificate in the
inventory is checked first:

- it chains to the deployment `root.pem` that core already mounts;
- it is within its validity period;
- its subject is a chart identity with a static user in the static users file;
- its fingerprint is not revoked.

A certificate that passes is then written in one of two ways:

- **Adopt.** When no component holds the subject, core adopts the certificate:
  it creates the component with the static grant for that subject.
- **Record a successor.** When a component already holds the subject and has
  an adopted predecessor, core records the certificate as that component's
  successor.

A certificate already recorded for its component needs no write.

The stored grant is the static block for that subject, so the record is
meaningful even if the static file is later unavailable.

Why this adds no trust: a certificate that chains to the root and carries a
chart subject is already accepted by the broker today through
`verify_and_map`. Writing the ConfigMap needs the same Kubernetes rights as
changing the chart's static users. Revocation still wins.

This provides the first adoption of chart certificates, which the existing
rotation record cannot: it only records successors of certificates already
adopted, and skips the rest. The inventory complements that record and does
not replace it. The rotation record keeps handling replacements of
already-adopted certificates before workloads roll; the inventory performs
first adoption and also covers a rotation the rotation record skipped.

Hand adoption (`POST /managed-components/adopt`) stays, unchanged, for clients
the chart does not define.

Alternatives considered:
- A CLI command that reads the runtime Secret and calls adopt per certificate.
  Rejected: it needs Kubernetes access to the Secret holding the CA keys, it
  is not available to a hosted tenant, and it does not survive regeneration.
- Give core RBAC to read the Secret. Rejected: core would hold every
  component's private key.
- Admit chart subjects by subject alone, with no adoption record. Rejected:
  the existing design keeps a per-fingerprint record so one certificate can be
  revoked and used certificates can be listed; this keeps that.

### Decision 2: The chart owns the signing keys

The generator creates the issuer, auth and system nkeys once and never
replaces existing ones. Seeds go into a Secret, `serviceradar-nats-callout`,
mounted only into core. The public keys go into a broker configuration
fragment in a ConfigMap, which the NATS pod mounts and the server
configuration includes.

Core reads the seeds from the mounted files when they are present. The
database record and `POST /nats/certificate-authorization/bootstrap` remain
for installs with no chart; when both exist and disagree, core reports
`signing_key_conflict` and does not answer authorization requests.

Why not keep the keys in the database and copy public keys into values: that
copy is the hand step being removed, and Helm cannot read the database at
render time.

Hosted tenants: the control plane creates the Secret and the fragment, as it
already creates the certificate Secret. That is a change in
`serviceradar-control`, tracked there.

### Decision 3: One value, and the unverifiable promise is removed

`nats.certificateAuthorization.enabled` is the only setting. The chart no
longer asks the operator to assert `infrastructureAdopted`; adoption is
automatic and its coverage is reported by core (Decision 5). The three key
values are removed.

This is a chart value, and the control plane renders the same value for
tenants, so it is not a Helm-only switch.

### Decision 4: Default (owner decision)

With enforcement on, a new NATS connection is admitted only if core's
authorizer answers, which needs core and its database. Established sessions
continue until their grant expires. The authorizer's own connections do not
depend on the callout, so the system can start from cold: NATS, then core,
then everything else connects or retries.

- **Off by default for this release (proposed).** Self-managed installs that
  do not use leaves keep today's behaviour. The hosted control plane turns it
  on for tenants. Demo runs with it on, so it is exercised continuously.
  Revisit the default once it has run there.
- **On by default.** Leaf onboarding needs nothing on the hub at all, but
  every install takes the availability dependency, including ones with no
  edge sites.

### Decision 5: Readiness is reported, and the CLI stops early

`GET /api/admin/managed-components/bootstrap` gains a `hub` object:

- `enforcement`: whether the authorizer is answering the broker;
- `chart_identities`: total, adopted, and the subjects not adopted with the
  reason for each;
- `leaf_listener`: whether the hub broker is configured with the leafnodes
  listener. Core cannot inspect the broker configuration, so the chart tells
  it through a setting rendered from `nats.leafnodes.enabled` together with
  enforcement, the same condition under which the chart renders the listener;
- `leaf_upstream_url`: whether the address new edge-site leaves dial is
  configured for this install (today `SERVICERADAR_NATS_LEAF_UPSTREAM_URL`).
  The hard-coded hosted fallback used when it is unset is not treated as
  configured.

`serviceradar-cli edge hub status` prints it. The route is already inside the
CLI's `edge.manage` scope; no scope is widened.

`edge install leaf` reads the same object before any host change and stops
when enforcement is off, when the leaf listener is not configured, when the
leaf upstream URL is not configured, or when a chart identity is not adopted,
naming which cause applies and the setting. It no longer
continues with "hub enforcement stays unconfirmed" for a leaf. Collector
installs keep today's behaviour.

### Decision 6: Turning it on is safe by construction

Core adopts chart identities whether or not enforcement is on. So the order
for an existing install is: upgrade to this release with the value off; check
`edge hub status` shows every chart identity adopted; turn the value on. If it
is turned on first anyway, clients are refused only until core's first
reconciliation, and they retry.

Certificate regeneration changes every fingerprint. A certificate that was
already adopted has its successor recorded by
`ServiceRadar.Edge.RuntimeCertificateRotation` from the core migrations hook
before workloads roll onto it, so its client is not refused. The inventory
changes in the same generator run and adopts any chart certificate that record
did not, on the authorizer's next tick. Only such a certificate is refused
until then, and its client retries; the window is bounded by the authorizer's
10 second tick (the rotation reconciler separately runs every 30 seconds).

## Risks / Trade-offs

- **Availability dependency on core** when enforcement is on. Stated in
  Decision 4. Established sessions are not affected by a core restart;
  connections and reconnections made during it wait.
- **The static user `O=ServiceRadar`** (publish allow `>` with deny
  `logs.normalized.>`, subscribe allow `>`) is not a chart identity: no
  chart-generated certificate carries that subject. A broker experiment on the
  chart configuration showed that only a certificate whose whole subject is
  exactly `O=ServiceRadar` maps to it; other unlisted subjects are refused.
  With enforcement on, such a certificate would not be in the inventory and
  would be refused. Task 1.2 checks live deployments for a holder before any
  behaviour changes, then removes the user or documents it.
- **Included broker configuration** is a new shape for the NATS pod. Covered
  by a broker test that boots nats-server from the rendered files, as the
  existing chart permission tests do.

## Migration Plan

1. Ship inventory, automatic adoption, generated keys and readiness with
   enforcement off. Nothing changes for running installs.
2. Turn enforcement on in demo; verify every client and a leaf.
3. Control plane change for hosted tenants.
4. Decide the default.

Rollback at any step is setting the value back to false.

## Open Questions

- Decision 4, the default.
- Whether the leaf listener should follow the same value, removing
  `nats.leafnodes.enabled` as a separate setting. Proposed: keep it separate,
  because it adds a Service port and is what the exposure settings key on.
  Either way, `leaf_listener` is rendered from the same condition the chart
  uses to render the listener.

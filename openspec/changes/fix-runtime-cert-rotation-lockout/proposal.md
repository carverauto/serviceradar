# Change: Keep adopted infrastructure admitted across chart certificate rotation

## Why

With the NATS certificate authorization callout enabled, core admits an adopted
infrastructure client only when the presented certificate's fingerprint is
recorded on its component. The chart's runtime certificate generator reissues
every runtime certificate, from the same root CA, whenever
`certs.runtimeLayoutVersion` changes. Nothing recorded the reissued
certificates, so the first layout change after adoption denied every platform
component (core, agent-gateway, web-ng, datasvc and the collectors) at the broker.
The deployment stayed locked out until an operator recorded each successor by
hand through `POST /api/admin/managed-components/:id/certificates`.

The flow-collector bootstrap pre-upgrade hook made it worse. It ran before the
certificate generator and retried a refused connection for longer than Helm's
timeout. Once the Secret held the new, unrecorded certificate, every later
upgrade blocked on that hook.

## What Changes

- The certificate generator writes `runtime-cert-rotation.json` into the runtime
  certificate Secret each time it reissues. For every reissued public
  certificate, it records the fingerprint that certificate replaced, its own
  fingerprint, and its PEM with the issuing root. It carries no key material.
- Core records each named replacement on the infrastructure component that
  holds the replaced fingerprint, at the same generation and with the same
  stored grant (`ComponentCertificateAuthority.record_rotated_infrastructure_successor/3`).
  It accepts a replacement only when the replaced certificate is recorded,
  unrevoked and current, and only when both certificates have the same issuer.
- The core migrations pre-upgrade hook records the replacements after the
  certificate generator and before any workload rolls. A core process repeats
  the recording whenever the mounted record changes.
- The flow-collector bootstrap hook runs after that recording (hook weight 0),
  and gives up after 600 seconds instead of outliving the upgrade.
- The chart refuses `nats.certificateAuthorization.enabled` together with
  `certs.regenerator.enabled`, because the regenerator reissues the root CA as
  well.

## Impact

- Affected specs: component-certificate-lifecycle
- Affected code: `elixir/serviceradar_core/lib/serviceradar/edge/`,
  `cluster/startup_migrations.ex`, the chart's certificate generator, core,
  core migrations and flow-collector bootstrap templates.
- No migration. Deployments with the callout disabled are unaffected. A
  rotation that happened before this change still needs its successors recorded
  by hand, because no record names their predecessors.

# Hosted Tenant Runtime Values

`values-tenant.yaml` is the baseline shape rendered by the ServiceRadar hosted
control plane for a dedicated tenant cluster. It is not a standalone customer
configuration file and it must not contain credentials, kubeconfigs, provider
resource IDs, or inline secrets.

The control plane owns hosted deployment facts such as tenant identity, public
hosts, contract version, pull-secret names, and plan entitlement defaults. The
chart owns runtime topology and behavior.

The control plane also creates `certs.runtimeSecretName` before Helm bootstrap.
Hosted values must keep both `certs.generator.enabled` and
`certs.regenerator.enabled` false. The chart treats a non-empty
`hostedRuntime.contractVersion` as authoritative hosted mode and suppresses
both in-cluster certificate-generation paths even if another values layer tries
to enable them.

## Validate The Baseline

From a chart source checkout, render the chart locally before changing
tenant-facing values:

```bash
helm template serviceradar ./helm/serviceradar \
  -n tenant-acme \
  -f helm/serviceradar/values-tenant.yaml >/tmp/serviceradar-tenant.yaml
```

Use this render check together with control-plane unit tests for
`ServiceRadarControl.Cloud.TenantRuntimeValues`. Helm accepts unknown values
silently, so a passing unit test alone does not prove the chart consumes a new
key. Do not layer `values-ha.yaml` for this validation; hosted bootstrap applies
one rendered tenant values file over the chart defaults, so `values-tenant.yaml`
must be HA-complete on its own.

## Exposure Model

The hosted baseline uses managed Gateway API for browser, edge-agent TCP, and
syslog ingress. Standard hosted deployments route the edge-agent gRPC and
artifact ports through the same managed Gateway data-plane Service as web
traffic, so they do not allocate a separate agent-gateway LoadBalancer.
NetFlow, sFlow, SNMP traps, and BMP use dedicated chart-managed LoadBalancer
services when the selected hosted tier enables those collectors. OTLP is routed
through Gateway API by default.

DNS and public certificate custody stay with the hosted control plane. The
tenant baseline disables `gatewayApi.dns.enabled` and
`logCollector.otlp.gateway.dns.enabled`, so the rendered routes do not rely on
tenant-cluster `external-dns`. It also leaves `gatewayApi.tls.clusterIssuer`
empty; hosted bootstrap must issue/sync the public TLS secret named by
`gatewayApi.tls.secretName` before the managed Gateway serves traffic.

External telemetry NetworkPolicy CIDR lists are intentionally empty in the
baseline. The hosted control plane's network-security sync writes tenant
trusted-CIDR allow-lists when that section lands.

## Backup Values

Day-one readiness requires the control plane to verify the first CNPG backup to
the tenant bucket before marking an environment ready. The tenant baseline
enables CNPG native Barman object-store backups through:

- `cnpg.backup.barmanObjectStore.destinationPath`
- `cnpg.backup.barmanObjectStore.endpointURL`
- `cnpg.backup.barmanObjectStore.s3Credentials.secretName`
- `cnpg.backup.scheduledBackup`

The values file carries only bucket destinations and Kubernetes secret
references. The control plane creates the per-tenant bucket and credential
secret before rendering the final values; credentials are never stored inline in
chart values.

The credential secret named by
`cnpg.backup.barmanObjectStore.s3Credentials.secretName` must already exist in
the release namespace before the CNPG `Cluster` starts. Hosted bootstrap must
therefore create the per-tenant bucket and write the object-storage access keys
into that Kubernetes secret before running `helm upgrade --install`; otherwise
WAL archiving and the immediate base backup cannot complete, and the control
plane's backup readiness gate will keep the environment out of service.

## Analytics Storage

The hosted baseline enables `analyticsStore.driver: hybrid` for
`timeseries_metrics`, with a 30-day hot read window. EventWriter persists a hot
Timescale copy and durable archive publication work. Historical queries use the
dedicated pg_duckdb head. The base OSS chart remains Timescale-only.

Before provisioning, the hosted control plane must replace the synthetic
`analyticsStore.pgDuckdb.s3` bucket, endpoint, region and Secret reference with
the tenant's analytics backend, and create that credential Secret. The analytics
bucket is separate from the CNPG backup bucket. The current table selection does
not enable NetFlow archival.

Changing this baseline does not update an already deployed control-plane values
renderer. Its output must carry these fields before hosted enablement is complete.
See [Analytics Store](../../docs/docs/analytics-store.md) for configuration,
retention, publication recovery, and query-routing behavior.

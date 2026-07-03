# Hosted Tenant Runtime Values

`values-tenant.yaml` is the baseline shape rendered by the ServiceRadar hosted
control plane for a dedicated tenant cluster. It is not a standalone customer
configuration file and it must not contain credentials, kubeconfigs, provider
resource IDs, or inline secrets.

The control plane owns hosted deployment facts such as tenant identity, public
hosts, contract version, pull-secret names, and plan entitlement defaults. The
chart owns runtime topology and behavior.

## Validate The Baseline

Render the chart locally before changing tenant-facing values:

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

The hosted baseline uses managed Gateway API for browser and syslog ingress.
NetFlow, sFlow, SNMP traps, and BMP use dedicated chart-managed LoadBalancer
services. OTLP is routed through Gateway API by default.

External telemetry NetworkPolicy CIDR lists are intentionally empty in the
baseline. The hosted control plane's network-security sync writes tenant
trusted-CIDR allow-lists when that section lands.

## Backup Values

Day-one readiness requires the control plane to verify the first CNPG backup to
the tenant bucket before marking an environment ready. The tenant baseline will
grow CNPG Barman/object-store values when the chart exposes that configuration.

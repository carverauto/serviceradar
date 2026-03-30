# Change: Harden Helm SPIRE Exposure and Attestation Defaults

## Why
When operators enable `spire.enabled=true`, the Helm chart still publishes the SPIRE server through a `LoadBalancer` by default and configures the SPIRE agent workload attestor with `skip_kubelet_verification = true`. Those defaults weaken the identity plane and expose sensitive control-plane surfaces unless operators notice and override them manually.

## What Changes
- Change the default SPIRE server service type from externally published `LoadBalancer` to internal-only service exposure.
- Stop exposing the SPIRE health port through the published SPIRE service by default.
- Remove the insecure `skip_kubelet_verification = true` default from the SPIRE agent workload attestor.
- Add chart documentation for the explicit operator escape hatches when external SPIRE publication or relaxed attestation is intentionally required.

## Impact
- Affected specs: `edge-architecture`
- Affected code: `helm/serviceradar/values.yaml`, `helm/serviceradar/templates/spire-server.yaml`, `helm/serviceradar/templates/spire-agent.yaml`, `helm/serviceradar/README.md`

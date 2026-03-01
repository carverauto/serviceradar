# Change: Add Demo Network Policy with Calico Deny Logging

## Why
The demo environment currently allows unrestricted egress, which creates a risk of unintended network discovery or credential exposure. Adding a controlled egress policy with deny logging reduces recon/exfil paths while keeping the demo functional.

## What Changes
- Add optional Helm chart support for Kubernetes `NetworkPolicy` egress controls scoped to ServiceRadar pods.
- Add optional Calico `NetworkPolicy` to log denied egress and enforce the same allow list.
- Enable these controls in `values-demo.yaml`.

## Impact
- Affected specs: `kubernetes-network-policy`
- Affected code: `helm/serviceradar/templates`, `helm/serviceradar/values*.yaml`, `helm/serviceradar/README.md`

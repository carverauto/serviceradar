# Change: Harden external-dns authority scope

## Why
The shipped `k8s/external-dns` deployment watches Services and Ingresses cluster-wide while holding authority for multiple Cloudflare-managed domains. Without namespace or annotation scoping, any actor who can create eligible resources elsewhere in the cluster can cause this controller to publish DNS records inside those zones.

## What Changes
- scope the external-dns controller to explicit ServiceRadar namespaces instead of the whole cluster
- require explicit external-dns hostname annotations before a resource is considered for publication
- align the Cloudflare secret documentation with the actual token-based deployment manifest

## Impact
- Affected specs: `edge-architecture`
- Affected code: `k8s/external-dns/base/*.yaml`, `k8s/external-dns/base/README.md`

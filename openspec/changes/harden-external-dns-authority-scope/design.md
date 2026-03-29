## Context
The repository ships a reusable `external-dns` deployment that manages several DNS zones through Cloudflare. Today it watches all Services and Ingresses in the cluster and does not require an annotation gate, so the controller's DNS authority is broader than the ServiceRadar-owned namespaces it is intended to serve.

## Goals / Non-Goals
- Goals:
  - limit external-dns to the ServiceRadar namespaces it is meant to manage
  - require explicit opt-in annotations before publishing DNS from a resource
  - fix the stale setup instructions so operators create the right Cloudflare token secret
- Non-Goals:
  - redesign the DNS topology
  - remove support for the existing managed zones
  - replace Cloudflare as the DNS provider

## Decisions
- Decision: add explicit namespace filters for the ServiceRadar-managed namespaces.
  - Why: this prevents unrelated namespaces from using the shared controller's DNS authority.
- Decision: add an annotation filter that only publishes records for resources carrying the external-dns hostname annotation.
  - Why: this turns DNS publication into an explicit per-resource opt-in instead of an implicit side effect of any Service or Ingress.
- Decision: keep the existing Cloudflare token secret model and update the README to match it.
  - Why: the deployment already expects a token secret, and the documentation should not encourage a mismatched legacy secret format.

## Risks / Trade-offs
- If a legitimate namespace is omitted from the namespace filter, its DNS records will stop reconciling.
  - Mitigation: document the intended namespaces clearly and keep the filter list easy to extend intentionally.
- Requiring an annotation filter may skip resources that rely on implicit hostname generation.
  - Mitigation: the ServiceRadar manifests already use explicit hostname annotations for managed ingress paths.

## Migration Plan
1. Add namespace and annotation filters to the external-dns deployment.
2. Update the setup README to describe the expected Cloudflare token secret shape and namespace list.
3. Render the Kustomize base to verify the controller still deploys cleanly.

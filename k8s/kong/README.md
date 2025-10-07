Kong Gateway on Kubernetes (DB-less with JWKS init)

This demo deploys Kong OSS in DB-less mode, no Postgres required. An initContainer fetches Core's JWKS and renders a fresh DB-less config at startup (protecting `/api/*`).

Resources
- `kong.yaml`: Kong Deployment + Service (proxy + admin), with JWKS initContainer

Usage
1) Deploy Kong:
   kubectl apply -f k8s/kong/kong.yaml

2) Point your ingress or Nginx to `kong-proxy` Service (port 8000) for API traffic.

Notes
- Update the JWKS URL/env in `kong.yaml` if Core runs under a different name/namespace.
- For production, consider the official Kong Helm chart and replicate the initContainer approach.

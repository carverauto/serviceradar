# external-dns

## Setup

The shipped deployment is intentionally scoped to the ServiceRadar-managed namespaces
(`demo` and `demo-staging`) and only publishes records for Services or Ingresses
that carry the `external-dns.alpha.kubernetes.io/hostname` annotation.

### Secrets

```bash
kubectl create secret generic cloudflare-api-token \
  --namespace external-dns-carverauto \
  --from-literal=api-token="YOUR_CLOUDFLARE_API_TOKEN"
```

## Install ExternalDNS

```bash
kubectl apply -k k8s/external-dns/base
```

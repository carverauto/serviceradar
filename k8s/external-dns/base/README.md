# external-dns

## Setup

### Secrets

```bash
kubectl create secret generic cloudflare-api-secret \
    --from-literal=CF_API_KEY="YOUR_CLOUDFLARE_API_KEY" \
    --from-literal=CF_API_EMAIL="YOUR_CLOUDFLARE_API_EMAIL"
```

## Install ExternalDNS

```bash
kubectl apply -f external-dns.yaml
```
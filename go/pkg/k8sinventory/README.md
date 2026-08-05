# k8sinventory

Discovers **public / edge Kubernetes endpoint ownership** and builds
**VIP → backend socket** correlation hints.

This package has **no ServiceRadar core, NATS, or SRQL dependency**. It is
meant to be validated with unit tests and the standalone CLI before wiring
publish/ingest.

## What it answers

Given a public flow destination such as `23.138.124.7:22`:

1. **Ownership** — which LoadBalancer Service and/or Gateway API route owns it
2. **Backends** — EndpointSlice pod/node/port (e.g. envoy `10.42.221.140:10022`)
3. **Correlation hints** — map public NetFlow tuple → post-DNAT socket that
   netprobe may attribute (`comm=envoy`)

Works from the Kubernetes API only (dataplane-agnostic: IPVS vs iptables vs
cloud LB controllers).

## Tests

```bash
go test ./go/pkg/k8sinventory/ -count=1
```

Covered without a live cluster:

- Forgejo-style MetalLB VIP + Gateway TCPRoute + EndpointSlice DNAT hint
- Hostname-only cloud LB ingress (EKS-style)
- ExternalIP services
- Unstructured Gateway / TCPRoute parsing
- Fake client-go Service + EndpointSlice list path

## CLI (live cluster)

```bash
go build -o k8s-inventory ./go/cmd/k8s-inventory

./k8s-inventory snapshot --cluster-id demo --ip 23.138.124.7 --port 22
./k8s-inventory snapshot --cluster-id demo --hints-only --ip 23.138.124.7
```

Requires kubeconfig (or in-cluster config). Does not publish anywhere.

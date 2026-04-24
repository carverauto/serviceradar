# Design: Flowgger External Service Configuration

## Context

Flowgger is ServiceRadar's syslog/NetFlow ingestion service. It receives UDP traffic from network devices (routers, switches, firewalls) that need to reach it from outside the Kubernetes cluster. The current approach requires manually creating LoadBalancer services in environment-specific directories (`k8s/demo/staging/serviceradar-flowgger-external.yaml`).

**Stakeholders**: Platform operators deploying ServiceRadar who need to ingest syslog from network infrastructure.

**Constraints**:
- Must support MetalLB (on-prem/bare-metal)
- Must support cloud provider load balancers (AWS NLB, GCP, Azure)
- Must not break existing deployments (disabled by default)
- UDP protocol support required (syslog uses UDP 514)

## Goals / Non-Goals

**Goals**:
- Enable external syslog ingestion through Helm values
- Support various load balancer implementations via annotations
- Allow static IP assignment where supported
- Keep configuration simple for common use cases

**Non-Goals**:
- TCP syslog support (can be added later if needed)
- Ingress-based routing (UDP doesn't work with HTTP ingress)
- mTLS for syslog (network devices typically don't support it)

## Decisions

### Decision 1: Separate External Service (not modify existing ClusterIP)

The existing ClusterIP service serves internal cluster communication (gRPC health checks, internal routing). We'll add a separate external service rather than changing the existing one.

**Rationale**: Keeps internal and external traffic isolated; allows different port mappings for external access (e.g., 30514 externally mapping to 514 internally).

**Alternatives considered**:
- Dual-stack single service: More complex, harder to configure separately
- NodePort only: Less flexible, exposes on all nodes

### Decision 2: Values Structure

```yaml
flowgger:
  externalService:
    enabled: false
    type: LoadBalancer
    annotations: {}
    loadBalancerIP: ""
    ports:
      syslog:
        enabled: true
        port: 514        # External port
        targetPort: 514  # Container port
        protocol: UDP
      netflow:
        enabled: false
        port: 2055
        targetPort: 2055
        protocol: UDP
```

**Rationale**: Matches patterns used elsewhere in the chart (e.g., `spire.server.serviceType`). Port-level granularity allows enabling only needed protocols.

### Decision 3: Environment-Specific Values in values-demo.yaml

Demo environment configuration goes in `values-demo.yaml`:

```yaml
flowgger:
  externalService:
    enabled: true
    annotations:
      metallb.universe.tf/address-pool: k3s-pool
```

**Rationale**: Follows existing pattern where `values-demo.yaml` contains environment-specific overrides.

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| UDP LoadBalancer support varies by provider | Document provider-specific annotations; test with MetalLB |
| Port conflicts on shared IPs | Use non-standard external ports (30514) by default |
| Breaking existing manual deployments | Feature disabled by default; migration path documented |

## Migration Plan

1. Deploy helm chart update (no behavior change - disabled by default)
2. Add values-demo.yaml configuration
3. Run `helm upgrade` to create external service via helm
4. Verify external IP assigned and syslog reaches flowgger
5. Remove manual `serviceradar-flowgger-external.yaml` from kustomization
6. Commit cleanup

**Rollback**: Disable `flowgger.externalService.enabled` and revert to manual YAML if issues arise.

## Open Questions

- [ ] Should we support TCP syslog in addition to UDP?
- [ ] Do we need rate limiting annotations for the external service?

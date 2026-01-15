---
sidebar_position: 15
title: Edge Agents
---

# Edge Agents

Edge agents are Go binaries that run on monitored hosts outside the Kubernetes cluster. They communicate with the Agent-Gateway via gRPC with mTLS for secure monitoring.

## Architecture

```mermaid
graph LR
  Agent[Agent] -->|gRPC mTLS| Gateway[Agent-Gateway]
  Gateway --> Core[core-elx]
```

## Security Model

| Property | Implementation |
|----------|----------------|
| **Transport** | gRPC with mTLS (TLS 1.3) |
| **Identity** | Workload-scoped X.509 certificates |
| **Isolation** | No ERTS/Erlang distribution access |
| **Authorization** | SPIFFE ID verification |

### What Edge Agents CANNOT Do

- Join the ERTS cluster
- Execute RPC calls on core-elx or agent-gateway
- Access Horde registries or enumerate cluster members
- Connect to the database directly

### Certificate Format

**Common Name (CN):**
```
<agent_id>.<partition_id>.<tenant_slug>.serviceradar
```

**SPIFFE ID (SAN URI):**
```
spiffe://serviceradar.local/agent/<tenant_slug>/<partition_id>/<agent_id>
```

## Deployment

Use the edge onboarding flow to generate an agent package and configuration. See:
- [Edge Onboarding](./edge-onboarding.md)
- [Installation Guide](./installation.md)

## Firewall Requirements

| Direction | Port | Protocol | Purpose |
|-----------|------|----------|---------|
| Outbound | 50052 | TCP | gRPC to Agent-Gateway |

## Troubleshooting

- Check agent logs: `journalctl -u serviceradar-agent -f`
- Verify gRPC connectivity with `grpcurl` against the Agent-Gateway endpoint
- Confirm cert validity with `openssl x509 -in svid.pem -noout -dates`

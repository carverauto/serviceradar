---
sidebar_position: 16
title: Security Architecture
---

# Security Architecture

ServiceRadar uses mTLS for internal traffic and JWTs for user/API access. Edge agents never join the ERTS cluster and only connect to the Agent-Gateway over gRPC.

## Security Layers

- **Network isolation**: edge agents only reach Agent-Gateway on port 50052.
- **ERTS isolation**: edge agents are not Erlang nodes and cannot call cluster RPC.
- **SPIFFE identities**: workload SVIDs are required for mTLS.
- **RBAC**: API access is enforced in web-ng and core-elx.

For TLS configuration and certificate handling, see [TLS Security](./tls-security.md).

1. Revoke agent certificate via TenantCA
2. Unregister agent: `AgentRegistry.unregister_agent/2`
3. Review gRPC logs for unusual patterns
4. Verify no ERTS connection established

### Certificate Rotation

1. Generate new certificates via TenantCA
2. Distribute to edge agents
3. Agents reconnect with new certs
4. Old certificates expire per CA policy

## Security Testing

Run the full security test suite:

```bash
cd elixir/serviceradar_core
mix test test/serviceradar/security/ --trace
```

**Test Coverage:**
- `edge_isolation_test.exs` - 7 tests
- `mtls_tenant_validation_test.exs` - 22 tests
- `cross_tenant_access_test.exs` - 14 tests

**Total: 43 security validation tests**

## Configuration Checklist

- [ ] SPIFFE trust domain configured (`spire.trustDomain`)
- [ ] Tenant CAs generated for all tenants
- [ ] Agent certificates use correct CN format
- [ ] mTLS enabled on gRPC endpoints
- [ ] Firewall blocks ERTS ports from edge
- [ ] No `agent@*` nodes in ERTS cluster
- [ ] AgentRegistry only stores gRPC endpoints
- [ ] Security tests passing (43 tests, 0 failures)

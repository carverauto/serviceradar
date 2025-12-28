# Security Runbook: Edge Isolation Architecture

This document describes the security properties of the ServiceRadar edge isolation architecture after removing Elixir edge agents in favor of Go agents communicating via gRPC.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                     SECURE ZONE (ERTS Cluster)                  │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐                  │
│  │   Core   │◄──►│   Core   │◄──►│  Poller  │                  │
│  │  Node 1  │    │  Node 2  │    │  Node 1  │                  │
│  └──────────┘    └──────────┘    └──────────┘                  │
│       ▲              ▲                │                         │
│       │   Erlang     │                │ gRPC                    │
│       │ Distribution │                │ (mTLS)                  │
│       ▼              ▼                ▼                         │
│  ┌──────────┐    ┌──────────┐   ┌──────────┐                   │
│  │  Horde   │    │ TenantReg│   │ AgentReg │                   │
│  │ Registry │    │  istry   │   │  istry   │                   │
│  └──────────┘    └──────────┘   └──────────┘                   │
└─────────────────────────────────────────────────────────────────┘
                              │
                              │ gRPC + mTLS
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                     EDGE ZONE (Go Agents)                       │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐                  │
│  │ Go Agent │    │ Go Agent │    │ Go Agent │                  │
│  │ Tenant A │    │ Tenant B │    │ Tenant C │                  │
│  └──────────┘    └──────────┘    └──────────┘                  │
│                                                                 │
│  - No ERTS connection                                          │
│  - mTLS with tenant-specific certificates                      │
│  - gRPC-only communication                                     │
└─────────────────────────────────────────────────────────────────┘
```

## Security Properties

### 1. ERTS Cluster Isolation (Verified)

**Property:** Edge nodes (Go agents) cannot join the ERTS cluster.

**Enforcement:**
- Go agents are compiled programs, not Erlang/Elixir nodes
- No ERTS distribution protocol is exposed to the edge
- Cluster topology only includes `core` and `poller` node types

**Verification Test:** `EdgeIsolationTest.cluster_nodes_do_not_include_edge_agent_nodes`

**Attack Scenario Blocked:**
- Attacker cannot use `:rpc.call/4` to execute arbitrary Erlang code on core nodes
- Result: `{:badrpc, :nodedown}` for any RPC to non-cluster nodes

### 2. Horde Registry Isolation (Verified)

**Property:** Edge nodes cannot enumerate or access Horde registries.

**Enforcement:**
- Horde registries run only on ERTS cluster nodes
- Go agents have no visibility into Erlang process registries
- Agent discovery requires going through the AgentRegistry API with proper tenant context

**Verification Test:** `EdgeIsolationTest.Horde_registries_are_not_accessible_from_non_ERTS_processes`

**Attack Scenario Blocked:**
- Attacker cannot call `Horde.Registry.lookup/2` to discover other tenants' agents
- Attacker cannot enumerate running processes across the cluster

### 3. mTLS Tenant Validation (Verified)

**Property:** Tenant identity is cryptographically bound to client certificates.

**Certificate Format:**
```
CN: <component_id>.<partition_id>.<tenant_slug>.serviceradar
SAN: spiffe://serviceradar.local/<component_type>/<tenant_slug>/<partition_id>/<component_id>
```

**Enforcement:**
- TenantResolver extracts tenant slug from certificate CN
- SPIFFE IDs provide node type authorization
- Certificates are signed by tenant-specific intermediate CAs
- mTLS verification rejects connections with invalid certificates

**Verification Tests:**
- `MTLSTenantValidationTest.extracts_tenant_slug_from_valid_CN`
- `MTLSTenantValidationTest.rejects_invalid_CN_format`
- `MTLSTenantValidationTest.SPIFFE_authorization_*`

**Attack Scenario Blocked:**
- Attacker cannot forge tenant identity without valid certificate
- Certificate CN modification invalidates the signature
- Cross-trust-domain connections are rejected

### 4. Multi-Tenant Isolation (Verified)

**Property:** Resources are strictly isolated by tenant_id.

**Enforcement Layers:**
1. **Registry Level:** AgentRegistry queries are scoped by tenant_id
2. **Database Level:** Ash multitenancy enforces tenant_id on all queries
3. **Policy Level:** Ash policies check actor tenant matches resource tenant

**Verification Tests:**
- `CrossTenantAccessTest.Attack_Scenario_1_Registry_Enumeration`
- `CrossTenantAccessTest.Attack_Scenario_2_Direct_Resource_Access`
- `CrossTenantAccessTest.Attack_Scenario_4_Capability_based_Discovery`
- `CrossTenantAccessTest.Attack_Scenario_5_Tenant_Spoofing`

**Attack Scenarios Blocked:**

| Attack | Result |
|--------|--------|
| Enumerate other tenant's agents via registry | Empty result |
| Get gRPC address for other tenant's agent | `{:error, :not_found}` |
| Query other tenant's agents via Ash | Filtered by tenant_id |
| Update other tenant's agent | Policy forbidden |
| Create job with other tenant's schedule_id | Job scoped to attacker's tenant |
| Spoof tenant_id in actor | Tenant context overrides |

### 5. gRPC-Only Communication Model (Verified)

**Property:** Edge agents communicate exclusively via gRPC, never ERTS.

**Enforcement:**
- AgentRegistry stores `grpc_host` and `grpc_port`, not Erlang pids
- Infrastructure.Agent resource has `host` and `port` attributes
- No `erlang_node` or `erlang_pid` attributes on Agent resource

**Verification Test:** `EdgeIsolationTest.agent_communication_model_uses_gRPC_addresses_not_ERTS_pids`

**Security Benefit:**
- All edge communication goes through defined gRPC APIs
- No arbitrary code execution path to edge
- Network firewall can control edge access via port rules

## Firewall Requirements

### Core/Poller Zone (Internal)

| Port | Protocol | Direction | Purpose |
|------|----------|-----------|---------|
| 4369 | TCP | Internal | EPMD (Erlang Port Mapper) |
| 9100-9155 | TCP | Internal | ERTS Distribution |
| 50051 | TCP | Outbound to Edge | gRPC to agents |
| 5432 | TCP | Outbound | PostgreSQL |

### Edge Zone (DMZ)

| Port | Protocol | Direction | Purpose |
|------|----------|-----------|---------|
| 50051 | TCP | Inbound from Core | gRPC from pollers |
| * | * | Outbound | Service checks (ICMP, TCP, HTTP, etc.) |

**Blocked by Architecture:**
- No inbound ERTS distribution ports (4369, 9100-9155) to edge
- No PostgreSQL access from edge
- No internal API access from edge

## Incident Response

### Suspected Cross-Tenant Access

1. **Check audit logs** for tenant_id mismatches in queries
2. **Review certificate issuance** for unauthorized tenant certificates
3. **Examine AgentRegistry** for cross-tenant lookups (should all fail)
4. **Verify tenant isolation** by running security tests

### Suspected Edge Compromise

1. **Rotate certificates** for the compromised agent
2. **Revoke access** via AgentRegistry.unregister_agent/2
3. **Review gRPC logs** for unusual patterns
4. **Verify no ERTS connection** was established (check Node.list/0)

### Suspected Certificate Forgery

1. **Check CA chain** - only tenant's intermediate CA should sign
2. **Verify SPIFFE ID** matches expected format
3. **Review TenantCA** issuance logs
4. **Rotate tenant CA** if compromise confirmed

## Security Test Suite

Run all security validation tests:

```bash
mix test test/serviceradar/security/ --trace
```

**Test Files:**
- `edge_isolation_test.exs` - ERTS isolation, Horde protection, gRPC model
- `mtls_tenant_validation_test.exs` - Certificate parsing, SPIFFE validation
- `cross_tenant_access_test.exs` - Penetration tests for tenant isolation

**Expected Result:** 43 tests, 0 failures

## Configuration Checklist

- [ ] SPIFFE trust domain configured: `serviceradar.local`
- [ ] Tenant CAs generated for all tenants
- [ ] Agent certificates issued with correct CN format
- [ ] mTLS enabled on gRPC endpoints
- [ ] Firewall rules block ERTS ports from edge
- [ ] No `agent@*` nodes in ERTS cluster
- [ ] AgentRegistry only stores gRPC endpoints

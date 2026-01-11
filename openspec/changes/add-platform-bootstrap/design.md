# Design: Platform Bootstrap

## Context

ServiceRadar requires a "zero-config" first-install experience where the platform automatically initializes with a working admin account. The current approach relies on manually running database seeds, which creates operational friction and security risks.

### Stakeholders

- **Platform operators**: Need secure, automated initial setup
- **DevOps teams**: Need consistent bootstrap across Docker Compose and Kubernetes
- **Security auditors**: Need audit trail and secure credential handling

### Constraints

1. Must work in air-gapped environments (no external password managers)
2. Must integrate with existing NATS operator bootstrap flow
3. Must not break existing deployments with manual seeds
4. Must handle idempotent restarts (don't regenerate on every start)

## Goals / Non-Goals

### Goals

- Automatic first-install detection and setup
- Secure random password generation
- Credential persistence appropriate to deployment mode
- One-time credential display for operator capture
- Clean integration with existing bootstrap infrastructure

### Non-Goals

- External secret management integration (Vault, AWS Secrets Manager) - future enhancement
- Multi-admin bootstrap - single admin is sufficient for first login
- Custom admin role configuration - super_admin only

## Decisions

### Decision 1: First-Install Detection via Database Query

**Choice**: Query for existence of default tenant and admin user to determine first-install state.

**Rationale**:
- Database is the source of truth
- Works across restarts and multiple replicas
- No need for external state files

**Alternatives considered**:
- File marker in volume: Rejected - doesn't work well with ephemeral containers
- Environment variable: Rejected - requires operator intervention

### Decision 2: GenServer Before OperatorBootstrap in Supervision Tree

**Choice**: Platform.Bootstrap starts before NATS.OperatorBootstrap in the supervision tree.

**Rationale**:
- OperatorBootstrap calls `ensure_default_tenant_nats_account()` which requires tenant to exist
- Sequential startup ensures tenant exists before NATS provisioning
- Both are `transient` restart strategy (don't restart on normal exit)

**Supervision tree order**:
```
ServiceRadar.Application
├── ServiceRadar.Repo
├── ServiceRadar.Platform.Bootstrap     # NEW - creates tenant/admin
├── ServiceRadar.NATS.OperatorBootstrap # Existing - creates NATS account
└── ...other supervisors
```

### Decision 3: Deployment-Mode-Specific Credential Storage

**Choice**: Detect deployment mode and use appropriate storage mechanism.

**Docker Compose mode** (detected by absence of K8s service account):
- Write JSON to `/data/platform/admin-credentials.json`
- Requires platform_data volume mount
- Operator retrieves via `docker exec` or volume inspection

**Kubernetes mode** (detected by K8s service account token presence):
- Create/update `serviceradar-admin-credentials` Secret
- Operator retrieves via `kubectl get secret ... -o jsonpath`
- Requires RBAC for core-elx ServiceAccount

**Detection logic**:
```elixir
def deployment_mode do
  cond do
    File.exists?("/var/run/secrets/kubernetes.io/serviceaccount/token") -> :kubernetes
    true -> :docker_compose
  end
end
```

### Decision 4: Password Format

**Choice**: 24-character password using `[A-Za-z0-9!@#$%^&*]` character set.

**Rationale**:
- ~140 bits entropy (exceeds NIST 800-63B requirements)
- Compatible with most password policies
- Long enough to resist offline attacks
- Printable ASCII for easy copy/paste

**Generation**:
```elixir
def generate_password(length \\ 24) do
  alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@#$%^&*"
  for _ <- 1..length, into: "" do
    <<Enum.random(String.to_charlist(alphabet))>>
  end
end
```

### Decision 5: Idempotent Bootstrap with Skip on Existing

**Choice**: Bootstrap checks for existing resources and skips if found.

**Logic**:
```
1. Check if default tenant exists
   - If exists: log "Tenant already exists", continue
   - If not: create tenant

2. Check if admin user exists in default tenant
   - If exists: log "Admin already exists", skip credential generation
   - If not: create admin, generate password, store credentials, log to console
```

**Rationale**:
- Safe for restarts and replica scaling
- Doesn't overwrite manually changed passwords
- Provides visibility into bootstrap state

## Risks / Trade-offs

### Risk: Credential Exposure in Logs

**Mitigation**:
- Only log password on first creation, not on restarts
- Use structured logging with `[BOOTSTRAP]` prefix for easy filtering
- Consider log rotation policies in production

### Risk: Multiple Replicas Racing

**Mitigation**:
- Use database unique constraints (tenant slug, user email per tenant)
- Handle `Ash.Error.Invalid` for constraint violations gracefully
- First replica wins, others detect existing and skip

### Risk: Kubernetes Secret RBAC

**Mitigation**:
- Document required RBAC in Helm values
- Fail fast with clear error if Secret creation fails
- Provide fallback to file-based storage with warning

### Trade-off: No External Secret Manager

**Accepted**: Simplifies initial implementation. Future enhancement can add Vault/AWS Secrets Manager support without breaking current design.

## Migration Plan

### Phase 1: Implement Bootstrap GenServer

1. Create `Platform.Bootstrap` module
2. Create `Platform.CredentialStorage` module
3. Add to supervision tree before OperatorBootstrap
4. Test in Docker Compose

### Phase 2: Kubernetes Support

1. Add Secret creation logic
2. Add RBAC to Helm chart
3. Test in local k3d cluster

### Phase 3: Documentation

1. Update installation docs
2. Add "First Login" guide
3. Document credential retrieval methods

### Rollback

- Remove Platform.Bootstrap from supervision tree
- Fall back to manual seeds.exs
- No data migration needed (bootstrap creates standard Ash resources)

## Open Questions

1. **Q**: Should we support custom admin email via environment variable?
   **A**: Yes, via `PLATFORM_ADMIN_EMAIL` (default: `admin@serviceradar.local`)

2. **Q**: Should bootstrap create the admin's TenantMembership?
   **A**: Yes, with role `:owner` for the default tenant

3. **Q**: How long should credentials be retained in storage?
   **A**: Indefinitely, but operator should change password and can delete file/secret after first login

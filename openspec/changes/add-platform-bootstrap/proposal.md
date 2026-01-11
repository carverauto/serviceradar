# Change: Add Platform Bootstrap for First-Install Experience

## Why

ServiceRadar's first-install experience currently requires manual setup steps:

1. **Manual seed execution**: Admins must run `mix run priv/repo/seeds.exs` to create the default tenant and admin user
2. **Hardcoded credentials**: Test credentials (`admin@default.local` / `password123456`) are used in seeds.exs
3. **No secure credential storage**: No mechanism to securely store generated admin passwords
4. **Fragmented bootstrap**: NATS operator bootstrap (`OperatorBootstrap` GenServer) runs automatically but depends on the tenant existing first
5. **No first-install detection**: The system cannot distinguish between first install and subsequent restarts

This creates security risks and operational friction:
- Hardcoded passwords may accidentally reach production
- Admins may forget to change default credentials
- No audit trail for initial admin creation
- Docker Compose and Kubernetes deployments have different credential delivery patterns

## What Changes

### 1. Platform Bootstrap GenServer

Add `ServiceRadar.Platform.Bootstrap` GenServer that runs at application startup:

- **First-install detection**: Check if `default` tenant and `admin` user exist
- **Automatic creation**: Create default tenant + admin user on first install only
- **Random password generation**: Generate cryptographically secure password
- **Secure storage**: Write credentials to Docker volume or K8s Secret
- **Console output**: Log credentials to stdout on first install ONLY (for operator visibility)
- **Integration**: Trigger existing `OperatorBootstrap` after tenant creation

### 2. Default Tenant Configuration

- Tenant ID: `00000000-0000-0000-0000-000000000000` (preserved for compatibility)
- Tenant name: "Default Organization"
- Tenant slug: `default`
- Status: `:active`

### 3. Platform Admin User

- Email: Configurable via `PLATFORM_ADMIN_EMAIL` env var (default: `admin@serviceradar.local`)
- Password: Random 24-character alphanumeric + symbols
- Role: `:super_admin` (platform-wide access)
- Tenant: Default tenant

### 4. Credential Storage

**Docker Compose**:
- Write to `/data/platform/admin-credentials.json` (on named volume)
- File permissions: `0600`

**Kubernetes**:
- Create/update `serviceradar-admin-credentials` Secret in same namespace
- Keys: `email`, `password`, `created_at`

### 5. Existing Integration Points

- **OperatorBootstrap**: Will find default tenant already exists, proceed to create NATS account
- **AssignDefaultTenant**: No changes needed (uses same default tenant ID)
- **Seeds.exs**: Becomes optional/dev-only, bootstrap GenServer handles production

## Impact

### Affected Specs

- NEW: `platform-bootstrap` capability spec

### Affected Code

- **NEW**: `elixir/serviceradar_core/lib/serviceradar/platform/bootstrap.ex` - Main bootstrap GenServer
- **NEW**: `elixir/serviceradar_core/lib/serviceradar/platform/credential_storage.ex` - Credential persistence
- **MODIFY**: `elixir/serviceradar_core/lib/serviceradar/application.ex` - Add Bootstrap to supervision tree (before OperatorBootstrap)
- **MODIFY**: `elixir/serviceradar_core/config/runtime.exs` - Add `PLATFORM_ADMIN_EMAIL` config
- **MODIFY**: `docker-compose.yml` - Add platform data volume
- **MODIFY**: `helm/serviceradar/templates/` - Add Secret and RBAC for credential creation

### Breaking Changes

None - this is additive. Existing seeds.exs continues to work for development.

## Deployment Considerations

### Docker Compose

```yaml
volumes:
  platform_data:

services:
  core-elx:
    volumes:
      - platform_data:/data/platform
    environment:
      - PLATFORM_ADMIN_EMAIL=admin@example.com  # Optional override
```

### Kubernetes

```yaml
# ServiceAccount needs Secret create/update permissions
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: serviceradar-core
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["create", "update", "get"]
```

## Security Considerations

1. **Password entropy**: 24-character password with uppercase, lowercase, digits, and symbols (~140 bits entropy)
2. **One-time display**: Password only logged on first install, never on restarts
3. **File permissions**: Credential files created with `0600` permissions
4. **Secret rotation**: Admins can change password via UI after first login; bootstrap does not overwrite
5. **Audit trail**: Bootstrap logs all actions with timestamps

## Migration Path

1. **Existing deployments**: Continue working; bootstrap detects existing tenant/user and skips
2. **New deployments**: Automatic bootstrap, no manual seeds required
3. **Development**: Can still use seeds.exs for reproducible test data

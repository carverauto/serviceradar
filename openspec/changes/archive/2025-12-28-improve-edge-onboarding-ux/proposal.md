# Change: Improve Edge Onboarding UX for Zero-Touch Provisioning

## Why

The current edge onboarding flow requires manual shell script execution for certificate generation and Kubernetes secret management. This creates friction for production deployments and violates the principle of zero-touch provisioning.

Key issues with the current approach:
1. **Manual CLI steps**: Shell scripts (`generate-tenant-ca.sh`, `sync-tenant-ca-to-k8s.sh`) are required for certificate generation
2. **Disconnected from UI**: The web UI doesn't leverage the existing `create_with_tenant_cert/2` function that handles automatic certificate generation
3. **Complex onboarding**: Tenant admins must understand certificate infrastructure instead of focusing on deploying edge components
4. **No progressive disclosure**: Users are exposed to certificate complexity before they need edge components

The infrastructure already exists - `create_with_tenant_cert/2` in `ServiceRadar.Edge.OnboardingPackages` automatically:
- Gets or generates the tenant's intermediate CA on-demand
- Generates component certificates signed by the tenant CA
- Includes the encrypted certificate bundle in the onboarding package

However, the UI wrapper module (`ServiceRadarWebNG.Edge.OnboardingPackages`) and LiveView don't use this function.

## What Changes

### 1. Wire Up Automatic Certificate Generation

Update the web-ng wrapper module to expose `create_with_tenant_cert/2`:
- Add `create_with_tenant_cert/2` delegation to `ServiceRadarWebNG.Edge.OnboardingPackages`
- Update the LiveView to call this function instead of `create/2`
- Pass the tenant from `current_scope.user.tenant_id`

### 2. Simplify Package Creation UI

Update the EdgePackageLive to:
- Remove certificate-related complexity from the user-facing form
- Show clear success state with download instructions
- Add one-liner install commands for common platforms (Docker, systemd)
- Display certificate fingerprint/validity only after creation (not during)

### 3. Improve Package Delivery UX

The package download/delivery flow should:
- Provide downloadable bundle files (not just tokens to copy)
- Include platform-specific install scripts in the bundle
- Show expiration countdown and renewal options
- Enable QR code generation for mobile-friendly deployment

### 4. Background CA Generation

When a tenant first creates an edge package:
- The system auto-generates the tenant CA in the background
- Progress indicator shows CA generation status
- No manual intervention required

## Impact

- Affected specs: None (UX improvement, no new capabilities)
- Affected code:
  - Modified: `web-ng/lib/serviceradar_web_ng/edge/onboarding_packages.ex` (add wrapper)
  - Modified: `web-ng/lib/serviceradar_web_ng_web/live/admin/edge_package_live/index.ex` (use new function)
  - New: Install script templates for package bundles

## Dependencies

- Existing `ServiceRadar.Edge.TenantCA` and `TenantCA.Generator` modules
- Existing `create_with_tenant_cert/2` function in `ServiceRadar.Edge.OnboardingPackages`

## Out of Scope

- Shell scripts remain for development/testing environments only
- Kubernetes secret automation (handled separately via ExternalSecrets or Vault)
- Certificate rotation automation (separate proposal)

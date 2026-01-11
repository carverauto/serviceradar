# Design: Zero-Touch Edge Onboarding

## Overview

This document describes the architectural changes needed to enable zero-touch edge onboarding, where tenant administrators can provision edge components entirely through the web UI without any manual certificate generation or CLI commands.

## Current State

```
┌─────────────────────────────────────────────────────────────────────┐
│                         CURRENT FLOW                                │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  1. Admin runs shell scripts to generate tenant CA                  │
│     $ ./scripts/generate-tenant-ca.sh acme-corp                     │
│                                                                     │
│  2. Admin syncs CA to Kubernetes                                    │
│     $ ./scripts/sync-tenant-ca-to-k8s.sh acme-corp                  │
│                                                                     │
│  3. Admin creates package in UI (no certs included)                 │
│     UI calls: OnboardingPackages.create(attrs, opts)                │
│                                                                     │
│  4. Edge component must be configured separately with certs         │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

## Target State

```
┌─────────────────────────────────────────────────────────────────────┐
│                         NEW FLOW                                    │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  1. Admin clicks "Create Package" in UI                             │
│     UI calls: OnboardingPackages.create_with_tenant_cert(attrs)     │
│                                                                     │
│  2. System auto-generates tenant CA if not exists                   │
│     └─> TenantCA.Generator.generate_root_ca(tenant)                 │
│                                                                     │
│  3. System generates component cert signed by tenant CA             │
│     └─> TenantCA.Generator.generate_component_cert(ca, opts)        │
│                                                                     │
│  4. UI shows download bundle with everything needed                 │
│     └─> Cert, key, CA chain, config, install script                 │
│                                                                     │
│  5. Admin downloads bundle, runs: ./install.sh                      │
│     └─> Component registered and sending data                       │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

## Component Diagram

```
                     ┌──────────────────────────────────────┐
                     │           Web UI (Phoenix)           │
                     │  EdgePackageLive                     │
                     └──────────────────┬───────────────────┘
                                        │
                                        ▼
                     ┌──────────────────────────────────────┐
                     │  ServiceRadarWebNG.Edge.             │
                     │  OnboardingPackages (wrapper)        │
                     │                                      │
                     │  + create_with_tenant_cert/2  ◄──NEW │
                     └──────────────────┬───────────────────┘
                                        │
                                        ▼
                     ┌──────────────────────────────────────┐
                     │  ServiceRadar.Edge.                  │
                     │  OnboardingPackages                  │
                     │                                      │
                     │  + create_with_tenant_cert/2 (exists)│
                     └──────────────────┬───────────────────┘
                                        │
              ┌─────────────────────────┼─────────────────────────┐
              │                         │                         │
              ▼                         ▼                         ▼
┌─────────────────────┐   ┌─────────────────────┐   ┌─────────────────────┐
│   TenantCA          │   │   TenantCA.         │   │   Crypto            │
│   (Ash Resource)    │   │   Generator         │   │   (Encryption)      │
│                     │   │                     │   │                     │
│   - certificate     │   │   - generate_root_ca│   │   - encrypt/decrypt │
│   - private_key     │   │   - generate_comp.. │   │   - hash/verify     │
│   - status          │   │                     │   │                     │
└─────────────────────┘   └─────────────────────┘   └─────────────────────┘
```

## Key Design Decisions

### 1. On-Demand CA Generation

The tenant CA is generated lazily when the first edge package is created, not at tenant signup. This:
- Reduces upfront complexity for tenants who don't need edge components
- Avoids generating unused CAs
- Keeps the signup flow fast

### 2. Certificate Bundle Format

The download bundle is a `.tar.gz` containing:

```
edge-package-<id>/
├── certs/
│   ├── component.pem        # Component certificate
│   ├── component-key.pem    # Private key
│   └── ca-chain.pem         # Root + intermediate CA chain
├── config/
│   └── config.yaml          # Component configuration
└── install.sh               # Platform-detecting installer
```

### 3. Install Script Strategy

The install script detects the platform and runs the appropriate installer:

```bash
#!/bin/bash
# install.sh - Auto-detect platform and install edge component

if command -v docker &> /dev/null; then
    # Docker-based install
    docker compose up -d
elif systemctl --version &> /dev/null; then
    # systemd-based install
    sudo cp serviceradar-*.service /etc/systemd/system/
    sudo systemctl enable --now serviceradar-agent
else
    echo "Manual installation required"
    echo "See: https://docs.serviceradar.cloud/edge/manual-install"
fi
```

### 4. Token Security

- **Download token**: Short-lived (24h default), hashed in DB
- **Join token**: Encrypted at rest with AshCloak, decrypted only during delivery
- **Certificate private key**: Never stored on server, included only in encrypted bundle

### 5. UI State Machine

```
[Form] ──create──> [Generating CA...] ──> [Creating Package...]
                                                    │
                                                    ▼
                        [Download Bundle] <── [Success!]
                              │
                              ▼
                   [Show Install Instructions]
```

## Data Flow

### Package Creation with Certificates

```elixir
# 1. LiveView receives form submission
def handle_event("create_package", params, socket) do
  # 2. Build attrs from form params
  attrs = build_package_attrs_from_form(params)

  # 3. Call wrapper with tenant from session
  tenant_id = socket.assigns.current_scope.user.tenant_id

  case OnboardingPackages.create_with_tenant_cert(attrs, tenant: tenant_id) do
    {:ok, result} ->
      # result contains: package, join_token, download_token, certificate_data
      socket
      |> assign(:created_tokens, result)
      |> assign(:bundle_ready, true)

    {:error, :ca_generation_failed} ->
      socket |> put_flash(:error, "Failed to initialize tenant certificate authority")
  end
end
```

### Bundle Download

```elixir
# Controller endpoint for bundle download
def download_bundle(conn, %{"id" => package_id, "token" => download_token}) do
  case OnboardingPackages.deliver(package_id, download_token) do
    {:ok, %{bundle_pem: bundle, package: pkg}} ->
      # Generate tarball with bundle contents
      tarball = BundleGenerator.create_tarball(pkg, bundle)

      conn
      |> put_resp_content_type("application/gzip")
      |> put_resp_header("content-disposition", "attachment; filename=edge-package-#{pkg.id}.tar.gz")
      |> send_resp(200, tarball)
  end
end
```

## Security Considerations

1. **CA Key Storage**: Tenant CA private keys are encrypted with AshCloak and stored in the database. The platform root CA key should be stored in a HSM or secure vault in production.

2. **Bundle Encryption**: The certificate bundle in the package is encrypted at rest. It's only decrypted and included in the download during delivery with valid download token.

3. **Certificate Revocation**: When a package is revoked, the associated component certificate should be added to a CRL or OCSP responder. (Future enhancement)

4. **Audit Logging**: All package operations are logged to `edge_onboarding_events` for compliance and troubleshooting.

## Trade-offs

| Decision | Benefit | Cost |
|----------|---------|------|
| Lazy CA generation | Simpler onboarding | First package creation is slower |
| Bundle includes install script | Zero-touch install | Script maintenance burden |
| Client-side key generation N/A | Server generates key | Key transits network (in encrypted bundle) |

## Future Enhancements

1. **QR Code Deployment**: Generate QR codes for mobile-initiated deployments
2. **Certificate Rotation**: Auto-renew component certs before expiry
3. **SCEP/EST Support**: Standard protocols for enterprise PKI integration
4. **Client-Side Key Generation**: Generate keys on client, submit CSR

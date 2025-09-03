---
sidebar_position: 5
title: Configuration Basics
---

# Configuration Basics

This page covers the core configuration for ServiceRadar with emphasis on authentication, RBAC, and route protection. Configuration is typically provided via `/etc/serviceradar/core.json` for the Core service.

For TLS, CORS, and other details see:
- Authentication specifics: `./auth-configuration.md`
- TLS Security: `./tls-security.md`

## Auth and RBAC

The `auth` section of `core.json` configures authentication and authorization:

```json title="/etc/serviceradar/core.json (excerpt)"
{
  "auth": {
    "jwt_secret": "your-long-random-secret",
    "jwt_expiration": "24h",
    "local_users": {
      "admin": "$2a$10$...bcrypt-hash..."
    },
    "rbac": {
      "user_roles": {
        "local:admin": ["admin"],
        "google:11223344556677889900": ["admin"],
        "github:ops@company.com": ["ops"],
        "readonly@company.com": ["viewer"]
      },
      "role_permissions": {
        "admin": ["*"],
        "ops":   ["config:read", "config:write"],
        "viewer":["config:read"]
      },
      "route_protection": {
        "/api/admin/*": ["admin"],
        "/api/admin/config/{service}": {
          "GET": ["admin", "ops"],
          "PUT": ["admin"]
        }
      }
    }
  }
}
```

### Identity Keys for `user_roles`

To prevent privilege escalation via email changes, RBAC role mapping supports stable, provider-scoped identities. Keys can be:
- `provider:subject` (preferred, e.g., `google:11223344556677889900`)
- `provider:email` (lowercased, e.g., `github:admin@company.com`)
- legacy `username-or-email` (lowercased) for backward compatibility

Local users can be scoped as `local:username` (e.g., `local:admin`).

The Core service resolves roles in this order: `provider:subject` → `provider:email` → legacy `username-or-email`.

### Permissions (`role_permissions`)

- Grant explicit permissions such as `config:read`, `config:write`.
- Use `"*"` to allow all permissions for a role.
- Category wildcards are supported (e.g., `config:*` matches `config:read`).

### Route Protection (`route_protection`)

You can restrict API routes by required roles:
- Exact path mapping: `"/api/admin/config/{service}": ["admin"]`
- Wildcards: `"/api/admin/*": ["admin"]`
- Method-specific roles via an object of HTTP methods to roles.

The API server automatically attaches the route-protection middleware for all `/api` routes when `auth.rbac.route_protection` is present. If it is not defined, admin endpoints under `/api/admin/...` default to requiring the `admin` role (safe fallback).

## API Authentication

All `/api` routes are protected by authentication. Clients authenticate using either:
- `Authorization: Bearer <JWT>` issued by the Core service, or
- Optional API key via `X-API-Key` when configured. See `AUTH_ENABLED` and `API_KEY` environment variables for development modes.

See `./auth-configuration.md` for login flows and CORS settings.

## Migration Notes

- If you previously keyed `user_roles` only by email/username, those still work (lowercased), but it is recommended to migrate to `provider:subject` or `local:username` for stronger identity binding.
- Review `route_protection` to align with your org’s role model; you can use method-specific rules to allow read-only access for non-admin roles.

## Quick Checklist

- Set a strong `auth.jwt_secret` and configure `auth.jwt_expiration`.
- Define `auth.local_users` for bootstrap access (replace default credentials).
- Map identities under `auth.rbac.user_roles` using `provider:subject` when available.
- Grant least-privilege with `auth.rbac.role_permissions`.
- Protect admin endpoints via `auth.rbac.route_protection`.


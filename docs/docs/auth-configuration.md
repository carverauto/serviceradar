---
sidebar_position: 10
title: Authentication
---

# Authentication

ServiceRadar authentication is configured in the Web UI (web-ng), not in `core.json`.

Go to **Settings -> Authentication** to choose an authentication mode and configure providers, JWKS, and claim mappings.

## Bootstrap Admin Access (Self-Hosted)

Self-hosted deployments bootstrap an admin user at startup if no admin exists.

- `SERVICERADAR_ADMIN_EMAIL` (default: `root@localhost`)
- `SERVICERADAR_ADMIN_PASSWORD` (required to bootstrap)
- `SERVICERADAR_ADMIN_PASSWORD_FILE` (optional alternative to `..._PASSWORD`)

Helm and Docker Compose set these for you (typically via a generated secret/file). After the first login, manage users in **Settings -> Auth -> Users**.

## Authentication Modes

ServiceRadar supports three instance-level modes:

## Password Only

Users authenticate with email + password.

- Sign-in UI: `GET /users/log-in`
- Password reset: `POST /auth/password-reset` (the reset link is valid for 1 hour)

## Direct SSO (OIDC / SAML)

Users are redirected to an identity provider. Configure this under **Settings -> Authentication**:

### OIDC

Required fields:

- Discovery URL (`https://<idp>/.well-known/openid-configuration`)
- Client ID
- Client secret

Redirect URI:

- `https://<web-host>/auth/oidc/callback`

### SAML 2.0

Use either an IdP metadata URL or paste metadata XML.

Service provider endpoints:

- ACS URL: `https://<web-host>/auth/saml/consume`
- SP metadata: `https://<web-host>/auth/saml/metadata`

## Gateway Proxy (JWT)

Use this when an upstream gateway authenticates users and injects a JWT on requests to web-ng.

Configure under **Settings -> Authentication**:

- JWT header name (default: `Authorization`)
- JWKS URL (preferred) or a static public key (PEM)
- Optional issuer (`iss`) and audience (`aud`) validation

In this mode, users are JIT-provisioned from claims when they first access ServiceRadar through the gateway.

## Claim Mappings

Claim mappings apply to OIDC, SAML, and Gateway Proxy to map identity claims into ServiceRadar user fields:

- `email` (required)
- `name`
- `sub` (stored as the user's external identifier)

Dot-notation is supported for nested claims (example: `user.email`).

## Hostname And Redirects

SSO redirect URIs and SAML metadata are built from the configured web-ng base URL.

If your IdP redirect URI or SAML metadata URLs are wrong, verify `PHX_HOST` (Helm/Docker Compose set this) matches the externally reachable hostname.


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
- `SERVICERADAR_ADMIN_PASSWORD_FORCE_SYNC` (default: `false` for shipped Helm and Compose defaults)

Helm and Docker Compose set these for you (typically via a generated secret/file). After the first login, manage users in **Settings -> Auth -> Users**.

Keep `SERVICERADAR_ADMIN_PASSWORD_FORCE_SYNC=false` for normal installs so a password changed in the UI is not overwritten on restart. Set it to `true` only when the mounted secret/file is the intended source of truth for the bootstrap admin password.

## Creating Accounts On First SSO Login

By default an identity-provider user with no local ServiceRadar account is
denied. Turn on **Create accounts on first SSO login** in
**Settings -> Authorization** (the same switch as **Settings -> Authentication
-> Auto-provision Accounts**) when the first successful SSO sign-in should
create the local row. New accounts get the configured default built-in role
unless a [group mapping](./group-permission-mapping.md) grants more.

Gate who can authenticate at the IdP (app assignment / group) so that only
people you intend to onboard can complete the login.

## SSO-Owned Email And Password

Once a local account is linked to an identity provider (`external_id` is set),
email and password are owned by that IdP. Profile settings show the address as
read-only and refuse a password change, even if an administrator previously
set a local password for break-glass sign-in. Change those values in Authentik,
Entra, or whichever directory issued the account.

Local-only accounts (no `external_id`) can still rotate email and password from
**Settings -> Profile** when they hold `settings.password.manage` (granted to
all built-in roles; omit it on a custom role profile to hide the password
form).

## Local Password Login With SSO

When Direct SSO or Gateway Proxy mode is enabled, local password login is controlled per account. Admins can enable or disable the **Local password login** toggle for each user under **Settings -> Auth -> Users**.

`SERVICERADAR_AUTH_FORCE_LOCAL_LOGIN` is a deployment-level break-glass switch. Leave it unset or `false` for normal installs. When set to `true`, any account with a valid local password can sign in locally even when SSO is enforced. This is intended only for recovering from broken AuthSettings or an unavailable identity provider.

## Authentication Modes

ServiceRadar supports three instance-level modes:

## Password Only

Users authenticate with email + password.

- Sign-in UI: `GET /users/log-in`
- Password reset: `POST /auth/password-reset` (the reset link is valid for 1 hour).
  Delivery uses the shared outbound mailer. Configure SMTP under
  **Settings -> Mail**; see [Outbound Mail](./outbound-mail.md).

## Direct SSO (OIDC / SAML)

Users are redirected to an identity provider. Configure this under **Settings -> Authentication**:

### OIDC

Required fields:

- Discovery URL (`https://<idp>/.well-known/openid-configuration`)
- Client ID
- Client secret

Redirect URI:

- `https://<web-host>/auth/oidc/callback`

web-ng is a confidential OIDC client: token exchange still sends the client
secret. It also uses Proof Key for Code Exchange (PKCE) with
`code_challenge_method=S256` on the authorization-code login at
`GET /auth/oidc`. Configure the PKCE mode under **Settings -> Authentication**
on the OIDC form. That is **not** the same flow as ServiceRadar's MCP OAuth
authorization server (`GET /oauth/authorize`), where ServiceRadar is the
authorization server and MCP clients must present PKCE.

PKCE modes:

- **Auto** (default) — send S256 when the IdP advertises
  `code_challenge_methods_supported` including `S256`, or when that field is
  absent. If the field is present and does not include `S256`, PKCE is omitted
  (`plain` is never sent).
- **Required** — always send S256; refuse to start login if discovery advertises
  challenge methods without `S256`.
- **Disabled** — never send PKCE. Use this only for a provider that rejects
  `code_verifier` on the token endpoint.

The code verifier is stored only in the encrypted login session, bound to
`state`, consumed on callback, and is not copied into identity claims or
logs.

### SAML 2.0

Use either an IdP metadata URL or paste metadata XML.

Service provider endpoints:

- ACS URL: `https://<web-host>/auth/saml/consume`
- SP metadata: `https://<web-host>/auth/saml/metadata`

## Gateway Proxy (JWT)

Use this when an upstream gateway authenticates users and injects a JWT on requests to web-ng.

Configure under **Settings -> Authentication**:

- JWT header name (default: `Authorization`)
- JWKS URL (preferred) or a static public key (PEM). One of these is required before Gateway Proxy mode can be enabled.
- Optional issuer (`iss`) and audience (`aud`) validation

In this mode, web-ng verifies the gateway JWT signature and required identity claims before creating a normal ServiceRadar browser session for Phoenix LiveView navigation. Direct access without either a verified gateway JWT or an existing ServiceRadar session is denied by the normal authenticated-route guardrails. The documented administrator escape hatch remains `GET /auth/local` and `POST /auth/local/sign-in`.

Gateway JWTs must include the mapped `email` and `sub` claims. New users are JIT-provisioned with the viewer role by default when they first access ServiceRadar through the gateway.

## Claim Mappings

Claim mappings apply to OIDC, SAML, and Gateway Proxy to map identity claims into ServiceRadar user fields:

- `email` (required)
- `name`
- `sub` (stored as the user's external identifier)

Dot-notation is supported for nested claims (example: `user.email`).

These mappings populate user fields (email, name, subject). They do **not**
assign roles. To turn identity-provider **groups** into a built-in role, a role
profile, or a ServiceRadar user group -- including how grants are revoked when
a user leaves a group, and the Microsoft Entra specifics -- see
[Group Permission Mapping](./group-permission-mapping.md).

## Hostname And Redirects

SSO redirect URIs and SAML metadata are built from the configured web-ng base URL.

If your IdP redirect URI or SAML metadata URLs are wrong, verify `PHX_HOST` (Helm/Docker Compose set this) matches the externally reachable hostname.

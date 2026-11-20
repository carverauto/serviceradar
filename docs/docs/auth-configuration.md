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
- `SERVICERADAR_ADMIN_PASSWORD_FORCE_SYNC` (default: `false`; the demo Helm overlay enables it)

Helm and Docker Compose set these for you (typically via a generated secret/file). After the first login, manage users in **Settings -> Auth -> Users**.

Keep `SERVICERADAR_ADMIN_PASSWORD_FORCE_SYNC=false` for normal installs. Set it to `true` when a rotated mounted secret/file should re-grant bootstrap admin access while the database persists.

With `SERVICERADAR_ADMIN_PASSWORD_FORCE_SYNC=true`, bootstrap re-applies the secret only when it changed since the recorded secret (for example the generated secret or admin-creds file was regenerated while the database persisted). A password changed through the UI or a reset flow persists across restarts and upgrades while the secret is unchanged. A subsequent secret rotation resets that password to restore bootstrap access.

For an existing administrator without rotation history, the first bootstrap with force-sync enabled records the current secret without changing the stored password. Only subsequent secret changes trigger a reset. With force-sync disabled, bootstrap leaves existing passwords unchanged even if the secret rotates.

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

## Direct SSO (OIDC)

Users are redirected to an OpenID Connect identity provider. OIDC is the only
direct-SSO protocol. Configure this under **Settings -> Authentication**:

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

### Upgrading from SAML

SAML 2.0 single sign-on has been removed. OIDC is the only direct-SSO
protocol. Configure OIDC before you upgrade if your users sign in through
SAML today.

- An install whose settings selected SAML is switched to **Password Only** by
  the upgrade migration, so administrators can still sign in with a local
  password. Enable OIDC afterwards under **Settings -> Authentication**.
- The old service provider endpoints (`/auth/saml`, `/auth/saml/consume`,
  `/auth/saml/metadata`) no longer exist and return 404.
- Users provisioned through SAML keep their accounts and roles. On their first
  OIDC sign-in they are matched on the stored external identifier, which is
  the value the `sub` claim mapping produces. Map `sub` to the OIDC claim that
  carries the same value the SAML NameID did. If it differs, the account is not
  matched: a sign-in whose email belongs to that existing account is rejected
  as unsafe account linking, and otherwise a new account is created only when
  just-in-time provisioning is enabled.

## Gateway Proxy (JWT)

Use this when an upstream gateway authenticates users and injects a JWT on requests to web-ng.

Configure under **Settings -> Authentication**:

- JWT header name (default: `Authorization`)
- JWKS URL (preferred) or a static public key (PEM). One of these is required before Gateway Proxy mode can be enabled.
- Optional issuer (`iss`) and audience (`aud`) validation

In this mode, web-ng verifies the gateway JWT signature and required identity claims before creating a normal ServiceRadar browser session for Phoenix LiveView navigation. Direct access without either a verified gateway JWT or an existing ServiceRadar session is denied by the normal authenticated-route guardrails. The documented administrator escape hatch remains `GET /auth/local` and `POST /auth/local/sign-in`.

Gateway JWTs must include the mapped `email` and `sub` claims. New users are JIT-provisioned with the viewer role by default when they first access ServiceRadar through the gateway.

## Claim Mappings

Claim mappings apply to OIDC and Gateway Proxy to map identity claims into ServiceRadar user fields:

- `email` (required)
- `name`
- `sub` (stored as the user's external identifier)

Dot-notation is supported for nested claims (example: `user.email`).

These mappings populate user fields (email, name, subject). They do **not**
assign roles. To turn identity-provider **groups** into a built-in role, a role
profile, or a ServiceRadar user group -- including how grants are revoked when
a user leaves a group, and the Microsoft Entra specifics -- see
[Group Permission Mapping](./group-permission-mapping.md).

## Default Homepage After Sign-In

After signing in, a user lands on the first of these that applies:

1. The page they were trying to open (a deep link or `return_to`). An unsafe or invalid `return_to` is ignored and the next applicable homepage below is used.
2. Their own homepage, set under **Settings > Profile > Default homepage**.
   Marking a dashboard **Set as default** on the dashboards hub sets the same value.
3. The homepage of one of their user groups, set under **Settings > User Groups**.
4. The deployment default, set under **Settings > Authorization > Default homepage**.
5. The overview dashboard (`/dashboard`).

A homepage is a choice, not a URL: the overview, the dashboards list, or a specific
dashboard. Opening `/` follows the same order.

**Groups that disagree.** Each user group has a homepage priority (default 100). Among a
user's groups that set a homepage, the lowest priority wins; ties go to the group name,
compared case-insensitively, and then the group id.

**Dashboards the user cannot open.** A dashboard homepage is re-checked as the signing-in
user every time. If it was deleted, archived, disabled, or is not shared with them, it is
skipped and the next level applies, so a group whose dashboard a member cannot open never
hides a working one. A user whose own homepage is skipped sees a one-time notice. When you
set a group or deployment homepage to a dashboard that is not public or shared with that
audience, the settings page warns you.

**SSO users.** No extra claim setup is needed: map the identity-provider group to a user
group (see [Group Permission Mapping](./group-permission-mapping.md)) and set that group's
homepage. Group memberships sync before the redirect is chosen, so a user's first SSO
sign-in lands on the group homepage.

## Hostname And Redirects

SSO redirect URIs are built from the configured web-ng base URL.

If your IdP redirect URI is wrong, verify `PHX_HOST` (Helm/Docker Compose set this) matches the externally reachable hostname.

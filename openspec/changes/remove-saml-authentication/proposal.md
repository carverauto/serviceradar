# Change: Remove SAML authentication

## Why

SAML single sign-on costs more than it is worth (GitHub issue #6052):

- `esaml` 4.6.0 is unmaintained. It carries four advisories with no fixed
  release (GHSA-4g2h-vm7x-747c, EEF-CVE-2026-93471, EEF-CVE-2026-86696,
  EEF-CVE-2026-105270), all waived in web-ng's dependency audit.
- The unauthenticated assertion consumer parses untrusted XML and is attack
  surface that has already needed an atom-exhaustion fix.
- OIDC already covers SSO for every identity provider ServiceRadar supports.

The product owner confirmed that no installation authenticates through SAML,
so SAML is removed outright: no deprecation release and no compatibility shim.
OIDC and local accounts remain.

## What Changes

- **BREAKING**: remove SAML sign-in. The routes `GET /auth/saml`,
  `POST /auth/saml/consume` and `GET /auth/saml/metadata` are deleted and
  return 404. The web-ng SAML strategy, response parser, assertion validator,
  metadata reader, XML parser and controller are deleted with their tests and
  fixtures.
- Settings -> Authentication offers OIDC as the only direct-SSO protocol. The
  provider selector and the SAML form are removed. `AuthSettings.provider_type`
  stays and accepts only `oidc`.
- Remove the core SAML resources (`SAMLPendingRequest`,
  `SAMLConsumedAssertion`), the `SAMLAssertionCleanupWorker` cron entry, the
  SAML rate-limit buckets and the `:saml` value from user, MCP grant and SSO
  provisioning auth-method enums. Remote-access SSH certificate issuance
  trusts OIDC sessions only.
- Remove the `esaml` and `sweet_xml` dependencies from web-ng (Mix lock and
  Bazel Hex closure) and delete the four `esaml` advisory waivers.
- Add a guarded migration that moves a stored SAML configuration to
  password-only, drops the SAML tables and columns, and clears stored SAML
  auth-method values that the application can no longer load.
- Documentation and the release note: SAML removed; configure OIDC before
  upgrading.

## Impact

- Affected specs: `platform-security`, `ash-authorization`,
  `ash-authentication`.
- Pending changes edited so their requirement copies do not restore SAML on
  archive: `add-mcp-sso-oauth`, `add-fleet-remote-access-enablement`,
  `migrate-dashboard-cli-to-pipelines`.
- Affected code: `elixir/web-ng` (auth, router, settings UI, MCP OAuth IdP
  binding, admin API client, config, deps), `elixir/serviceradar_core`
  (identity resources, crontab, rate limiter, SSH identity issuer,
  migration), `elixir/palisade` (docs only), `third_party/hex`.
- Upgrade: an installation configured for SAML falls back to local password
  login. Users provisioned through SAML keep their accounts and roles and sign
  in through OIDC once it is configured, matched on the same external
  identifier.

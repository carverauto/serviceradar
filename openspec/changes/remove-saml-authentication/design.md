## Context

SAML is removed entirely (see `proposal.md`). The open question in #6052,
whether any installation authenticates through SAML, is answered: none does.
The design questions left are how an upgraded database stops carrying SAML
state, and how the application treats values it can no longer represent.

## Decisions

- **No deprecation release, no shims.** No alias routes, no redirect from the
  old SAML URLs, no compatibility enum values. The old URLs return 404 because
  no route matches them.
- **`provider_type` stays, OIDC only.** `AuthSettings.provider_type` keeps its
  column and accepts only `oidc`. The Settings UI no longer shows a provider
  selector: direct SSO means OIDC, and saving direct-SSO mode stores
  `provider_type = oidc`. Dropping the column would touch the OIDC strategy,
  config cache and their tests for no behavioural gain.
- **One guarded migration** (`20261118232806_remove_saml_authentication.exs`)
  carries the upgrade:
  - `auth_settings` rows with `provider_type = 'saml'`: when `mode` is
    `active_sso` the row becomes `password_only` with `is_enabled = false`;
    `provider_type` becomes `NULL` in every case. The install falls back to
    local login instead of failing to load its settings.
  - Drop the columns `saml_idp_metadata_url`, `saml_idp_metadata_xml`,
    `saml_sp_entity_id`, `encrypted_saml_private_key_encrypted` and
    `saml_pinned_cert_fingerprints`, and the tables `saml_pending_requests`
    and `saml_consumed_assertions`.
  - `ng_users.last_auth_method = 'saml'` becomes `NULL`. Ash loads stored
    atoms with `String.to_existing_atom/1`; once no module mentions `:saml`, a
    stored `'saml'` could fail to load and make the account unreadable. `NULL`
    means "no recorded method" and the next sign-in overwrites it. Accounts,
    roles, role profiles and external identifiers are not touched.
  - `mcp_oauth_grants` with `auth_method = 'saml'` are deleted; their
    authorization codes and refresh tokens cascade. SAML never supplied an IdP
    refresh token, so such a grant could not refresh anyway, and its IdP
    session binding can no longer be confirmed. The user signs in again and
    re-consents.
  - Pending Oban jobs of the removed `SAMLAssertionCleanupWorker` are deleted
    so they do not fail as undefined workers.
  - Every statement is bounded (a singleton settings row, accounts and grants
    that carry a SAML value, one worker's pending jobs), idempotent, and
    tolerant of a database that never had SAML data. The migration carries
    the `serviceradar:allow-startup-maintenance` waiver with that reasoning.
- **Release note only.** The upgrade note in `CHANGELOG` and the
  authentication docs tell operators to configure OIDC before upgrading.
  There is no in-app "SAML was removed" notice: the migration erases the
  stored SAML state, and keeping a marker only to render a notice would be a
  compatibility shim.

## Risks / Trade-offs

- An installation that did use SAML loses SSO until OIDC is configured. Local
  administrators can still sign in, and `SERVICERADAR_AUTH_FORCE_LOCAL_LOGIN`
  remains the break-glass path.
- A SAML-provisioned user is matched to their account on first OIDC sign-in
  only when the OIDC `sub` claim mapping yields the external identifier the
  SAML NameID produced. Otherwise the existing account is not linked (an
  email match without an external-identifier match is rejected as unsafe
  account linking).

## Migration Plan

Upgrade runs the migration in the normal migrations job. Its `down` recreates
the dropped columns and tables, empty, so the previous release can boot after a
rollback. The data changes are not reversible: converted settings, cleared auth
methods, deleted grants and the contents of the dropped tables and columns are
not restored.

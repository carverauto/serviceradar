## 1. Close the SAML endpoints

- [x] 1.1 Delete the `/auth/saml`, `/auth/saml/consume` and `/auth/saml/metadata`
      routes, the `:saml_acs` pipeline and the SAML rate-limit pipelines from
      the web-ng router.
- [x] 1.2 Delete `SAMLController`, `SAMLStrategy`, `SAMLResponse`,
      `SAMLAssertionValidator`, `SAMLMetadata`, `SAMLXml` and the SAML test
      fixtures and tests; drop the deleted DB test from the web-ng shard list
      and the runner contract inventory.
- [x] 1.3 Add a regression test that the old SAML URLs are not routed.

## 2. Remove SAML from the application

- [x] 2.1 Settings -> Authentication: remove the provider selector, the SAML
      form and the SAML metadata test; direct SSO saves `provider_type = oidc`.
- [x] 2.2 Remove `:saml` from SSO provisioning, the auth-users label, the admin
      API client, the MCP OAuth IdP binding and refresh checks, and the
      settings catalog.
- [x] 2.3 Core: remove the SAML attributes, argument and AshCloak field from
      `AuthSettings` and limit `provider_type` to `oidc`; remove `:saml` from
      `User` and `McpOAuthGrant`; delete `SAMLPendingRequest`,
      `SAMLConsumedAssertion` and `SAMLAssertionCleanupWorker` and its cron
      entry; remove the SAML rate-limit buckets; trust only OIDC sessions for
      SSH certificate issuance.
- [x] 2.4 Delete the core SAML tests and their rows in
      `INTEGRATION_SOURCE_DISPOSITIONS.tsv` and
      `build/integration_test_dispositions.bzl`.
- [x] 2.5 Remove the SAML web-ng config keys.

## 3. Dependencies

- [x] 3.1 Remove `esaml` and `sweet_xml` from web-ng `mix.exs`, `mix.lock` and
      `BUILD.bazel`; regenerate the Hex closure with `//third_party/hex:write`.
- [x] 3.2 Delete the `esaml` advisory waivers from `.deps_audit_ignore` and
      `mix.exs`, and the SAML `.dialyzer_ignore.exs` entry.

## 4. Database

- [x] 4.1 Add `20261118232806_remove_saml_authentication.exs`: move stored SAML
      settings to password-only, clear `ng_users.last_auth_method = 'saml'`,
      delete SAML-bound MCP grants and pending SAML cleanup jobs, drop the
      SAML columns and tables.
- [x] 4.2 Bump Helm `core.migrations.expectedVersion`.

## 5. Docs and release note

- [x] 5.1 Remove SAML setup and references from the docs site, the security
      hardening notes and the Palisade README and package description.
- [x] 5.2 Document the upgrade path and claim matching in
      `docs/docs/auth-configuration.md`.
- [x] 5.3 Add the CHANGELOG upgrade note.
- [x] 5.4 Remove SAML from the pending `add-mcp-sso-oauth`,
      `add-fleet-remote-access-enablement` and
      `migrate-dashboard-cli-to-pipelines` changes.

## 6. Verification

- [ ] 6.1 `bazel build --config=remote //elixir/...`, the touched projects'
      quality checks, the web-ng and core unit shards and
      `//third_party/hex:gen_test` pass.
- [ ] 6.2 Database-backed lanes (migration replay, OIDC and local login tests)
      pass in BazelCI.

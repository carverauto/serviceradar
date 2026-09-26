# Credentials test ownership

Rules earned by the credentials test-audit campaign (#4649). Each one is a
mistake that was found in this directory, not a style preference.

- **Prove read authorization with a real read.** `Ash.can?/2` and
  `Ash.Policy.Info.strict_check/3` on a read return `true` for these resources
  even when the read policy is deleted: reads are filter policies, and a
  forbidden read becomes an empty filter. Positive read checks here stayed
  green with `read_with_permission` removed. Create and update policies are
  simple checks and `strict_check` on a changeset does fail correctly.
- **A leak refute needs input that carries the value.** Several tests refuted
  `"test-token"` / `"test-secret"` that no input contained, so they could
  never fail. Put a sentinel in the input, and use a key that
  `CredentialRedactor` does not already redact (bare `token` is not on its
  list today; a harmless `"note"` key is safer) when the contract is "caller
  data is dropped" rather than "the redactor ran".
- **Tag by what the test needs.** `:requires_app` routes a module to the
  database lanes only. A DB-free module carrying it disappears from the unit
  shard; two did.
- **Drive the production entry point.** Materializer tests went through a
  `reconcile_rules/4` entry only tests called; use
  `reconcile_provider_for_agent/4`, pin telemetry assertions to a unique
  `agent_id`, and pass `grant_issuer:` explicitly.
- **Constraint catalogs select by the referenced table,** not by a copied list
  of constraint names, or a new foreign key is invisible to the check.
- **Classifier tables assert the exact class,** not membership in the allowed
  set: `:internal_error` is itself allowed, so membership passes when every
  reason collapses to it.

Test routing for new or removed files (`INTEGRATION_SOURCE_DISPOSITIONS.tsv`)
is in [docs/agent-runbooks.md](../../../../../docs/agent-runbooks.md). Serial
selected-test counts live in `build/integration_test_dispositions.bzl`.

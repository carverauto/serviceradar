# Change: Deprecate SPIFFE/SPIRE support in phase one

## Why

GitHub issue #5413 authorizes a staged move to the deployment-managed mTLS model. The first phase must announce deprecation, provide neutral Helm configuration keys, and default new onboarding packages to mTLS while preserving existing explicit SPIRE installations. This proposal covers only that first phase. The user approved it through Lavish on 2026-10-08 and confirmed that no users rely on SPIRE/SPIFFE runtime support.

## What Changes

- Mark SPIRE runtime modes and Helm configuration as deprecated, with WARN-level startup messages and conditional Helm notes linking the migration guide.
- Introduce `serviceAccounts.<component>` and top-level `trustDomain` overrides while retaining the corresponding `spire.*` values as fallbacks. Reuse the existing `cnpg.*` namespace rather than create another database configuration hierarchy.
- Preserve existing cluster names, namespaces, secrets, certificates and service accounts when neutral overrides are absent. Keep CNPG cluster rendering mutually exclusive across the existing templates.
- Change the core chart's blank `DATASVC_SEC_MODE` fallback to `mtls` and default newly created edge onboarding packages to `mtls` in Ash, the database, the API and CLI.
- Document deprecation and a non-destructive migration sequence, including the manual cleanup required after a separately verified SPIRE migration.
- Retain the existing explicit SPIRE runtime path, manifests, CRDs and dependencies throughout phase one.

## Impact

- Affected specs: new `identity-deprecation` capability containing the phase-one compatibility contract.
- Affected code: Helm values/helpers/workload and CNPG templates; Go, Rust and Elixir security initialization; edge onboarding resource/default migration/controller/CLI; documentation and `openspec/project.md`.
- Existing URI SAN identity names, the `spiffe_identity` field, NATS leaf identities, datasvc RBAC identities, `SPIFFE_CERT_DIR`, certificate generators and `ComponentIdentityResolver` remain outside this change.
- The pending `remove-agent-gateway-spiffe-dependency` proposal contains a different certificate-identity change. This phase does not remove URI SANs or modify its resolver/issuer behavior. Its internal SPIRE-supported wording should be reconciled to deprecated compatibility by that proposal owner; coordinator notified, and no unowned proposal is edited here.

## Approval

The user approved the proposal through Lavish on 2026-10-08: "approved, there are no users using spire/spiffe either so.. i dont know if we really need to preserve anything here". Implementation remains scoped to the assigned phase one; removal of runtime paths and manifests belongs in a separately authorized follow-up. Preserve the currently load-bearing mTLS URI identity contract, and avoid extra migration machinery for unused SPIRE deployments.

## Context
ServiceRadar publishes OCI images to Harbor and already expects Cosign signatures to be present and verifiable. The current automation is converging on correct sign-then-verify sequencing, but it still assumes static key-based signing identities. The target state is a self-hosted Sigstore deployment that provides Fulcio, Rekor, and trust-root distribution for ServiceRadar release pipelines, avoiding long-lived private-key secrets in Forgejo.

Forgejo Actions now supports OIDC ID tokens when workflows enable OpenID Connect. Sigstore supports keyless signing against custom components and custom trust roots. The unresolved design constraint is identity origin: Forgejo can mint OIDC tokens for a workflow run, while Authentik exists in-cluster and may act as an upstream identity or federation component. The design must choose one issuer model and make it operationally coherent.

## Goals / Non-Goals
- Goals:
  - Eliminate static Cosign private keys from CI release jobs.
  - Produce Harbor-visible Cosign signature accessories and Rekor-backed verification for published OCI images.
  - Support local/operator verification with published trust material.
  - Keep the release pipeline usable from Forgejo Actions and repo-managed helpers.
- Non-Goals:
  - Reworking Harbor admission policy beyond what is needed to trust the new signatures.
  - Replacing existing image verification semantics with a different signing technology.
  - Solving unrelated Rust/test workflow failures as part of the signing migration.

## Decisions
- Decision: Introduce a dedicated `artifact-signing` capability rather than burying signing behavior inside existing image-build specs.
  - Rationale: Signing, trust roots, transparency logs, and verification material form a security capability with distinct operational requirements.

- Decision: Use keyless Sigstore signing for CI, backed by self-hosted Fulcio and Rekor.
  - Rationale: This removes long-lived private-key secrets from CI while preserving Cosign-compatible signatures and verification flows.

- Decision: Use Forgejo Actions OIDC tokens as the CI workload identity source unless a concrete Authentik federation requirement proves necessary.
  - Rationale: Forgejo officially supports OIDC token issuance for workflows. Authentik may still participate as the trusted issuer or federation bridge, but the implementation must not assume that merely having Authentik in-cluster is enough.

- Decision: Publish custom trust-root material for local verification.
  - Rationale: Verifying keyless signatures against custom Sigstore components requires explicit trust-root distribution; local `cosign verify` must work without hidden runner state.

## Risks / Trade-offs
- Risk: Custom Sigstore introduces new operational components and trust-root rotation work.
  - Mitigation: Keep deployment and trust distribution declarative and repo-owned.

- Risk: Forgejo OIDC claims may not match Fulcio/Auth policy assumptions out of the box.
  - Mitigation: Validate the exact claims emitted by Forgejo and encode the required subject/issuer constraints in the design before implementation.

- Risk: Authentik integration may be more complex than direct Forgejo OIDC trust.
  - Mitigation: Treat Authentik as an explicit design choice, not an assumed shortcut.

## Migration Plan
1. Deploy custom Sigstore components and publish trust material.
2. Add keyless signing support in CI behind configuration gates.
3. Verify release signing and Harbor-visible accessories end-to-end.
4. Remove static CI signing key dependence after the keyless path is proven.

## Open Questions
- Is Authentik intended to be the direct OIDC issuer for Fulcio, or should Fulcio trust Forgejo Actions OIDC directly?
- Where should the custom Sigstore trust root be published for operators and local tooling?
- Does Harbor policy need any issuer/identity-specific adjustments once signatures come from the self-hosted stack?

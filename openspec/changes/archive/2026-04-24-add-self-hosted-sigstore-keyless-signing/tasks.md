## 1. Design
- [ ] 1.1 Confirm the trust model for keyless signing: Forgejo Actions OIDC token claims, accepted issuer, Fulcio configuration, Rekor deployment, and trust-root distribution.
- [ ] 1.2 Decide whether Authentik is the effective OIDC issuer for Sigstore, or whether Forgejo Actions OIDC is the direct issuer and Authentik only participates through upstream trust or federation.
- [ ] 1.3 Define where the self-hosted Sigstore components live and how they are exposed to CI runners and operators.

## 2. Infrastructure
- [ ] 2.1 Add deployment manifests or Helm-managed configuration for self-hosted Fulcio, Rekor, and trust-root publication.
- [ ] 2.2 Configure issuer trust for the selected OIDC identity flow and document required Authentik and Forgejo configuration.
- [ ] 2.3 Publish the resulting trust root and verification material in a stable operator-consumable path.

## 3. CI/CD
- [ ] 3.1 Update Forgejo workflows to request OIDC tokens explicitly and sign OCI images keylessly against custom Sigstore endpoints.
- [ ] 3.2 Update BuildBuddy/local release helpers to support the same custom Fulcio/Rekor/TUF configuration.
- [ ] 3.3 Update verification scripts to verify signatures against the custom trust root without requiring static private keys.

## 4. Documentation and Verification
- [ ] 4.1 Update release/signing runbooks to describe the new keyless workflow and removal of static CI signing keys.
- [ ] 4.2 Add an end-to-end validation path proving Harbor-visible signatures, Rekor inclusion, and local verification against the published trust root.
- [ ] 4.3 Remove or deprecate key-based CI secret guidance once keyless signing is the default path.

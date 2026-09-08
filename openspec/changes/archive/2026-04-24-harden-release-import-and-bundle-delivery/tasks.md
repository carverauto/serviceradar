## 1. Implementation
- [x] 1.1 Restrict release import to GitHub and `https://code.carverauto.dev`, and enforce outbound URL policy on importer metadata and asset fetches.
- [x] 1.2 Prevent provider auth headers from being forwarded to untrusted asset hosts during import.
- [x] 1.3 Enforce outbound URL policy for core-side artifact mirroring, including signed manifest artifact URLs.
- [x] 1.4 Replace onboarding and collector bundle `GET ?token=` flows with a non-URL token transport and update generated install commands.
- [x] 1.5 Update docs and operator guidance for the new import and bundle-delivery behavior.

## 2. Verification
- [ ] 2.1 Run focused importer, onboarding, and mirroring tests.
- [x] 2.2 Run `openspec validate harden-release-import-and-bundle-delivery --strict`.

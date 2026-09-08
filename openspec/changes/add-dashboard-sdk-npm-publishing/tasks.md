## 1. Package Metadata
- [x] 1.1 Add npm publish metadata to `@serviceradar/dashboard-sdk`, including repository, license, publish access, and pack validation scripts.
- [x] 1.2 Ensure `npm pack --dry-run` includes only intended SDK source, Go helpers, and tooling files.
- [x] 1.3 Document npm installation and release expectations in the SDK README.

## 2. CI
- [x] 2.1 Add a Forgejo CI workflow that installs dependencies from `package-lock.json`, runs `npm test`, and runs package dry-run validation.
- [x] 2.2 Add a guarded GitHub Actions npm publish workflow using npm trusted publishing / OIDC.
- [x] 2.3 Validate the workflows locally where possible with `npm test` and `npm pack --dry-run`.

## 3. Release Guardrails
- [x] 3.1 Enforce release tag and package version alignment for tag-triggered publishes.
- [x] 3.2 Keep npm tokens out of source, generated files, workflows, and logs.
- [ ] 3.3 Configure npmjs.com trusted publisher settings for the GitHub mirror repository and `.github/workflows/npm-publish.yml`.

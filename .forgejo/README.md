# Forgejo Actions (retired)

Forgejo is no longer the CI host. All workflows live in
`.github/workflows/` and run on in-cluster GitHub Actions runner
scale sets (`arc-runner-set` for lint/checks, `serviceradar-signing`
for publish/sign). BuildBuddy still owns the heavy `buildbuddy.yaml`
suites.

Do not add new files under `.forgejo/workflows/`.

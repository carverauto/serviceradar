# Leftovers only

Do not add new Forgejo Actions here. Publish/sign jobs moved to
`.github/workflows/`. Lint/check jobs already live there too.

YAML still in this directory is either already superseded on GitHub
(`elixir-*`, `golangci-lint`, `helm-lint`, `secret-scan`, `web-ng-lint`,
`rust-lint`/`rust-audit` → `.github/workflows/rust-checks.yml`) or is
owned by BuildBuddy / Bazel and must not be recreated as GitHub Actions:

- `main.yml`
- `rust-musl.yml`
- `rust-tests-addon-interop.yml`
- `banner-grab-large.yml`

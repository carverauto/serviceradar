# Change: Add private dashboard Git sources

## Why
Dashboard package GitHub import currently assumes public `github.com` content fetched over GitHub API/raw HTTPS. Production dashboard packages may live in private GitHub or Forgejo repositories, which forces operators back to manual manifest/renderer upload and makes repeatable production updates fragile.

## What Changes
- Add an admin-managed dashboard Git source concept for dashboard package imports.
- Generate an SSH deploy keypair per source and show the public key for installation in the upstream Git host.
- Store the private key through the existing encrypted credential/secret facilities rather than in dashboard package rows.
- Fetch dashboard manifests and renderer artifacts from private Git repositories server-side using the stored key, with host allowlisting, path validation, ref pinning, size limits, and audit metadata.
- Extend the dashboard package import UI so operators can create/select a Git source, copy its public key, test connectivity, and import by ref/manifest path.

## Impact
- Affected specs: `build-web-ui`, `wasm-plugin-system`
- Affected code: `elixir/web-ng` dashboard package LiveView/importer, dashboard package publish API, encrypted credential storage, package source metadata/audit events
- Security impact: introduces stored SSH private keys for read-only package imports; requires strict encryption, redaction, host verification, and audit logging

# Change: Fix web-ng missing static assets in container builds

## Why
The web-ng Phoenix app is missing static assets (favicon, logo.svg) when deployed via Docker Compose or Bazel-built OCI images. The sidebar ServiceRadar icon does not appear in container deployments, and the browser favicon is missing entirely. Local development with `mix phx.server` works correctly for the logo, but the favicon is still missing due to a missing `<link>` tag in the HTML.

## What Changes
- **Fix Bazel build (`build/mix_release.bzl`)**: The current build script wipes `priv/static` entirely (lines 158-161) before running `mix assets.deploy`, destroying pre-existing static files like `favicon.ico`, `images/logo.svg`, and `robots.txt`. Modify the script to preserve these files.
- **Add favicon link to HTML**: `root.html.heex` is missing the `<link rel="icon">` tag. Add proper favicon references.
- **Verify static files exist**: Ensure `web-ng/priv/static/favicon.ico` and `web-ng/priv/static/images/logo.svg` are present and correct.

## Impact
- Affected specs: `web-ng-build` (new capability)
- Affected code:
  - `build/mix_release.bzl` - preserve static files during release build
  - `web-ng/lib/serviceradar_web_ng_web/components/layouts/root.html.heex` - add favicon link
  - `web-ng/priv/static/` - verify/add static assets
- Consumers: Docker Compose stack, Bazel-built OCI images, demo/staging k8s deployments

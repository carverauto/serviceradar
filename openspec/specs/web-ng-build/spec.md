# web-ng-build Specification

## Purpose
TBD - created by archiving change fix-web-ng-missing-static-assets. Update Purpose after archive.
## Requirements
### Requirement: Static Asset Preservation
The Bazel `mix_release` rule SHALL preserve pre-existing static assets in `priv/static/` when running `mix assets.deploy`.

Static assets that MUST be preserved:
- `favicon.ico` - Browser tab icon
- `images/logo.svg` - ServiceRadar logo used in sidebar navigation
- `robots.txt` - Search engine directives

The build process SHALL copy these files from the source `priv/static/` directory to the build output directory before running asset compilation, ensuring they are included in the final release tarball.

#### Scenario: Static assets included in release
- **WHEN** the Bazel target `//web-ng:release_tar` is built
- **THEN** the resulting tarball contains `priv/static/favicon.ico`
- **AND** the tarball contains `priv/static/images/logo.svg`
- **AND** the tarball contains `priv/static/robots.txt`

#### Scenario: Assets survive Docker build
- **WHEN** the web-ng OCI image is built via `//docker/images:web_ng_image_amd64`
- **THEN** the container filesystem contains `/app/lib/serviceradar_web_ng-*/priv/static/favicon.ico`
- **AND** the container filesystem contains `/app/lib/serviceradar_web_ng-*/priv/static/images/logo.svg`

### Requirement: Favicon HTML Reference
The web-ng Phoenix application SHALL include proper favicon link tags in the root HTML template.

The `root.html.heex` layout MUST contain a `<link rel="icon">` element referencing the favicon path so browsers display the ServiceRadar icon in tabs and bookmarks.

#### Scenario: Favicon displayed in browser
- **WHEN** a user loads any page in the web-ng application
- **THEN** the browser tab displays the ServiceRadar favicon
- **AND** bookmarking the page saves the favicon with the bookmark


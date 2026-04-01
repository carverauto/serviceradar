# Software Bill of Materials (SBOM)

ServiceRadar generates SBOMs and vulnerability reports in Forgejo Actions using:

- **Syft** for SPDX SBOM generation
- **OSV-Scanner** for vulnerability detection
- **Forgejo Actions** for automation
- **Harbor** for published container images

Trivy is intentionally not part of this workflow.

## Workflows

### 1. Source Security Scan
**Workflow:** `.forgejo/workflows/source-security.yml`

This workflow scans the repository itself and generates:

- `serviceradar-source.spdx.json`
- `serviceradar-source.sbom.txt`
- `serviceradar-source.osv.json`

It runs on:

- pushes to `main`
- pushes to `staging`
- tagged releases (`v*`)
- manual dispatch

For tagged releases, it uploads a bundled archive named:

- `serviceradar-source-security.tar.gz`

### 2. Image Security Scan
**Workflow:** `.forgejo/workflows/image-security.yml`

This workflow scans the released Harbor images for a given tag and generates, for each publishable image:

- SPDX JSON SBOM
- human-readable text SBOM
- OSV JSON vulnerability report

It runs on:

- tagged releases (`v*`)
- manual dispatch with a tag

For tagged releases, it uploads a bundled archive named:

- `serviceradar-image-security-<tag>.tar.gz`

## Registry Paths

Container images are scanned from Harbor, not GHCR:

```text
registry.carverauto.dev/serviceradar/<image>:<tag>
```

The image list is derived from:

- `docker/images/image_inventory.bzl`

## Local Verification

### Install Tools
```bash
./scripts/install-syft.sh
./scripts/install-osv-scanner.sh
```

### Generate a Source SBOM
```bash
syft scan dir:. \
  -c .syft.yaml \
  -o spdx-json=serviceradar-source.spdx.json \
  -o syft-text=serviceradar-source.sbom.txt
```

### Scan the Source Tree for Vulnerabilities
```bash
osv-scanner scan source -r . \
  --format json \
  --output-file serviceradar-source.osv.json
```

### Scan a Released Harbor Image
```bash
IMAGE="registry.carverauto.dev/serviceradar/serviceradar-core-elx:v1.2.10"

syft scan "registry:${IMAGE}" \
  -o spdx-json=serviceradar-core-elx.spdx.json \
  -o syft-text=serviceradar-core-elx.sbom.txt

osv-scanner scan image "${IMAGE}" \
  --format json \
  --output-file serviceradar-core-elx.osv.json
```

## Output Files

### Source scan outputs
- `serviceradar-source.spdx.json`
- `serviceradar-source.sbom.txt`
- `serviceradar-source.osv.json`

### Image scan outputs
Per image:
- `<image>.spdx.json`
- `<image>.sbom.txt`
- `<image>.osv.json`

## Release Assets

For tagged releases, the workflows upload bundles to the Forgejo release:

- `serviceradar-source-security.tar.gz`
- `serviceradar-image-security-<tag>.tar.gz`

## Exclusions

Source SBOM generation excludes the paths listed in:

- `.syft.yaml`

These exclusions remove bulky or generated trees such as:

- `node_modules/`
- `vendor/`
- `target/`
- `.git/`
- `build/`
- `dist/`
- `.cache/`
- Bazel output trees

## Notes

- Syft produces the SBOMs; it does not decide vulnerability severity.
- OSV-Scanner reports vulnerabilities based on the OSV database.
- Harbor stores the released images, but the trust and scanning policy is driven by the Forgejo workflows in this repository.

# Software Bill of Materials (SBOM)

ServiceRadar generates comprehensive Software Bills of Materials (SBOMs) to provide transparency about dependencies and support supply chain security.

## SBOM Types

### 1. Source Code SBOM
**Workflow:** `.github/workflows/sbom-syft.yml`

- Scans the entire source repository
- Includes all Go, Rust, and JavaScript dependencies
- Generated weekly and on releases
- Format: SPDX JSON
- Location: GitHub Actions artifacts and release assets

**Use cases:**
- Development dependency tracking
- Source code auditing
- License compliance

### 2. Container Image SBOMs (Recommended for Deployment)
**Workflow:** `.github/workflows/sbom-images.yml`

- Generates per-image SBOMs for each container
- Attached as OCI attestations (signed with cosign)
- Format: SPDX JSON + human-readable table
- Triggered automatically after releases

**Use cases:**
- Runtime dependency verification
- Vulnerability scanning
- Deployment compliance
- Supply chain security

## Verifying Container Image SBOMs

### Prerequisites
```bash
# Install cosign
brew install cosign  # macOS
# or
curl -sSfL https://github.com/sigstore/cosign/releases/latest/download/cosign-linux-amd64 -o /usr/local/bin/cosign
chmod +x /usr/local/bin/cosign
```

### Verify SBOM Attestation
```bash
# Verify the SBOM attestation is signed and valid
cosign verify-attestation \
  --type spdx \
  --certificate-identity-regexp='.*' \
  --certificate-oidc-issuer-regexp='.*' \
  ghcr.io/carverauto/serviceradar-core:v1.0.56
```

### Download and Inspect SBOM
```bash
# Download the SBOM from the attestation
cosign download attestation \
  ghcr.io/carverauto/serviceradar-core:v1.0.56 | \
  jq -r '.payload' | base64 -d | \
  jq '.predicate' > core-sbom.json

# View packages
jq -r '.packages[].name' core-sbom.json | sort | uniq

# Count packages
jq '.packages | length' core-sbom.json
```

### Scan for Vulnerabilities
```bash
# Using Grype (install: brew install grype)
grype ghcr.io/carverauto/serviceradar-core:v1.0.56

# Using Trivy (install: brew install trivy)
trivy image ghcr.io/carverauto/serviceradar-core:v1.0.56
```

## SBOM Locations

### GitHub Release Assets
Each release includes:
- `serviceradar-source.spdx.json` - Source code SBOM
- `serviceradar-<component>.spdx.json` - Per-image SBOM (SPDX JSON)
- `serviceradar-<component>.sbom.txt` - Per-image SBOM (human-readable)

### OCI Attestations
Each container image has an attached SBOM attestation accessible via:
```bash
cosign download attestation <image>
```

### GitHub Actions Artifacts
Available as workflow artifacts for 90 days after generation.

## Available Container SBOMs

The following container images have dedicated SBOMs:

- `serviceradar-core`
- `serviceradar-agent`
- `serviceradar-zen`
- `serviceradar-mapper`
- `serviceradar-datasvc`
- `serviceradar-poller`
- `serviceradar-flowgger`
- `serviceradar-trapd`
- `serviceradar-otel`
- `serviceradar-web-ng`
- `serviceradar-srql`
- `serviceradar-db-event-writer`

## Technical Details

### Tools Used
- **Syft** (v1.38.0): SBOM generation
- **Cosign** (v2.4.1): Signing and attestation
- **SPDX**: Standard format for SBOMs

### Signing
Images are signed using keyless signing via Sigstore/Cosign with GitHub OIDC tokens. This provides:
- No key management required
- Transparency log via Rekor
- Certificate-based verification

### Exclusions
Source SBOM excludes:
- `node_modules/`
- `vendor/`
- Test directories
- Build artifacts
- Documentation build artifacts

## Compliance

SBOMs support compliance with:
- Executive Order 14028 (Improving the Nation's Cybersecurity)
- NIST SP 800-218 (Secure Software Development Framework)
- CISA software supply chain guidelines

## Automation

SBOMs are generated automatically:
- **Source SBOM**: Weekly (Monday 00:00 UTC) and on releases
- **Image SBOMs**: After successful release artifact publication
- **Manual trigger**: Available via GitHub Actions workflow dispatch

## FAQ

**Q: Why two types of SBOMs?**
A: Source SBOMs track all development dependencies. Image SBOMs show only what's deployed in production containers.

**Q: Can I scan images before pulling?**
A: Yes! Download the SBOM attestation and scan it with Grype or Trivy without pulling the image.

**Q: Are SBOMs signed?**
A: Yes, container image SBOMs are signed with cosign using keyless signing.

**Q: How do I know what vulnerabilities are in an image?**
A: Use Grype or Trivy to scan the image or its SBOM for known CVEs.

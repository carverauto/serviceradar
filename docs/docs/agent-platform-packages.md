# Agent platform packages

The official release publishes installation packages for Linux amd64, Linux
arm64, and Apple Silicon Macs. Linux packages include the agent, package-owned
updater, and enrollment CLI. The macOS installer uses the existing launchd layout.

| Host | Installer | Managed agent updates |
| --- | --- | --- |
| Debian-based Linux, amd64 | `serviceradar-agent_<version>_amd64.deb` | Supported |
| Debian-based Linux, arm64 | `serviceradar-agent_<version>_arm64.deb` | Supported |
| Red Hat-based Linux, x86_64 | Agent `.x86_64.rpm` | Supported |
| Red Hat-based Linux, aarch64 | Agent `.aarch64.rpm` | Supported |
| macOS, Apple Silicon | `serviceradar-agent_<version>_darwin_arm64.pkg` | Install a newer signed package |

The macOS installer is a standalone release asset. It does not install the Linux
managed-updater layout and is not advertised as a selectable managed runtime.
Native add-ons have their own supported platform lists; an ARM64 agent package
does not imply every add-on supports that host.

## Install on a Raspberry Pi

Use a 64-bit operating system. On Debian-based distributions, check userspace
architecture before downloading the package:

```console
dpkg --print-architecture
```

The result must be `arm64`. An `armhf` installation cannot use this package,
even when the Raspberry Pi hardware supports 64-bit execution.

Install the downloaded package using APT so its declared dependencies are resolved:

```console
sudo apt install ./serviceradar-agent_<version>_arm64.deb
```

For a Red Hat-based ARM64 installation, use the `.aarch64.rpm` package:

```console
sudo dnf install ./serviceradar-agent-<version>-<release>.aarch64.rpm
```

Complete the normal [agent onboarding](./edge-agent-onboarding.md) process for a
new host. Installing a package does not provide enrollment credentials. Inspect
service status and logs after enrollment:

```console
systemctl status serviceradar-agent --no-pager
journalctl -u serviceradar-agent -n 50 --no-pager
```

Package upgrades preserve an existing managed runtime selection. The installed
seed binary's version can be checked without starting the launcher:

```console
/usr/local/lib/serviceradar/agent/serviceradar-agent-seed --version
```

## Install on macOS

Use the `.pkg` for Apple Silicon. Release packaging signs the agent with a
Developer ID Application identity, signs the installer with a Developer ID
Installer identity, submits it to Apple's notarization service, and staples the
accepted notarization ticket. Publication fails if any of these checks fails.

Check the downloaded installer before installing it:

```console
pkgutil --check-signature ./serviceradar-agent_<version>_darwin_arm64.pkg
xcrun stapler validate ./serviceradar-agent_<version>_darwin_arm64.pkg
sudo installer -pkg ./serviceradar-agent_<version>_darwin_arm64.pkg -target /
```

The installer retains the existing launchd service and configuration layout.
Configure enrollment before expecting the agent to connect to ServiceRadar.
Apply subsequent macOS versions by installing their signed packages.

## CI signing setup

The macOS release job uses an ephemeral `macos-15` ARM64 runner. It checks out the
release commit, validates its metadata and ingestion gate, and builds the native
agent and installer through Bazel before accessing Apple signing credentials.

Configure these secrets in the protected GitHub `release` environment:

| Secret | Value |
| --- | --- |
| `MACOS_APPLICATION_CERTIFICATE_P12` | Base64-encoded Developer ID Application certificate and private key in PKCS#12 format |
| `MACOS_INSTALLER_CERTIFICATE_P12` | Base64-encoded Developer ID Installer certificate and private key in PKCS#12 format |
| `MACOS_CERTIFICATE_PASSWORD` | Password protecting both PKCS#12 exports |
| `MACOS_APPLICATION_SIGN_IDENTITY` | Full Developer ID Application identity name, including team ID |
| `MACOS_INSTALLER_SIGN_IDENTITY` | Full Developer ID Installer identity name, including team ID |
| `MACOS_NOTARY_KEY_P8` | Base64-encoded App Store Connect API private key authorized for notarization |
| `MACOS_NOTARY_KEY_ID` | App Store Connect API key ID |
| `MACOS_NOTARY_ISSUER_ID` | App Store Connect issuer ID |

Reuse the organization's existing Developer ID certificates. Export only the two
required identities, protect the exports with a strong password, and transfer
them directly into the release environment's secret store. Do not commit
certificates, private keys, passwords, or real account identifiers.

The job creates an isolated temporary keychain, imports the identities, and stores
the notarization profile in that keychain. Credentials are used only by the local
signing process; they are not Bazel action inputs or cached artifacts. The keychain
and temporary credential files are deleted when the signing step exits.

Pull requests have a separate unsigned macOS package check. It builds and inspects
the actual ARM64 installer without release credentials or a signing keychain. Its
artifact is explicitly named `.unsigned.pkg` and cannot satisfy release publication.

The Linux publisher receives the verified macOS package and its provenance from
the same workflow run. It requires both Linux architectures and the verified
macOS installer before completing the release. A missing ARM64 package or failed
notarization therefore prevents release finalization and demo branch advancement.

Draft retries build all package inputs from the immutable release commit. A newer
workflow commit must not substitute its Linux binaries into an older release.
For tags predating this platform pipeline, dispatch the original workflow with
its workflow ref set to that tag. Released versions are not replaced; a source
change requires a new release.

Apple installer signatures and the ServiceRadar Ed25519 agent manifest serve
different purposes. Apple validates the macOS installation package. ServiceRadar
uses its signed manifest to authenticate Linux managed-runtime updates. See
[agent release management](./agent-release-management.md) for importing those
runtime releases and rolling them out to an enrolled fleet.

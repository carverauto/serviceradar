# Change: Ship the agent on Windows as a service with an MSI installer

## Why
The agent now compiles for Windows (#386), but nothing can install or run it there: the
binary does not answer the Windows service manager, so Windows kills it with error 1053,
and its config and state paths are hardcoded to `/etc/serviceradar` and
`/var/lib/serviceradar`. Operators need a standard installer to deploy it.

## What Changes
- The agent detects when Windows starts it as a service and reports its state to the
  service manager; a service Stop or Shutdown goes through the existing graceful shutdown.
- Per-OS default paths: on Windows, config and state live under
  `%ProgramData%\ServiceRadar\`; the unix defaults are unchanged.
- A WiX-based MSI packager (`build/packaging/agent/windows/`) produces
  `serviceradar-agent_<version>_windows_amd64.msi` and `_arm64.msi`. It installs the
  binary, a default config, and a `ServiceRadarAgent` service running as LocalSystem,
  set to start automatically and restart on failure. Upgrades replace older versions
  (fixed UpgradeCode + MajorUpgrade); uninstall keeps config and state.
- CI builds the MSIs on GitHub-hosted `windows-latest` runners, on demand and in the
  release workflow. The release publishes them as GitHub release assets.
- The MSI and binary ship **unsigned** for now. Authenticode signing through Azure Trusted
  Signing is tracked in #388.

## Out of scope
- Self-update (managed release rollout) on Windows: the updater is systemd-based; Windows
  agents are upgraded by installing a newer MSI.
- High-performance TCP/ICMP scanning on Windows (#387).

## Impact
- Affected specs: `agent-release-management`
- Affected code: `go/cmd/agent/main.go`, new `go/pkg/lifecycle` or `go/cmd/agent` Windows
  service file, path defaults in `go/pkg/agent/{types,sysmon_service,snmp_service,sync_runtime}.go`,
  new `build/packaging/agent/windows/`, `.github/workflows/agent-platform-packages.yml`,
  `.github/workflows/release.yml`, `build/release/platform_artifacts.go` (after #385).

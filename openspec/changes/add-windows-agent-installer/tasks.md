## 1. Agent runs as a Windows service
- [ ] 1.1 Add the Windows service handler (`svc.IsWindowsService` + `svc.Run`) wired to the agent's shutdown context; unix builds unchanged
- [ ] 1.2 Unit-test the handler's state transitions with a fake change-request channel
- [ ] 1.3 Per-OS default config/state paths; `--config` default follows the platform
- [ ] 1.4 Windows cross-build and `make test` green

## 2. MSI packager
- [ ] 2.1 `build/packaging/agent/windows/` Go packager + `.wxs` template (service, recovery actions, MajorUpgrade, config-if-absent)
- [ ] 2.2 Bazel targets: packager binary with the Windows agent `.exe` and default config as declared data
- [ ] 2.3 Unit tests for template rendering, input validation, and provenance
- [ ] 2.4 `agent-platform-packages.yml`: on-demand `windows-latest` job builds and inspects both MSIs

## 3. Release
- [ ] 3.1 `release.yml` builds both MSIs and hands them to the publisher (after #385 merges)
- [ ] 3.2 `build/release/platform_artifacts.go` validates and uploads the MSIs with their provenance
- [ ] 3.3 Document install/uninstall/upgrade in `docs/docs/agent-release-management.md`

## 4. Verification
- [ ] 4.1 Install, upgrade, and uninstall the MSI on a Windows runner; service reaches Running and restarts after a kill

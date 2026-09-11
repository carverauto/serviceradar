## 1. Agent runs as a Windows service
- [x] 1.1 Add the Windows service handler (`svc.IsWindowsService` + `svc.Run`) wired to the agent's shutdown context; unix builds unchanged
- [x] 1.2 Unit-test the handler's state transitions with a fake change-request channel
- [x] 1.3 Per-OS default config/state paths; `--config` default follows the platform
- [x] 1.4 Windows cross-build and `make test` green

## 2. MSI packager
- [x] 2.1 `build/packaging/agent/windows/` Go packager + `.wxs` template (service, recovery actions, MajorUpgrade, config-if-absent)
- [x] 2.2 Bazel targets: packager binary with the Windows agent `.exe` and default config as declared data
- [x] 2.3 Unit tests for template rendering, input validation, and provenance
- [x] 2.4 `agent-platform-packages.yml`: on-demand `windows-latest` job builds and inspects both MSIs

## 3. Release
- [x] 3.1 `release.yml` builds both MSIs and hands them to the publisher (after #385 merges)
- [x] 3.2 `build/release/platform_artifacts.go` validates and uploads the MSIs with their provenance
- [x] 3.3 Document install/uninstall/upgrade in `docs/docs/agent-release-management.md`

## 4. Verification
- [x] 4.1 Install, start, stop, and uninstall the MSI on a Windows runner (upgrade-in-place is covered by the template test, not yet by a live run)

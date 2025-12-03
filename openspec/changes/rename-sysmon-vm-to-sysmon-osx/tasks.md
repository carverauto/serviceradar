## 1. Preparation
- [x] 1.1 Create tracking issue for the rename work
- [x] 1.2 Ensure all sysmon-vm related PRs are merged or closed before starting

## 2. Go Package Renames
- [x] 2.1 Rename `pkg/checker/sysmonvm/` → `pkg/checker/sysmonosx/` (update package declaration)
- [x] 2.2 Update all import paths referencing `pkg/checker/sysmonvm`
- [x] 2.3 Rename `cmd/checkers/sysmon-vm/` → `cmd/checkers/sysmon-osx/`
- [x] 2.4 Update `pkg/config/registry.go`: change `"sysmon-vm-checker"` to `"sysmon-osx-checker"`
- [x] 2.5 Update `pkg/agent/registry.go`: change `"sysmon-vm"` case to `"sysmon-osx"`
- [x] 2.6 Update any other Go files with sysmon-vm references

## 3. Build System
- [x] 3.1 Move and update `cmd/checkers/sysmon-vm/BUILD.bazel` → `cmd/checkers/sysmon-osx/BUILD.bazel`
- [x] 3.2 Move and update `packaging/sysmonvm_host/BUILD.bazel` → `packaging/sysmonosx_host/BUILD.bazel`
- [x] 3.3 Update Makefile: rename all `sysmonvm-*` targets to `sysmonosx-*`
- [x] 3.4 Remove obsolete VM-related Makefile targets (vm-create, vm-start, vm-ssh, etc.)
- [ ] 3.5 Verify `bazel build` and `bazel test` pass

## 4. Scripts
- [x] 4.1 Move `scripts/sysmonvm/` → `scripts/sysmonosx/`
- [x] 4.2 Update script names (remove vm-* prefix, keep host-* and build-*)
- [x] 4.3 Update internal script references to new paths
- [x] 4.4 Remove scripts that are only for VM management (vm-create.sh, vm-start.sh, etc.)

## 5. Configuration Files
- [x] 5.1 Rename `docker/compose/sysmon-vm.checker.json` → `docker/compose/sysmon-osx.checker.json`
- [x] 5.2 Update service name inside checker config from `"sysmon-vm"` to `"sysmon-osx"`
- [x] 5.3 Update `docker/compose/poller.docker.json` service references
- [x] 5.4 Update `cmd/poller/config.json` service references
- [x] 5.5 Update `packaging/poller/config/poller.json` service references
- [x] 5.6 Rename example config: `sysmon-vm.json.example` → `sysmon-osx.json.example`

## 6. Service Definitions
- [x] 6.1 Rename LaunchDaemon plist: `com.serviceradar.sysmonvm.plist` → `com.serviceradar.sysmonosx.plist`
- [x] 6.2 Update plist contents (Label, Program path, log paths)
- [x] 6.3 Rename/update systemd service file (if keeping Linux support)
- [x] 6.4 Update default config/binary paths in plist and service files

## 7. Tools Directory
- [x] 7.1 Move `tools/sysmonvm/` → `tools/sysmonosx/`
- [x] 7.2 Update `config.example.yaml` if still applicable
- [x] 7.3 Remove VM-specific tooling that is no longer needed

## 8. Web UI
- [x] 8.1 Rename `web/src/components/Service/SysmonVmDetails.tsx` → `SysmonOsxDetails.tsx`
- [x] 8.2 Update component exports and imports in `Dashboard.tsx`
- [x] 8.3 Update any type definitions in `web/src/types/sysmon.ts` if they reference "vm"
- [x] 8.4 Update `WatcherTelemetryPanel.tsx` references
- [x] 8.5 Update `metric-components.jsx` references
- [x] 8.6 Update edge-packages admin page references
- [ ] 8.7 Run `npm run build` to verify no TypeScript errors

## 9. Docker Compose
- [x] 9.1 Update environment variable `SYSMON_VM_ADDRESS` → `SYSMON_OSX_ADDRESS`
- [x] 9.2 Update service names in compose files
- [x] 9.3 Update `poller-stack.compose.yml` if applicable

## 10. Documentation
- [x] 10.1 Move `cmd/checkers/sysmon-vm/README.md` → `cmd/checkers/sysmon-osx/README.md`
- [x] 10.2 Update README content (all path/name references)
- [x] 10.3 Rename `docs/docs/runbooks/sysmonvm-e2e.md` → `sysmonosx-e2e.md`
- [x] 10.4 Rename `docs/docs/runbooks/compose-mtls-sysmonvm.md` → `compose-mtls-sysmonosx.md`
- [x] 10.5 Update runbook contents
- [ ] 10.6 Add migration notes to CHANGELOG.md

## 11. TLS Demo Assets
- [x] 11.1 Rename `tls/demo/sysmon*` files to use new naming
- [x] 11.2 Update any scripts that reference these files

## 12. CI/CD
- [x] 12.1 Update `.github/workflows/clang-tidy.yml` path triggers
- [x] 12.2 Check for any other workflow files with sysmon-vm references
- [ ] 12.3 Verify CI passes with renamed paths

## 13. OpenSpec Updates
- [x] 13.1 Archive old sysmon-vm fix proposals (already implemented - kept as historical reference)
- [x] 13.2 Update `fix-sysmon-vm-metrics-availability/` references if needed (kept as historical reference)
- [x] 13.3 Update `fix-sysmon-vm-macos-service-startup/` references if needed (kept as historical reference)

## 14. Final Verification
- [x] 14.1 Run grep to find any missed references (remaining references are historical/test data)
- [ ] 14.2 Build all targets: `make sysmonosx-build-checker-darwin`
- [ ] 14.3 Package installer: `make sysmonosx-host-package`
- [ ] 14.4 Install on macOS test host and verify LaunchDaemon starts
- [ ] 14.5 Verify metrics flow end-to-end: sysmon-osx → poller → core → UI
- [ ] 14.6 Run full test suite

## 15. Release
- [ ] 15.1 Document upgrade path in release notes
- [ ] 15.2 Create migration guide for existing users
- [ ] 15.3 Tag release with rename

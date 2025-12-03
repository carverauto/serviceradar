# Change: Rename sysmon-vm package to sysmon-osx

## Status: PROPOSED

## Why
The `sysmon-vm` package name is misleading. The component was originally developed for testing in a Linux VM environment, but it is actually a macOS/darwin system monitor checker that collects CPU, memory, and process metrics from Apple Silicon hosts. The "vm" suffix suggests virtual machine monitoring, which is not the component's purpose.

Renaming to `sysmon-osx` clarifies:
1. The target platform (macOS/darwin)
2. The component's role as an OS-level system monitor
3. Distinction from other sysmon checkers that may exist for different platforms

## What Changes

### 1. Package & Directory Renames
| Old Path | New Path |
|----------|----------|
| `cmd/checkers/sysmon-vm/` | `cmd/checkers/sysmon-osx/` |
| `pkg/checker/sysmonvm/` | `pkg/checker/sysmonosx/` |
| `scripts/sysmonvm/` | `scripts/sysmonosx/` |
| `tools/sysmonvm/` | `tools/sysmonosx/` |
| `packaging/sysmonvm_host/` | `packaging/sysmonosx_host/` |

### 2. Binary & Service Names
| Old Name | New Name |
|----------|----------|
| `serviceradar-sysmon-vm` | `serviceradar-sysmon-osx` |
| `com.serviceradar.sysmonvm` (LaunchDaemon) | `com.serviceradar.sysmonosx` |
| `serviceradar-sysmon-vm.service` (systemd) | `serviceradar-sysmon-osx.service` |

### 3. Configuration Files
| Old Name | New Name |
|----------|----------|
| `sysmon-vm.json` | `sysmon-osx.json` |
| `sysmon-vm.json.example` | `sysmon-osx.json.example` |
| `sysmon-vm.checker.json` | `sysmon-osx.checker.json` |

### 4. Log Paths (macOS)
| Old Path | New Path |
|----------|----------|
| `/var/log/serviceradar/sysmon-vm.log` | `/var/log/serviceradar/sysmon-osx.log` |
| `/var/log/serviceradar/sysmon-vm.err.log` | `/var/log/serviceradar/sysmon-osx.err.log` |

### 5. Service Registry & Config Registry
- Update `pkg/config/registry.go`: `"sysmon-vm-checker"` → `"sysmon-osx-checker"`
- Update `pkg/agent/registry.go`: `"sysmon-vm"` → `"sysmon-osx"`
- Update KV key: `config/sysmon-vm-checker.json` → `config/sysmon-osx-checker.json`

### 6. Makefile Targets
Rename all `sysmonvm-*` targets to `sysmonosx-*`:
- `sysmonosx-host-setup`
- `sysmonosx-build-checker-darwin`
- `sysmonosx-host-install`
- `sysmonosx-host-package`
- (Remove VM-related targets that are no longer applicable)

### 7. Web UI Components
| Old Name | New Name |
|----------|----------|
| `SysmonVmDetails.tsx` | `SysmonOsxDetails.tsx` |
| `sysmon.ts` (types) | Update internal type names if they reference "vm" |

### 8. Docker Compose
- Update service name in compose files
- Update environment variable: `SYSMON_VM_ADDRESS` → `SYSMON_OSX_ADDRESS`

### 9. Documentation
- `cmd/checkers/sysmon-vm/README.md` → `cmd/checkers/sysmon-osx/README.md`
- Update all references in runbooks (`sysmonvm-e2e.md`, `compose-mtls-sysmonvm.md`)
- Update CHANGELOG references

### 10. TLS Demo Certificates
Rename demo certificate files:
- `tls/demo/sysmon*` → appropriate new naming

### 11. CI/CD
- Update `.github/workflows/clang-tidy.yml` path triggers
- Update any other workflow files referencing sysmon-vm paths

## Migration Path

### Backward Compatibility (Optional)
For existing deployments, consider:
1. Adding config migration logic to detect old paths and log deprecation warnings
2. Symlinks from old binary/config paths to new ones (for one release cycle)
3. KV store migration script to update `sysmon-vm-checker` → `sysmon-osx-checker` keys

### Breaking Change Approach (Recommended)
Given that sysmon-vm is a relatively new component with limited deployment:
1. Clean rename without backward compatibility shims
2. Document upgrade path in release notes
3. Require users to:
   - Reinstall the package (new paths)
   - Update poller configurations
   - Re-enroll if using edge onboarding

## Files to Modify

### Go Source
| File | Change |
|------|--------|
| `pkg/config/registry.go` | Update service type registration |
| `pkg/agent/registry.go` | Update case statement |
| `pkg/checker/sysmonvm/*.go` → `pkg/checker/sysmonosx/*.go` | Rename package, update imports |
| `cmd/checkers/sysmon-vm/main.go` → `cmd/checkers/sysmon-osx/main.go` | Update paths, service name |

### Build & Package
| File | Change |
|------|--------|
| `cmd/checkers/sysmon-vm/BUILD.bazel` | Move and update |
| `packaging/sysmonvm_host/BUILD.bazel` | Move and update package rules |
| `Makefile` | Rename targets |
| `scripts/sysmonvm/*.sh` | Move and update |

### Configuration
| File | Change |
|------|--------|
| `docker/compose/sysmon-vm.checker.json` | Rename and update |
| `docker/compose/poller.docker.json` | Update service reference |
| `cmd/poller/config.json` | Update service reference |
| `packaging/poller/config/poller.json` | Update service reference |

### Service Definitions
| File | Change |
|------|--------|
| `cmd/checkers/sysmon-vm/hostmac/com.serviceradar.sysmonvm.plist` | Rename and update |
| `tools/sysmonvm/serviceradar-sysmon-vm.service` | Rename and update |

### Web UI
| File | Change |
|------|--------|
| `web/src/components/Service/SysmonVmDetails.tsx` | Rename |
| `web/src/components/Service/Dashboard.tsx` | Update imports |
| Related component files | Update imports/references |

### Documentation
| File | Change |
|------|--------|
| `cmd/checkers/sysmon-vm/README.md` | Move and update |
| `docs/docs/runbooks/sysmonvm-e2e.md` | Rename and update |
| `docs/docs/runbooks/compose-mtls-sysmonvm.md` | Rename and update |
| `CHANGELOG.md` | Note rename in next release |

## Impact
- Affected specs: sysmon-telemetry (update references)
- Affected code: All sysmon-vm related packages, configs, and scripts
- Existing deployments: Will require reinstallation with new package

## Verification
1. Build sysmon-osx binary: `make sysmonosx-build-checker-darwin`
2. Package installer: `make sysmonosx-host-package`
3. Install and verify LaunchDaemon starts correctly
4. Verify metrics flow: sysmon-osx → poller → core → UI
5. Run E2E test with renamed components
6. Verify no residual "sysmon-vm" references in codebase (grep check)

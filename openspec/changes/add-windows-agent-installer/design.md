# Design: Windows agent service and MSI

## Service integration
`golang.org/x/sys/windows/svc` (already a dependency, v0.48.0). `svc.IsWindowsService()`
decides the mode at startup:
- service mode: `svc.Run("ServiceRadarAgent", handler)`. The handler reports
  `StartPending` -> `Running` once the agent has started, and on `Stop`/`Shutdown` cancels
  the same context the SIGINT/SIGTERM path cancels, reports `StopPending`, and waits for the
  agent to return.
- console mode (run from a terminal): unchanged signal handling, so `serviceradar-agent.exe
  --config ...` still works for debugging.
Unix builds never compile the handler (`_windows.go` / `_other.go` split).

The self-restart after an update (#386) exits the process; the MSI configures the service's
recovery actions to restart on failure so that exit becomes a restart.

## Paths
One helper returns the platform default root:
- unix: `/etc/serviceradar` (config) and `/var/lib/serviceradar` (state)
- Windows: `%ProgramData%\ServiceRadar\config` and `%ProgramData%\ServiceRadar\data`, read from
  the `ProgramData` environment variable, falling back to `C:\ProgramData`.
Explicit paths in config or flags still win.

## MSI
- WiX Toolset v5.0.2 (a .NET tool), pinned, run on `windows-latest`. WiX v6 and later require
  the Open Source Maintenance Fee from users who generate revenue; v5.0.2 predates it. Moving to a
  newer WiX is a licensing decision, not a routine bump. Bazel cross-compiles the `.exe` on
  Linux RBE and the job packages it. The packager is a Go program like the macOS one, with two
  subcommands. `stage` is a Bazel target run on Linux: it copies the two agent `.exe`s, the
  Windows config and the packager itself (cross-compiled for Windows) out of runfiles, with an
  `inputs.json` of their digests. This repository's Bazel setup does not run on Windows hosts,
  so the Windows job receives these instead of building them. `build` runs on the Windows
  runner: it checks every input against `inputs.json`, checks each agent's PE machine type,
  runs `--version` on the host-architecture agent, renders the `.wxs`, runs `wix build` per
  architecture, unpacks the result with `msiexec /a` and compares the packaged bytes, and
  writes a provenance JSON (version, commit, arch, SHA256s, unsigned).
- Install layout: `%ProgramFiles%\ServiceRadar\serviceradar-agent.exe`; default config to
  `%ProgramData%\ServiceRadar\config\agent.json` only if absent (never overwrites operator
  config).
- Service: `ServiceInstall` (LocalSystem, auto start) + `ServiceControl` (stop on upgrade and
  uninstall, remove on uninstall; no start, because the default config is not usable until the
  operator fills in the gateway and certificates) + the Util extension's `util:ServiceConfig`
  (restart 10s after each failure; reset after a day). The core `ServiceConfigFailureActions`
  element made installs fail with Error 1939 on the hosted Windows runner.
- Fixed per-architecture `UpgradeCode`, `MajorUpgrade` with downgrade blocked.

Alternative rejected: `wixl` (msitools) on Linux would keep packaging inside Bazel, but it
implements only a subset of WiX and its support for service recovery actions is uncertain.

## Signing
Unsigned until #388 lands. The packager has no signing mode yet; adding one later is a new
`--mode release` step in the release job, as on macOS.

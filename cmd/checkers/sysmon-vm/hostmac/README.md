# macOS Host Frequency Integration

The sysmon-vm checker embeds its macOS frequency sampler directly into the Go
binary via cgo. The Objective-C++ implementation that talks to IOReport now
lives under `pkg/cpufreq` and is compiled as part of the checker, so no separate
`hostfreq` executable or launchd service is required.

## Build

```
make sysmonvm-build-checker-darwin
```

The command cross-compiles the checker (including the embedded sampler) into
`dist/sysmonvm/mac-host/bin/serviceradar-sysmon-vm`.

## Install

```
sudo make sysmonvm-host-install
```

The install script copies the checker to
`/usr/local/libexec/serviceradar/serviceradar-sysmon-vm`, installs the launchd
unit `com.serviceradar.sysmonvm`, and ensures `/usr/local/etc/serviceradar`
contains `sysmon-vm.json`. Because the frequency sampler is built in, there is
no companion `hostfreq` daemon to manage. `scripts/sysmonvm/host-setup.sh`
also fetches a `spire-agent` binary (arm64 macOS) into `dist/sysmonvm/bin`, and
`sysmonvm-host-install` copies it to `/usr/local/libexec/serviceradar/spire-agent`
so the embedded onboarding flow can join the demo SPIRE server without extra
install steps.

## Troubleshooting

- The sampler still depends on private IOReport APIs, so the launchd service
  must run with sufficient privileges (root on Apple Silicon macOS).
- When the process cannot talk to IOReport, `pkg/cpufreq` reports the wrapped
  error that previously came from the helper binary. Check
  `/var/log/serviceradar/sysmon-vm.err.log` for additional detail.

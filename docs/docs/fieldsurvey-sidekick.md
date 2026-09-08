---
title: FieldSurvey Sidekick
description: Raspberry Pi RF bridge for FieldSurvey Wi-Fi surveys.
---

# FieldSurvey Sidekick

FieldSurvey Sidekick is the Raspberry Pi companion daemon for the native iOS
FieldSurvey app. The iPhone remains responsible for ARKit/LiDAR pose tracking,
visualization, offline bundles, and ServiceRadar uploads. The Pi supplies
high-fidelity Wi-Fi observations from Linux monitor-mode USB radios.

The RF data plane uses one WebSocket per radio with binary Apache Arrow IPC
record batches. SDR spectrum sweeps use a separate binary Arrow IPC WebSocket
so Wi-Fi BSSID observations and interference/channel-energy observations remain
distinct. Control and status endpoints remain JSON.

## Hardware Requirements

The Sidekick daemon runs on a Raspberry Pi (64-bit ARM) running a current
64-bit Debian release. You will need:

- **A management interface** — the Pi's built-in Wi-Fi (`wlan0`) or wired
  Ethernet, used for connectivity to the iPhone and ServiceRadar. Do not use the
  management interface for capture.
- **One or more monitor-mode USB Wi-Fi adapters** — used for survey capture.
  Each adapter must expose Linux monitor mode and radiotap metadata through `iw`.
  Verified chipsets:
  - Ralink RT5572 (`rt2800usb` driver)
  - MediaTek MT7612U (`mt76x2u` driver)

  Prefer a USB3 adapter for the 5 GHz survey plan.
- **(Optional) A HackRF One SDR** — used for channel-energy/interference
  spectrum sweeps.

Treat the HackRF as receive-only unless the hardware modification history is
known. The Sidekick spectrum path starts `hackrf_sweep` with the RX amp disabled
and antenna power disabled.

## Connectivity

Treat the iPhone-to-Pi connection as IP transport. USB networking is the
preferred field transport when it is available; LAN reachability works for lab
and bench setups. The daemon listens on port `17321` by default and serves both
HTTP control endpoints and WebSocket observation streams:

- `http://<PI_HOST>:17321` — control and status
- `ws://<PI_HOST>:17321` — RF and spectrum streams

Replace `<PI_HOST>` with the Pi's address on whichever transport you use.

## Installation

The repository includes a systemd install path under
`build/packaging/fieldsurvey-sidekick/`.

Build the daemon for the Pi (64-bit ARM). Install the Linux ARM64 Rust target
once:

```bash
rustup target add aarch64-unknown-linux-gnu
```

The repo-local Cargo config uses `aarch64-linux-gnu-gcc` for that target. Build
the daemon:

```bash
cargo build -p serviceradar-fieldsurvey-sidekick --target aarch64-unknown-linux-gnu
```

Copy the binary and packaging assets to the Pi, then install the systemd service
(replace `<pi-user>` and `<PI_HOST>`):

```bash
scp target/aarch64-unknown-linux-gnu/debug/serviceradar-fieldsurvey-sidekick \
  <pi-user>@<PI_HOST>:/tmp/serviceradar-fieldsurvey-sidekick.new

scp build/packaging/fieldsurvey-sidekick/config/fieldsurvey-sidekick.toml \
  build/packaging/fieldsurvey-sidekick/config/fieldsurvey-sidekick.env.example \
  build/packaging/fieldsurvey-sidekick/systemd/serviceradar-fieldsurvey-sidekick.service \
  <pi-user>@<PI_HOST>:/tmp/

ssh <pi-user>@<PI_HOST> '
  sudo install -m 0755 /tmp/serviceradar-fieldsurvey-sidekick.new \
    /usr/local/bin/serviceradar-fieldsurvey-sidekick
  sudo install -d -m 0755 /etc/serviceradar
  sudo install -m 0644 /tmp/fieldsurvey-sidekick.toml \
    /etc/serviceradar/fieldsurvey-sidekick.toml
  sudo install -m 0600 /tmp/fieldsurvey-sidekick.env.example \
    /etc/serviceradar/fieldsurvey-sidekick.env
  sudo install -m 0644 /tmp/serviceradar-fieldsurvey-sidekick.service \
    /etc/systemd/system/serviceradar-fieldsurvey-sidekick.service
  sudo systemctl daemon-reload
  sudo systemctl enable --now serviceradar-fieldsurvey-sidekick.service
'
```

Before field use, set a strong `SERVICERADAR_SIDEKICK_API_TOKEN` in
`/etc/serviceradar/fieldsurvey-sidekick.env`, replacing the `change-me`
placeholder.

Runtime paths:

- Binary: `/usr/local/bin/serviceradar-fieldsurvey-sidekick`
- Config: `/etc/serviceradar/fieldsurvey-sidekick.toml`
- Environment/token file: `/etc/serviceradar/fieldsurvey-sidekick.env`
- Persisted runtime config:
  `/var/lib/serviceradar/fieldsurvey-sidekick/runtime-config.json`
- Logs:
  `/var/log/serviceradar/fieldsurvey-sidekick.log` and
  `/var/log/serviceradar/fieldsurvey-sidekick-error.log`

Check service status:

```bash
ssh <pi-user>@<PI_HOST> \
  'sudo systemctl status serviceradar-fieldsurvey-sidekick.service --no-pager'

curl -s http://<PI_HOST>:17321/healthz
curl -s http://<PI_HOST>:17321/status
```

## Pairing Workflow

`SERVICERADAR_SIDEKICK_API_TOKEN` is the setup/admin token. Use it to claim a
paired device token from the iOS app or with curl:

```bash
curl -s -X POST http://<PI_HOST>:17321/pairing/claim \
  -H "authorization: Bearer <admin-token>" \
  -H "content-type: application/json" \
  -d '{"device_id":"iphone-field-unit-1","device_name":"FieldSurvey iPhone"}'
```

The response includes a one-time visible `token`. Store that token in the
FieldSurvey Sidekick settings and use it for normal config, control, RF stream,
and spectrum stream requests. The daemon stores only the token hash in
`runtime-config.json`; `/config` returns paired device metadata without token
hashes.

The setup token still works as an admin credential. Rotate it in
`/etc/serviceradar/fieldsurvey-sidekick.env` after provisioning if the field
unit should rely only on paired-device tokens.

## Verifying the Daemon

Mutating endpoints and observation streams require a bearer token — the admin
token or a paired-device token.

Check radio inventory and stream state:

```bash
curl -s http://<PI_HOST>:17321/status
```

`/status` includes `capture_running` and `active_streams`, so the app can see
whether RF or spectrum WebSockets are currently registered.

Read the persisted runtime config:

```bash
curl -s http://<PI_HOST>:17321/config \
  -H "authorization: Bearer <token>"
```

Update non-secret runtime config values:

```bash
curl -s -X PUT http://<PI_HOST>:17321/config \
  -H "authorization: Bearer <token>" \
  -H "content-type: application/json" \
  -d '{"sidekick_id":"fieldsurvey-sidekick","radio_plans":[{"interface_name":"wlan2","frequencies_mhz":[5180,5200,5220],"hop_interval_ms":250}]}'
```

Plan a Pi Wi-Fi uplink configuration without changing the Pi. Responses redact
the passphrase:

```bash
curl -s -X POST http://<PI_HOST>:17321/wifi/uplink-plan \
  -H "authorization: Bearer <token>" \
  -H "content-type: application/json" \
  -d '{"interface_name":"wlan0","ssid":"<ssid>","psk":"<wifi-password>","country_code":"US","dry_run":true}'
```

Apply the uplink with `dry_run:false` only when the iPhone-to-Pi management link
does not depend on the target interface. The daemon uses `iw reg set` and
`nmcli device wifi connect`, then persists only the SSID/interface/country and a
`psk_configured` flag.

Stop active RF and spectrum streams through the authenticated control plane:

```bash
curl -s -X POST http://<PI_HOST>:17321/capture/stop \
  -H "authorization: Bearer <token>"
```

## Monitor-Mode Capture

Generate the monitor-mode command plan for a radio (here `wlan2` on 5180 MHz):

```bash
curl -s -X POST http://<PI_HOST>:17321/radios/monitor-plan \
  -H "content-type: application/json" \
  -d '{"interface_name":"wlan2","frequency_mhz":5180}'
```

Dry-run the authenticated monitor preparation endpoint:

```bash
curl -s -X POST http://<PI_HOST>:17321/radios/prepare-monitor \
  -H "content-type: application/json" \
  -H "authorization: Bearer <token>" \
  -d '{"interface_name":"wlan2","frequency_mhz":5180,"dry_run":true}'
```

Set `dry_run:false` to prepare the interface for real monitor-mode capture. Keep
the management interface out of the capture set so the Pi stays reachable, and
prepare each USB radio you intend to capture with.

## Streaming Observations

Open the observation WebSocket — one per radio. The iOS app uses the same
endpoint with an `Authorization: Bearer <token>` header. Frames with opcode `2`
are binary Arrow IPC streams containing RF observation record batches.

```text
ws://<PI_HOST>:17321/observations/stream?interface_name=wlan2&sidekick_id=sidekick-1&radio_id=wlan2
```

To let the daemon hop channels for a stream, add `frequencies_mhz` and
`hop_interval_ms`. The hopper is tied to that WebSocket and stops when the
stream closes.

```text
ws://<PI_HOST>:17321/observations/stream?interface_name=wlan2&sidekick_id=sidekick-1&radio_id=wlan2&frequencies_mhz=5180,5200,5220,5240&hop_interval_ms=250
```

A quiet channel can correctly produce no batches until a beacon or
probe-response appears.

In iOS auto mode, FieldSurvey ignores the management interface, chooses
monitor-capable USB radios, sorts them by USB link speed, assigns the fastest
radio to the 5 GHz survey plan, and assigns the next radio to the 2.4 GHz
non-overlapping channel plan. Explicit settings can override this, for example
`wlan1:2412|2437|2462,wlan2:5180|5200|5220|5240`.

Open the HackRF spectrum WebSocket for channel-energy/interference data. Frames
with opcode `2` are binary Arrow IPC streams containing spectrum sweep record
batches with `power_bins_dbm` list columns.

```text
ws://<PI_HOST>:17321/spectrum/stream?sidekick_id=sidekick-1&sdr_id=hackrf-0&serial_number=<hackrf-serial>&frequency_min_mhz=2400&frequency_max_mhz=2500&bin_width_hz=1000000&lna_gain_db=8&vga_gain_db=8&sweep_count=1024
```

For unknown or modified HackRF hardware, keep `lna_gain_db` and `vga_gain_db`
conservative, keep `amp` off, and do not use transmit tooling. The Sidekick
passes an explicit `sweep_count` to `hackrf_sweep` because some Pi/HackRF
toolchains complete zero sweeps when no count is provided.

## Adapter and Monitor-Mode Notes

Supported survey adapters must expose Linux monitor mode and radiotap metadata
through `iw`. The verified adapters are:

- Ralink RT5572 with `rt2800usb`
- MediaTek MT7612U with `mt76x2u`

Basic adapter checks:

```bash
iw dev
iw phy | sed -n "/Supported interface modes:/,/Band /p"
lsusb -t
```

The service runs as root with `CAP_NET_ADMIN` and `CAP_NET_RAW` because it
configures Wi-Fi interfaces, opens `AF_PACKET` sockets, and may configure
NetworkManager Wi-Fi uplink state.

No udev rule is required for the current root-owned service, but production
units should add stable interface naming or serial-based inventory rules if USB
enumeration order changes between boots.

If monitor setup fails:

- Confirm the interface is not the management uplink.
- Confirm NetworkManager is not reconnecting the capture interface.
- Confirm the requested frequency is valid for the adapter and regulatory
  country.
- Check `journalctl -u serviceradar-fieldsurvey-sidekick.service` and
  `/var/log/serviceradar/fieldsurvey-sidekick-error.log`.

Kismet is useful as a comparison tool but is not required for the product path.
Use it only to compare adapter behavior, visible BSSIDs, or channel activity
when validating a new dongle.

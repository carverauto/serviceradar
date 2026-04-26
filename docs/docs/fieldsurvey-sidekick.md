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

## Current Test Hardware

The first lab Pi is reachable at `192.168.1.74` as `mfreeman`.

- OS: Debian 13 `trixie`
- Kernel: Raspberry Pi `6.12.75+rpt-rpi-v8`
- Built-in Wi-Fi: `wlan0`, `brcmfmac`, managed client connection
- USB radio 1: `wlan1`, Ralink RT5572, driver `rt2800usb`, monitor capable,
  USB2 at 480 Mbps
- USB radio 2: `wlan2`, MediaTek MT7612U, driver `mt76x2u`, monitor capable,
  USB3 at 5000 Mbps
- SDR: HackRF One, serial `0000000000000000f77c60dc299165c3`, high-speed USB2
  at 480 Mbps

Do not use `wlan0` for capture while it is providing management connectivity.
Use `wlan1` and `wlan2` for monitor-mode survey work.
Treat the HackRF as receive-only unless the hardware modification history is
known. The Sidekick spectrum path starts `hackrf_sweep` with RX amp disabled and
antenna power disabled.

## Transport Status

Treat the iPhone-to-Pi connection as IP transport. The lab unit currently uses
LAN reachability rather than USB networking:

- `eth0`: `192.168.1.73/24`
- `wlan0`: `192.168.1.74/24`

No USB gadget, tethering, or other USB network interface was visible on the Pi
during validation. USB networking remains the preferred field transport when it
is available, but the current development path uses `http://192.168.1.74:17321`
and `ws://192.168.1.74:17321`.

## Local Cross-Build

Install the Linux ARM64 Rust standard library once:

```bash
rustup target add aarch64-unknown-linux-gnu
```

The repo-local Cargo config uses `aarch64-linux-gnu-gcc` for that target.
Build the daemon for the Pi:

```bash
cargo build -p serviceradar-fieldsurvey-sidekick --target aarch64-unknown-linux-gnu
```

Copy the binary to the Pi for smoke testing:

```bash
scp target/aarch64-unknown-linux-gnu/debug/serviceradar-fieldsurvey-sidekick \
  mfreeman@192.168.1.74:/tmp/serviceradar-fieldsurvey-sidekick.new
```

## Systemd Install

The repository includes a documented systemd install path under
`build/packaging/fieldsurvey-sidekick/`.

Install or update the daemon on the Pi:

```bash
scp target/aarch64-unknown-linux-gnu/debug/serviceradar-fieldsurvey-sidekick \
  mfreeman@192.168.1.74:/tmp/serviceradar-fieldsurvey-sidekick.new

scp build/packaging/fieldsurvey-sidekick/config/fieldsurvey-sidekick.toml \
  build/packaging/fieldsurvey-sidekick/config/fieldsurvey-sidekick.env.example \
  build/packaging/fieldsurvey-sidekick/systemd/serviceradar-fieldsurvey-sidekick.service \
  mfreeman@192.168.1.74:/tmp/

ssh mfreeman@192.168.1.74 '
  sudo -n install -m 0755 /tmp/serviceradar-fieldsurvey-sidekick.new \
    /usr/local/bin/serviceradar-fieldsurvey-sidekick
  sudo -n install -d -m 0755 /etc/serviceradar
  sudo -n install -m 0644 /tmp/fieldsurvey-sidekick.toml \
    /etc/serviceradar/fieldsurvey-sidekick.toml
  sudo -n install -m 0600 /tmp/fieldsurvey-sidekick.env.example \
    /etc/serviceradar/fieldsurvey-sidekick.env
  sudo -n install -m 0644 /tmp/serviceradar-fieldsurvey-sidekick.service \
    /etc/systemd/system/serviceradar-fieldsurvey-sidekick.service
  sudo -n systemd-analyze verify \
    /etc/systemd/system/serviceradar-fieldsurvey-sidekick.service
  sudo -n systemctl daemon-reload
  sudo -n systemctl enable --now serviceradar-fieldsurvey-sidekick.service
'
```

Before field use, replace `SERVICERADAR_SIDEKICK_API_TOKEN=change-me` in
`/etc/serviceradar/fieldsurvey-sidekick.env`.

Runtime paths:

- Binary: `/usr/local/bin/serviceradar-fieldsurvey-sidekick`
- Config: `/etc/serviceradar/fieldsurvey-sidekick.toml`
- Environment/token file: `/etc/serviceradar/fieldsurvey-sidekick.env`
- Persisted runtime config:
  `/var/lib/serviceradar/fieldsurvey-sidekick/runtime-config.json`
- Logs:
  `/var/log/serviceradar/fieldsurvey-sidekick.log` and
  `/var/log/serviceradar/fieldsurvey-sidekick-error.log`

Useful checks:

```bash
ssh mfreeman@192.168.1.74 \
  'sudo -n systemctl status serviceradar-fieldsurvey-sidekick.service --no-pager'

curl -s http://192.168.1.74:17321/healthz
curl -s http://192.168.1.74:17321/status
```

## Pairing Workflow

`SERVICERADAR_SIDEKICK_API_TOKEN` is the setup/admin token. Use it to claim a
paired device token from the iOS app or with curl:

```bash
curl -s -X POST http://192.168.1.74:17321/pairing/claim \
  -H "authorization: Bearer test-token" \
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

## Smoke Test

The preferred smoke test is the systemd service above. For temporary local
testing, run the daemon as root for radio setup and raw packet capture.
Mutating endpoints and observation streams require a bearer token from
`SERVICERADAR_SIDEKICK_API_TOKEN` or `api_token` in the daemon config.

```bash
ssh mfreeman@192.168.1.74 \
  'sudo -n fuser -k 17321/tcp 2>/dev/null || true;
   sudo -n mv /tmp/serviceradar-fieldsurvey-sidekick.new /tmp/serviceradar-fieldsurvey-sidekick;
   sudo -n chmod 0755 /tmp/serviceradar-fieldsurvey-sidekick;
   sudo -n env SERVICERADAR_SIDEKICK_API_TOKEN=test-token \
     /tmp/serviceradar-fieldsurvey-sidekick --listen-addr 0.0.0.0:17321 \
       > /tmp/serviceradar-fieldsurvey-sidekick.log 2>&1 &'
```

Check radio inventory:

```bash
ssh mfreeman@192.168.1.74 \
  'curl -s http://127.0.0.1:17321/status'
```

`/status` includes `capture_running` and `active_streams`, so the app can see
whether RF or spectrum WebSockets are currently registered.

Read the persisted runtime config. The file is stored under the daemon
`state_dir` as `runtime-config.json`.

```bash
curl -s http://192.168.1.74:17321/config \
  -H "authorization: Bearer test-token"
```

Update non-secret runtime config values:

```bash
curl -s -X PUT http://192.168.1.74:17321/config \
  -H "authorization: Bearer test-token" \
  -H "content-type: application/json" \
  -d '{"sidekick_id":"fieldsurvey-sidekick","radio_plans":[{"interface_name":"wlan2","frequencies_mhz":[5180,5200,5220],"hop_interval_ms":250}]}'
```

Plan a Pi Wi-Fi uplink configuration without changing the Pi. Responses redact
the passphrase.

```bash
curl -s -X POST http://192.168.1.74:17321/wifi/uplink-plan \
  -H "authorization: Bearer test-token" \
  -H "content-type: application/json" \
  -d '{"interface_name":"wlan0","ssid":"ExampleSSID","psk":"secret","country_code":"US","dry_run":true}'
```

Apply the uplink with `dry_run:false` only when the iPhone-to-Pi management link
does not depend on the target interface. The daemon uses `iw reg set` and
`nmcli device wifi connect`, then persists only the SSID/interface/country and a
`psk_configured` flag.

Stop active RF and spectrum streams through the authenticated control plane:

```bash
curl -s -X POST http://192.168.1.74:17321/capture/stop \
  -H "authorization: Bearer test-token"
```

Generate the monitor-mode command plan for `wlan2` on 5180 MHz:

```bash
ssh mfreeman@192.168.1.74 \
  'curl -s -X POST http://127.0.0.1:17321/radios/monitor-plan \
     -H "content-type: application/json" \
     -d "{\"interface_name\":\"wlan2\",\"frequency_mhz\":5180}"'
```

Dry-run the authenticated monitor preparation endpoint:

```bash
ssh mfreeman@192.168.1.74 \
  'curl -s -X POST http://127.0.0.1:17321/radios/prepare-monitor \
     -H "content-type: application/json" \
     -H "authorization: Bearer test-token" \
     -d "{\"interface_name\":\"wlan2\",\"frequency_mhz\":5180,\"dry_run\":true}"'
```

Prepare `wlan2` for real monitor-mode capture on channel 36:

```bash
ssh mfreeman@192.168.1.74 \
  'curl -s -X POST http://127.0.0.1:17321/radios/prepare-monitor \
     -H "content-type: application/json" \
     -H "authorization: Bearer test-token" \
     -d "{\"interface_name\":\"wlan2\",\"frequency_mhz\":5180,\"dry_run\":false}" &&
   sudo -n /usr/sbin/iw dev wlan2 info'
```

Prepare both USB radios for simultaneous capture, keeping `wlan0` as the Pi's
management interface:

```bash
ssh mfreeman@192.168.1.74 \
  'curl -s -X POST http://127.0.0.1:17321/radios/prepare-monitor \
     -H "content-type: application/json" \
     -H "authorization: Bearer test-token" \
     -d "{\"interface_name\":\"wlan1\",\"frequency_mhz\":2412,\"dry_run\":false}" &&
   curl -s -X POST http://127.0.0.1:17321/radios/prepare-monitor \
     -H "content-type: application/json" \
     -H "authorization: Bearer test-token" \
     -d "{\"interface_name\":\"wlan2\",\"frequency_mhz\":5180,\"dry_run\":false}" &&
   sudo -n /usr/sbin/iw dev wlan1 info &&
   sudo -n /usr/sbin/iw dev wlan2 info'
```

Open the observation WebSocket. The iOS app should use the same endpoint with
an `Authorization: Bearer <token>` header. Frames with opcode `2` are binary
Arrow IPC streams containing RF observation record batches.

```text
ws://192.168.1.74:17321/observations/stream?interface_name=wlan2&sidekick_id=sidekick-1&radio_id=wlan2
```

To let the daemon hop channels for a stream, add `frequencies_mhz` and
`hop_interval_ms`. The hopper is tied to that WebSocket and stops when the
stream closes.

```text
ws://192.168.1.74:17321/observations/stream?interface_name=wlan2&sidekick_id=sidekick-1&radio_id=wlan2&frequencies_mhz=5180,5200,5220,5240&hop_interval_ms=250
```

Open one WebSocket per radio when capturing both adapters. In the lab smoke
test, `wlan1` produced Arrow frames on 2412 MHz and `wlan2` produced Arrow
frames on 5220 MHz. A quiet channel can correctly produce no batches until a
beacon/probe-response appears.

In iOS auto mode, FieldSurvey ignores `wlan0`, chooses monitor-capable USB
radios, sorts them by USB link speed, assigns the fastest radio to the 5 GHz
survey plan, and assigns the next radio to the 2.4 GHz non-overlapping channel
plan. Explicit settings can override this with
`wlan1:2412|2437|2462,wlan2:5180|5200|5220|5240`.

Open the HackRF spectrum WebSocket for channel-energy/interference data. Frames
with opcode `2` are binary Arrow IPC streams containing spectrum sweep record
batches with `power_bins_dbm` list columns.

```text
ws://192.168.1.74:17321/spectrum/stream?sidekick_id=sidekick-1&sdr_id=hackrf-0&serial_number=0000000000000000f77c60dc299165c3&frequency_min_mhz=2400&frequency_max_mhz=2500&bin_width_hz=1000000&lna_gain_db=8&vga_gain_db=8&sweep_count=1024
```

For unknown or modified HackRF hardware, keep `lna_gain_db` and `vga_gain_db`
conservative, keep `amp` off, and do not use transmit tooling. A one-shot lab
sweep over 2400-2500 MHz at 1 MHz bins completed at about 20 sweeps/sec on the
current Pi. The Sidekick passes an explicit `sweep_count` to `hackrf_sweep`
because the current Pi/HackRF toolchain completes zero sweeps when no count is
provided.

Stop the test daemon:

```bash
ssh mfreeman@192.168.1.74 'sudo -n fuser -k 17321/tcp 2>/dev/null || true'
```

For the installed service, use:

```bash
ssh mfreeman@192.168.1.74 \
  'sudo -n systemctl stop serviceradar-fieldsurvey-sidekick.service'
```

## Adapter and Monitor-Mode Notes

Supported survey adapters must expose Linux monitor mode and radiotap metadata
through `iw`. The current verified adapters are:

- Ralink RT5572 with `rt2800usb`
- MediaTek MT7612U with `mt76x2u`

Basic adapter checks:

```bash
ssh mfreeman@192.168.1.74 '
  /usr/sbin/iw dev
  /usr/sbin/iw phy | sed -n "/Supported interface modes:/,/Band /p"
  lsusb -t
'
```

The service currently runs as root with `CAP_NET_ADMIN` and `CAP_NET_RAW`
because it configures Wi-Fi interfaces, opens `AF_PACKET` sockets, and may
configure NetworkManager Wi-Fi uplink state. A later hardening pass can split
radio setup into a smaller privileged helper.

No udev rule is required for the current root-owned service, but production
units should add stable interface naming or serial-based inventory rules if USB
enumeration order changes between boots.

If monitor setup fails:

- Confirm the interface is not the management uplink. On the lab Pi, keep
  `wlan0` managed and reserve `wlan1`/`wlan2` for monitor capture.
- Confirm NetworkManager is not reconnecting the capture interface.
- Confirm the requested frequency is valid for the adapter and regulatory
  country.
- Check `journalctl -u serviceradar-fieldsurvey-sidekick.service` and
  `/var/log/serviceradar/fieldsurvey-sidekick-error.log`.

Kismet is useful as a comparison tool but is not required for the product path.
Use it only to compare adapter behavior, visible BSSIDs, or channel activity
when validating a new dongle.

## Next Implementation Step

The current daemon exposes health, radio inventory, persisted runtime config,
Wi-Fi uplink planning/application, authenticated monitor setup, capture stop,
radiotap/802.11 parsing, channel hopping, and authenticated RF/spectrum
WebSockets backed by `AF_PACKET`/`TPACKET_V3` and `hackrf_sweep`.

The backend golden-path ingest endpoints are authenticated WebSockets:

- RF observations:
  `wss://<serviceradar-host>/v1/field-survey/<session_id>/rf-observations`
- iOS pose samples:
  `wss://<serviceradar-host>/v1/field-survey/<session_id>/pose-samples`
- SDR spectrum observations:
  `wss://<serviceradar-host>/v1/field-survey/<session_id>/spectrum-observations`

All endpoints accept binary Apache Arrow IPC stream frames. RF observation
batches persist to `platform.survey_rf_observations`; pose batches persist to
`platform.survey_pose_samples`; spectrum batches persist to
`platform.survey_spectrum_observations`. Fusion should use `session_id` plus the
nanosecond wall-clock and monotonic timestamp columns.
`platform.survey_rf_pose_matches` exposes the first database fusion surface by
joining each RF observation to the nearest pose sample in the same session
within a 200 ms window and reporting `pose_offset_nanos`.

The iOS app's live-stream control now starts raw FieldSurvey streams alongside
the existing final-sample streamer. The Sidekick relay keeps the Sidekick
payloads as Arrow IPC bytes and forwards them directly:

- `/observations/stream` on the Pi to `/v1/field-survey/<session_id>/rf-observations`
- `/spectrum/stream` on the Pi to `/v1/field-survey/<session_id>/spectrum-observations`
- ARKit camera pose samples to `/v1/field-survey/<session_id>/pose-samples`

This keeps the iPhone out of the high-rate decode/re-encode path. The app still
decodes a preview copy of each RF batch into `SurveySample` and heatmap points
using the latest ARKit pose, so the live walk view can show Sidekick BSSIDs
without changing the raw persistence path. `RealWiFiScanner` now receives
native Wi-Fi, HotspotHelper, BLE, subnet, manual, and Sidekick samples through a
shared source-event ingest path; `SidekickScannerAdapter` owns the
Sidekick-observation-to-preview-sample mapping. The existing final
`SurveySample` stream remains for current local samples until database-side
fused survey sample/materialized view generation is added.

The next slice is backend/API verification and end-to-end row checks:

- verify an end-to-end survey writes raw RF, pose, spectrum, and fused rows in
  the database

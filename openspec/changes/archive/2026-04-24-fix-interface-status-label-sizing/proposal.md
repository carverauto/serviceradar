# Change: Fix network interface status label sizing

## Why

Network interface status badges ("Up", "Down", "Enabled", "Disabled", etc.) render at varying widths due to different text lengths, causing visual misalignment in the interface list table. This makes the UI appear inconsistent and harder to scan.

## What Changes

- Add fixed minimum width to interface status badges so all labels render at consistent sizes
- Oper status badges ("Up", "Down", "Testing", "Unknown") will have uniform width
- Admin status badges ("Enabled", "Disabled", "Testing", "Unknown") will have uniform width
- Accessibility: existing icons already provide non-color differentiation (arrow-up, arrow-down, check-circle, pause-circle)

## Impact

- Affected specs: `build-web-ui`
- Affected code:
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/device_live/show.ex` (interface list in device details)
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/interface_live/show.ex` (interface detail header)

## References

- GitHub Issue: #2438

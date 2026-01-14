# Change: Fix Devices Page Sysmon Badge Crash

## Why
The Devices list page crashes when sysmon profile data is missing or malformed, preventing operators from viewing inventory. The UI should render safely with clear fallback labels instead of raising errors.

## What Changes
- Update Devices list sysmon badge rendering to handle missing or malformed sysmon profile/status data without exceptions.
- Display fallback labels for unassigned/unknown sysmon profile and status.
- Add regression coverage for devices with missing sysmon data.

## Impact
- Affected specs: build-web-ui
- Affected code: web-ng DeviceLive devices list rendering (sysmon profile badge helper), related UI components/tests

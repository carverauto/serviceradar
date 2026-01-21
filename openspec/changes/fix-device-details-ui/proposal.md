# Change: Device details UI improvements

## Why
Operators need visibility into IP aliases recorded by DIRE to understand how devices are being deduplicated and resolved. Today those alias records are hidden, making troubleshooting device identity issues harder.

## What Changes
- Surface IP alias information on the device detail page (alias value, state, last seen, sightings).
- Add a toggle to include/exclude alias states that are stale/archived.

## Impact
- Affected specs: build-web-ui
- Affected code: web-ng device details LiveView + data loading

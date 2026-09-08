# Change: Add device active lifecycle semantics

## Why
Operators need to mark devices out of service without deleting inventory history. An inactive device should remain visible for audit and integration context, but it must not count as active inventory for future licensing or generate operational events/alerts while intentionally out of service.

## What Changes
- Add first-class device active/inactive lifecycle semantics for `ocsf_devices`.
- Expose controls and state in web-ng device list/details so operators can mark a device in or out of service.
- Exclude inactive devices from future license-accounted inventory totals.
- Suppress device-scoped event and alert generation for inactive devices while preserving raw telemetry/log ingestion for auditability.

## Impact
- Affected specs: `device-inventory`, `observability-signals`
- Affected code: `elixir/serviceradar_core` inventory resources/actions, event/alert promotion paths, web-ng device list/details UI, integration ingestion policy

## 1. Investigation

- [x] 1.1 Confirm stale behavior is isolated to Device Details view (Devices list ICMP sparkline continues refreshing)
- [x] 1.2 Inspect Device Details code path - Metrics are fetched via SRQL (`/api/query`) and are not polled/revalidated
- [x] 1.3 Identify root cause - `DeviceDetail.tsx` performs one-shot fetches and freezes the “now” time window end

## 2. Implementation

- [x] 2.1 Revert API-key auth context injection workaround in `pkg/core/api/server.go`
- [x] 2.2 Add periodic auto-refresh to `web/src/components/Devices/DeviceDetail.tsx` without UI flicker (silent refresh)
- [ ] 2.3 Add/confirm regression coverage (if existing web tests exist for polling behavior)

## 3. Verification

- [ ] 3.1 Deploy to demo namespace
- [ ] 3.2 Leave Device Details open >1h; confirm “Latest ICMP RTT” timestamp advances
- [ ] 3.3 Confirm Device Metrics Timeline includes recent points without requiring a page reload

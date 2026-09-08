## 1. Implementation

- [x] 1.1 Add helper function `to_float/1` in networks_live/index.ex to safely convert any number to float
- [x] 1.2 Update `scanner_metrics_grid/1` to ensure `rx_drop_rate_percent` is a float when assigned
- [x] 1.3 Audit line 1595 (`@aggregate_metrics.avg_drop_rate`) for same issue and fix if needed
- [ ] 1.4 Add tests to verify metrics grid handles integer `0` values without crashing

## 2. Verification

- [ ] 2.1 Manually test Active Scans tab with executions that have `rx_drop_rate_percent: 0`
- [ ] 2.2 Confirm no FunctionClauseError in logs when switching to Active Scans tab

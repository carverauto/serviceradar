## 1. Proposal
- [x] 1.1 Validate OpenSpec proposal with strict mode.
- [x] 1.2 Get approval before implementation.

## 2. Data Model And Queries
- [x] 2.1 Add `MtrData.compare_windows/1` for aligned aggregate window summaries.
- [x] 2.2 Add bucketed timeline query for retained trace activity/reachability over the selected outer range.
- [x] 2.3 Add dominant path-signature query with representative trace IDs and source-agent breakdown.
- [x] 2.4 Add focused tests for partial-period alignment and uneven sample counts.

## 3. Comparison UI
- [x] 3.1 Preserve the existing trace-to-trace comparison mode.
- [x] 3.2 Add window comparison mode with presets, filters, and custom datetime controls.
- [x] 3.3 Add comparison stat cards, deltas, timeline strips, and route-signature visuals.
- [x] 3.4 Add drill-down links from windows/segments to filtered MTR diagnostics trace lists.
- [x] 3.5 Ensure light and dark theme styling is polished on desktop and mobile.

## 4. Validation
- [x] 4.1 Run web-ng CSS build and compile checks.
- [x] 4.2 Run focused MTR data tests against `srql-fixtures` when DB-backed validation is needed.
- [x] 4.3 Capture Playwright screenshots for trace and window comparison in light/dark desktop/mobile.

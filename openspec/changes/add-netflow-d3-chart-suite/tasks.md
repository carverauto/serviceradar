## 1. Spec And Design
- [x] 1.1 Identify the hook API for all chart types (data attributes, events)

## 2. Shared D3 Utilities
- [x] 2.1 Add a small chart utility module (sizing + palette helpers)

## 3. Chart Hooks
- [x] 3.1 Stacked area (standardize existing)
- [x] 3.2 100% stacked area (new)
- [x] 3.3 Line series (new)
- [x] 3.4 Grid (small multiples) (new)
- [x] 3.5 Sankey (standardize existing)

## 4. /netflow Wiring
- [x] 4.1 Load SRQL-driven datasets for selected chart type
- [x] 4.2 Render selected chart type on `/netflow`

## 5. Validation
- [x] 5.1 Run `openspec validate add-netflow-d3-chart-suite --strict`
- [x] 5.2 Run repo checks (`make lint`, `make test`)

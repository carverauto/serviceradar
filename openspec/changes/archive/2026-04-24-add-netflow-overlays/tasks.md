## 1. Spec And Design
- [x] 1.1 Confirm overlay semantics for v1 (lines only, best-effort reverse query)
- [x] 1.2 Confirm how previous-period is computed for relative vs absolute SRQL time ranges

## 2. Visualize UI
- [x] 2.1 Add toggles in `/netflow` left panel for bidirectional + previous period
- [x] 2.2 Add UX hint when overlays are not supported by the selected graph type

## 3. Dataset Construction (SRQL)
- [x] 3.1 Implement best-effort SRQL query reversal for bidirectional overlays
- [x] 3.2 Implement previous-period time range computation and time-shift alignment
- [x] 3.3 Merge overlay datasets into a single chart payload

## 4. Chart Rendering
- [x] 4.1 Render reverse/previous overlays in D3 line chart (dash/opacity)
- [x] 4.2 Keep legend toggles working with overlay series
- [x] 4.3 Render reverse/previous total overlays on stacked area chart (dashed line overlays)
- [x] 4.4 Render reverse/previous composition overlays on 100% stacked chart (dashed boundaries)

## 5. Validation
- [x] 5.1 Run `openspec validate add-netflow-overlays --strict`
- [x] 5.2 Run repo checks (`make lint`, `make test`)

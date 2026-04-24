## 1. Spec And Design
- [x] 1.1 Confirm URL state param name (`nf`) and prefix format (`v1-`)
- [x] 1.2 Confirm redirect behavior from `/observability` netflows tab and `/netflows`

## 2. Web-NG Routing
- [x] 2.1 Add `live "/netflow"` route and new LiveView module (Visualize page skeleton)
- [x] 2.2 Implement redirect from `/netflows` to `/netflow` (or alias)
- [x] 2.3 Implement redirect from `/observability?...tab=netflows` to `/netflow` preserving SRQL query param `q`

## 3. URL State Codec (Visualize Options)
- [x] 3.1 Define `NetflowVisualizeState` schema (graph type, units, time preset/range, dimensions, options)
- [x] 3.2 Implement encode/decode with versioning and strict validation (bounded sizes)
- [x] 3.3 Round-trip tests for codec (`nf` param)

## 4. Visualize Page UI (Scaffolding)
- [x] 4.1 Left panel UI components (placeholders acceptable): time, graph type, units, options
- [x] 4.2 Right panel visualization surface + table placeholders
- [x] 4.3 Ensure SRQL query string is visible/editable and is not overwritten by builder when unsupported tokens are present
- [x] 4.4 Remove duplicate in-page SRQL bar; use the global topbar SRQL input only
- [x] 4.5 Add a paginated flows table and a working flow details affordance (modal)

## 5. SRQL Integration (Minimal)
- [x] 5.1 Execute SRQL query based on current state (initially reuse existing NetFlow SRQL patterns)
- [x] 5.2 Ensure no Ecto queries are used to generate chart data (SRQL only)

## 6. Validation
- [x] 6.1 Run `openspec validate add-netflow-visualize-page --strict`
- [x] 6.2 Run repo checks (`make lint`, `make test`)

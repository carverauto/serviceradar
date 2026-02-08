## 1. Spec And Design
- [ ] 1.1 Confirm URL state param name (`nf`) and prefix format (`v1-`)
- [ ] 1.2 Confirm redirect behavior from `/observability` netflows tab and `/netflows`

## 2. Web-NG Routing
- [ ] 2.1 Add `live "/netflow"` route and new LiveView module (Visualize page skeleton)
- [ ] 2.2 Implement redirect from `/netflows` to `/netflow` (or alias)
- [ ] 2.3 Implement redirect from `/observability?...tab=netflows` to `/netflow` preserving SRQL query param `q`

## 3. URL State Codec (Visualize Options)
- [ ] 3.1 Define `NetflowVisualizeState` schema (graph type, units, time preset/range, dimensions, options)
- [ ] 3.2 Implement encode/decode with versioning and strict validation (bounded sizes)
- [ ] 3.3 Round-trip tests for codec (`nf` param)

## 4. Visualize Page UI (Scaffolding)
- [ ] 4.1 Left panel UI components (placeholders acceptable): time, graph type, units, options
- [ ] 4.2 Right panel visualization surface + table placeholders
- [ ] 4.3 Ensure SRQL query string is visible/editable and is not overwritten by builder when unsupported tokens are present

## 5. SRQL Integration (Minimal)
- [ ] 5.1 Execute SRQL query based on current state (initially reuse existing NetFlow SRQL patterns)
- [ ] 5.2 Ensure no Ecto queries are used to generate chart data (SRQL only)

## 6. Validation
- [ ] 6.1 Run `openspec validate add-netflow-visualize-page --strict`
- [ ] 6.2 Run repo checks (`make lint`, `make test`)

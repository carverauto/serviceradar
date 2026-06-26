## 1. Data Projection

- [x] 1.1 Extend anomaly row projection to preserve window, peak/value, threshold, disposition, and effective severity metadata when present.
- [x] 1.2 Extend capacity row projection to preserve projected runway, threshold, confidence bounds, and unit metadata needed by charts.
- [x] 1.3 Add tests for current sparse rows and future richer rows from `add-anomaly-finding-disposition`.

## 2. Overlay Mapping

- [x] 2.1 Introduce a normalized chart overlay structure separate from the existing list rows.
- [ ] 2.2 Map anomaly overlays to CPU, memory, disk, and process-count sysmon sections using metric class/name and normalized series keys.
- [x] 2.3 Map capacity overlays to disk/capacity-compatible sections using resource key/label and metric name.
- [x] 2.4 Keep unmatched rows visible in the anomaly/capacity panel but out of chart overlays.

## 3. Chart Rendering

- [x] 3.1 Render point anomaly markers with tooltip context for title, severity/disposition, value, score, and time.
- [x] 3.2 Render anomaly windows as translucent bands when start/end are available.
- [x] 3.3 Render peak/value glyphs on matching series when a numeric value can be mapped into the chart domain.
- [x] 3.4 Render capacity forecast reference lines, projected runway segments, exhaustion markers, and optional confidence bands.
- [x] 3.5 Ensure hover tooltips continue to work for chart points and overlay marks without stealing pointer interaction.

## 4. UX Controls

- [x] 4.1 Add an unobtrusive per-section overlay legend/count so operators can tell why a marker is present.
- [x] 4.2 Preserve selected finding focus behavior and make selected overlays visually distinct.
- [x] 4.3 Avoid chart clutter by bounding default overlay count per chart.
- [x] 4.4 Cursor-page anomaly findings at five rows per page through SRQL limit/cursor options.
- [x] 4.5 Add severity/status/sort controls for the device findings list.
- [x] 4.6 Load selected finding modal metric context with SRQL queries bounded to the finding time window.

## 5. Verification

- [x] 5.1 Add focused LiveView/component tests for anomaly markers, windows, selected focus, and unmatched metadata.
- [x] 5.2 Add focused component tests for capacity forecast lines and out-of-window exhaustion dates.
- [ ] 5.3 Add JS chart tests for hover geometry with overlay SVG elements present.
- [x] 5.4 Validate against demo data locally with `$demo-cnpg-local-web-ng` and screenshots for CPU/disk pages with known findings.

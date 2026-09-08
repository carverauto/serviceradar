## Notes

- Overlays are modeled after Akvorado's `graph/line` behavior.
- All overlay datasets MUST be SRQL-driven.
- Bidirectional is best-effort: we swap directional filter tokens (`src_*` <-> `dst_*`) and use a directional series dimension mapping.
- Previous-period is aligned to the current x-axis by shifting timestamps forward by the window duration.
- For `stacked`, overlays are rendered as total-only dashed lines (not full per-series overlays) to avoid exploding legend/stack semantics.
- For `stacked100`, overlays are rendered as composition-only dashed boundaries (per-series y1 lines) since totals are always 100%.

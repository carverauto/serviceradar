/**
 * BandwidthGauge — arc gauge showing percent of capacity.
 *
 * This hook is intentionally minimal — the Elixir component handles all
 * formatting and severity calculation. This hook only exists to animate
 * the daisyUI radial-progress on mount/update if needed in the future.
 *
 * Currently a no-op placeholder; the component renders via pure CSS
 * (daisyUI radial-progress). Hook is registered so the component can
 * opt into JS-driven animation later without changing the HEEx template.
 */
export default {
  mounted() {},
  updated() {},
  destroyed() {},
}

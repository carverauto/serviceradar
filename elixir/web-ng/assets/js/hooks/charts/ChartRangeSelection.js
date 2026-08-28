import {hoverPosition, plotGeometryFromDataset} from "../../utils/chart_hover_geometry"
import ChartRangeSelectionController from "./ChartRangeSelectionController"
import {parseRangeBuckets} from "./chart_range_selection"

export default {
  mounted() {
    this.rangeSelectionEmitter = ({start, end}) => this.pushEvent(this.rangeEventName, {start, end})
    this.rangeController = new ChartRangeSelectionController(this.rangeSelectionOptions())
  },

  updated() {
    this.rangeController.update(this.rangeSelectionOptions())
  },

  destroyed() {
    this.rangeController?.destroy()
    this.rangeController = null
    this.rangeSelectionEmitter = null
  },

  rangeSelectionOptions() {
    const root = this.el
    const svg = root.querySelector("[data-range-svg]")
    const overlay = root.querySelector("[data-range-overlay]")
    const status = root.querySelector("[data-range-status]")
    const serializedBuckets = root.dataset.rangeBuckets
    const eventName = root.dataset.rangeEvent
    const buckets = parseRangeBuckets(serializedBuckets)
    this.rangeEventName = eventName

    return {
      bindingKey: `${serializedBuckets ?? ""}\u0000${eventName ?? ""}`,
      buckets,
      emit: typeof eventName === "string" && eventName.length > 0 ? this.rangeSelectionEmitter : null,
      eventKey: eventName,
      overlay,
      plotBounds: () => {
        const rect = svg?.getBoundingClientRect()
        if (!rect) return null
        const geometry = plotGeometryFromDataset(root, svg, rect)
        return {left: geometry.plotLeft, right: geometry.viewBoxWidth - geometry.plotRight}
      },
      root,
      status,
      svg,
      viewXForEvent: (event) => {
        const rect = svg?.getBoundingClientRect()
        if (!rect) return null
        const geometry = plotGeometryFromDataset(root, svg, rect)
        const position = hoverPosition(event.clientX, rect, geometry)
        return geometry.plotLeft + position.pct * geometry.plotWidth
      },
    }
  },
}

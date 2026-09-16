import {hoverPosition, plotGeometryFromDataset} from "../../utils/chart_hover_geometry"
import {netflowRangeSelectionStatus} from "../../netflow_charts/util"
import {adaptiveUserTimeAxis} from "../../utils/user_time"
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
    const timeZone = typeof root.dataset.timezone === "string" && root.dataset.timezone.trim() !== ""
      ? root.dataset.timezone
      : "Etc/UTC"
    const buckets = parseRangeBuckets(serializedBuckets)
    this.rangeEventName = eventName
    localizePointAxis(root, timeZone)

    return {
      bindingKey: `${serializedBuckets ?? ""}\u0000${eventName ?? ""}`,
      buckets,
      emit: typeof eventName === "string" && eventName.length > 0 ? this.rangeSelectionEmitter : null,
      eventKey: eventName,
      formatStatus: (range) => netflowRangeSelectionStatus(range, timeZone),
      overlay,
      plotBounds: () => {
        const rect = svg?.getBoundingClientRect()
        if (!rect) return null
        const geometry = plotGeometryFromDataset(root, svg, rect)
        return {left: geometry.plotLeft, right: geometry.viewBoxWidth - geometry.plotRight}
      },
      root,
      status,
      statusKey: timeZone,
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

function localizePointAxis(root, timeZone) {
  const labels = Array.from(root.querySelectorAll?.("[data-time-axis-iso]") || [])
  const times = labels.map((label) => Date.parse(label.dataset.timeAxisIso)).filter(Number.isFinite)
  if (times.length === 0) return

  const axis = adaptiveUserTimeAxis([Math.min(...times), Math.max(...times)], {timeZone})
  const grid = Array.from(root.querySelectorAll?.("[data-time-axis-grid]") || [])
  const seen = new Set()

  // Keep labels aligned with plotted bucket positions, including gapped input.
  // Long windows need fewer calendar labels than the original hourly ticks.
  labels.forEach((label, index) => {
    const canonical = label.dataset.timeAxisIso
    const formatted = axis.format(canonical)
    const text = formatted && formatted !== canonical
      ? formatted
      : label.dataset.timeAxisFallback || label.textContent
    const duplicate = axis.unit !== "hour" && seen.has(text)
    seen.add(text)
    label.textContent = text
    label.setAttribute("visibility", duplicate ? "hidden" : "visible")
    grid[index]?.setAttribute("visibility", duplicate ? "hidden" : "visible")
  })
}

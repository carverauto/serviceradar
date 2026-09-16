import {
  ensureTooltip as nfEnsureTooltip,
  netflowTimeAxis,
  netflowTimeDomain,
  netflowDisplayTimeZone,
  netflowRangeSelectionStatus,
  netflowTooltipTimeHtml,
  netflowTooltipTimeLabel,
  parseJSON as nfParseJSON,
} from "../../netflow_charts/util"
import {nfFormatRateValue} from "../../utils/formatters"
import ChartRangeSelectionController from "./ChartRangeSelectionController"
import {parseRangeBuckets} from "./chart_range_selection"

export default {
  mounted() {
    this._localizeTimeMarkers()
    this._bindTooltip()
    this._rangeEmitter = ({start, end}) => this.pushEvent(this._rangeEvent, {start, end})
    this.rangeController = new ChartRangeSelectionController(this._rangeOptions())
    this._bindClickArbiter()
  },
  updated() {
    this._unbindTooltip()
    this._localizeTimeMarkers()
    this._bindTooltip()
    this.rangeController.update(this._rangeOptions())
  },
  destroyed() {
    this._unbindTooltip()
    this._unbindClickArbiter()
    this.rangeController?.destroy()
    this.rangeController = null
    this._rangeEmitter = null
  },
  _bindTooltip() {
    const el = this.el
    const tooltip = nfEnsureTooltip(el)
    const points = nfParseJSON(el.dataset.points || "[]", [])
    const timeZone = netflowDisplayTimeZone(el.dataset.timezone)

    if (!Array.isArray(points) || points.length === 0) {
      tooltip.classList.add("hidden")
      return
    }

    const onMove = (evt) => {
      const rect = el.getBoundingClientRect()
      if (!rect || rect.width <= 0) return

      const x = evt.clientX - rect.left
      const y = evt.clientY - rect.top
      const ratio = Math.max(0, Math.min(1, x / rect.width))
      const idx = Math.max(0, Math.min(points.length - 1, Math.round(ratio * (points.length - 1))))
      const point = points[idx] || {}

      const bytes = Number(point.bytes || 0)
      const bucketSeconds = Math.max(1, Number(point.bucket_seconds || el.dataset.bucketSeconds || 1))
      const bps = (bytes * 8.0) / bucketSeconds

      tooltip.innerHTML = `
        <div class="text-[10px] text-base-content/60 font-mono">${netflowTooltipTimeHtml(point.start || "", timeZone)} → ${netflowTooltipTimeHtml(point.end || "", timeZone)}</div>
        <div class="mt-1 flex items-center justify-between gap-3">
          <span>Bytes</span><span class="font-mono">${escapeHtml(nfFormatRateValue("Bps", bytes))}</span>
        </div>
        <div class="flex items-center justify-between gap-3">
          <span>Rate</span><span class="font-mono">${escapeHtml(nfFormatRateValue("bps", bps))}</span>
        </div>
      `
      tooltip.classList.remove("hidden")

      const pad = 8
      const ttRect = tooltip.getBoundingClientRect()
      const maxLeft = rect.width - (ttRect.width || 220) - pad
      const left = Math.max(pad, Math.min(maxLeft, x + 12))
      const top = Math.max(pad, Math.min(rect.height - 52, y - 12))
      tooltip.style.left = `${left}px`
      tooltip.style.top = `${top}px`
    }

    const onLeave = () => tooltip.classList.add("hidden")

    el.addEventListener("mousemove", onMove)
    el.addEventListener("mouseleave", onLeave)

    this._tooltipCleanup = () => {
      el.removeEventListener("mousemove", onMove)
      el.removeEventListener("mouseleave", onLeave)
      tooltip.classList.add("hidden")
    }
  },
  _unbindTooltip() {
    try {
      this._tooltipCleanup?.()
    } catch (_e) {}
    this._tooltipCleanup = null
  },
  _localizeTimeMarkers() {
    localizeAxisMarkers(this.el)
    localizeRangeTitleMarkers(this.el)
  },
  _bindClickArbiter() {
    this._clickArbiter = (event) => {
      if (!this.rangeController?.consumeChartClick()) return
      event.preventDefault()
      event.stopImmediatePropagation()
    }
    this.el.addEventListener("click", this._clickArbiter, true)
  },
  _unbindClickArbiter() {
    if (this._clickArbiter) this.el.removeEventListener("click", this._clickArbiter, true)
    this._clickArbiter = null
  },
  _rangeOptions() {
    const root = this.el
    const svg = root.querySelector("[data-range-svg]")
    const overlay = root.querySelector("[data-range-overlay]")
    const status = root.querySelector("[data-range-status]")
    const serializedBuckets = root.dataset.rangeBuckets
    const eventName = root.dataset.rangeEvent
    const buckets = parseRangeBuckets(serializedBuckets)
    const timeZone = netflowDisplayTimeZone(root.dataset.timezone)
    this._rangeEvent = eventName

    const viewBox = svg?.getAttribute("viewBox")?.trim().split(/\s+/).map(Number)
    const viewWidth = viewBox?.length === 4 && Number.isFinite(viewBox[2]) ? viewBox[2] : Number(root.dataset.chartWidth)
    const viewHeight = viewBox?.length === 4 && Number.isFinite(viewBox[3]) ? viewBox[3] : Number(root.dataset.chartHeight)

    const viewPoint = (event, continuing = false) => {
      const rect = svg?.getBoundingClientRect()
      if (!rect || rect.width <= 0 || rect.height <= 0 || !Number.isFinite(viewWidth) || !Number.isFinite(viewHeight)) {
        return null
      }

      const x = ((event.clientX - rect.left) / rect.width) * viewWidth
      const y = ((event.clientY - rect.top) / rect.height) * viewHeight
      if (!continuing && (x < 0 || x > viewWidth || y < 10 || y > 150)) return null
      return Math.max(0, Math.min(viewWidth, x))
    }

    return {
      bindingKey: `${serializedBuckets ?? ""}\u0000${eventName ?? ""}`,
      buckets,
      continuationXForEvent: (event) => viewPoint(event, true),
      emit: typeof eventName === "string" && eventName.length > 0 ? this._rangeEmitter : null,
      eventKey: eventName,
      formatStatus: (range) => netflowRangeSelectionStatus(range, timeZone),
      overlay,
      plotBounds: () => ({left: 0, right: viewWidth}),
      root,
      status,
      statusKey: timeZone,
      svg,
      viewXForEvent: viewPoint,
    }
  },
}

function localizeAxisMarkers(root) {
  const buckets = parseRangeBuckets(root.dataset.rangeBuckets) || []
  const observed = buckets.length > 0 ? [buckets[0].start, buckets[buckets.length - 1].end] : []
  const domain = netflowTimeDomain(root.dataset, observed)
  const axis = netflowTimeAxis(root.dataset.timezone, domain, {count: 3})
  const nodes = Array.from(root.querySelectorAll("[data-netflow-time='axis']"))
  const bounds = domain.map((value) => new Date(value).getTime())
  const ticks = axis.ticks || (root.dataset.timeStart && bounds.every(Number.isFinite)
    ? bounds.map((value) => new Date(value)).flatMap((value, index) => index === 0
      ? [value, new Date((bounds[0] + bounds[1]) / 2)] : [value])
    : null)
  const step = ticks ? Math.max(1, Math.ceil(ticks.length / Math.max(nodes.length, 1))) : 1
  const selected = ticks?.filter((_tick, index) => index % step === 0)

  nodes.forEach((node, index) => {
    const canonical = selected ? selected[index] : node.getAttribute("data-time-iso") || ""
    if (!canonical) {
      node.textContent = ""
      return
    }
    const fallback = node.getAttribute("data-time-fallback") || ""
    const localized = axis.format(canonical)
    node.textContent = localized && localized !== canonical ? localized : fallback
    if (selected) {
      const x = (canonical.getTime() - bounds[0]) / (bounds[1] - bounds[0]) * Number(root.dataset.chartWidth || 1000)
      node.setAttribute("x", String(x))
      node.setAttribute("text-anchor", "middle")
    }
  })
}

function localizeRangeTitleMarkers(root) {
  const timeZone = netflowDisplayTimeZone(root.dataset.timezone)

  for (const node of root.querySelectorAll("[data-netflow-time='range-title']")) {
    const fallback = node.getAttribute("data-time-fallback") || ""
    const start = node.getAttribute("data-time-start") || ""
    const end = node.getAttribute("data-time-end") || ""
    node.textContent = fallback

    const localizedStart = netflowTooltipTimeLabel(start, timeZone)
    const localizedEnd = netflowTooltipTimeLabel(end, timeZone)
    if (localizedStart === start || localizedEnd === end) continue

    const [_windowLine, ...remainingLines] = fallback.split("\n")
    const localizedWindow =
      `window: ${localizedStart} (canonical UTC ${start}) → ` +
      `${localizedEnd} (canonical UTC ${end}); display zone ${timeZone}`
    node.textContent = [localizedWindow, ...remainingLines].join("\n")
  }
}

function escapeHtml(s) {
  return String(s || "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;")
}

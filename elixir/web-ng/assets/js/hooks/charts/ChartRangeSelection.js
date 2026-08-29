import {hoverPosition, plotGeometryFromDataset} from "../../utils/chart_hover_geometry"
import {
  nearestRangeBucketIndex,
  overlayForBucketIndexes,
  parseRangeBuckets,
  rangeForBucketIndexes,
} from "./chart_range_selection"

const DRAG_THRESHOLD_PX = 6

export default {
  mounted() {
    this.bindRangeSelection()
  },

  updated() {
    if (this.rangeBindingCurrent()) {
      if (this.rangeAnchorIndex !== null) this.renderRangeSelection()
      return
    }

    this.bindRangeSelection()
  },

  destroyed() {
    this.rangeCleanup?.()
    this.rangeCleanup = null
    this.resetRangeSelection()
  },

  bindRangeSelection() {
    this.rangeCleanup?.()
    this.rangeCleanup = null
    this.resetRangeSelection()

    this.rangeBuckets = null
    this.rangeSvg = null
    this.rangeOverlay = null
    this.rangeStatus = null
    this.rangeEventName = null
    this.rangeBucketsJSON = null

    const svg = this.el.querySelector("[data-range-svg]")
    const overlay = this.el.querySelector("[data-range-overlay]")
    const status = this.el.querySelector("[data-range-status]")
    const bucketsJSON = this.el.dataset.rangeBuckets
    const buckets = parseRangeBuckets(bucketsJSON)
    const eventName = this.el.dataset.rangeEvent

    if (!svg || !overlay || !status || !buckets || typeof eventName !== "string" || eventName.length === 0) {
      this.el.removeAttribute("tabindex")
      this.el.setAttribute("aria-disabled", "true")
      return
    }

    this.rangeBuckets = buckets
    this.rangeSvg = svg
    this.rangeOverlay = overlay
    this.rangeStatus = status
    this.rangeEventName = eventName
    this.rangeBucketsJSON = bucketsJSON
    this.rangeActiveIndex = buckets.length - 1
    this.el.setAttribute("tabindex", "0")
    this.el.removeAttribute("aria-disabled")
    status.setAttribute("aria-live", "polite")

    const onPointerDown = (event) => this.rangePointerDown(event)
    const onPointerMove = (event) => this.rangePointerMove(event)
    const onPointerUp = (event) => this.rangePointerUp(event)
    const onPointerCancel = (event) => this.rangePointerCancel(event)
    const onLostPointerCapture = (event) => this.rangeLostPointerCapture(event)
    const onKeyDown = (event) => this.rangeKeyDown(event)

    svg.addEventListener("pointerdown", onPointerDown)
    svg.addEventListener("pointermove", onPointerMove)
    svg.addEventListener("pointerup", onPointerUp)
    svg.addEventListener("pointercancel", onPointerCancel)
    svg.addEventListener("lostpointercapture", onLostPointerCapture)
    this.el.addEventListener("keydown", onKeyDown)

    this.rangeCleanup = () => {
      svg.removeEventListener("pointerdown", onPointerDown)
      svg.removeEventListener("pointermove", onPointerMove)
      svg.removeEventListener("pointerup", onPointerUp)
      svg.removeEventListener("pointercancel", onPointerCancel)
      svg.removeEventListener("lostpointercapture", onLostPointerCapture)
      this.el.removeEventListener("keydown", onKeyDown)
    }
  },

  rangeBindingCurrent() {
    return (
      this.rangeSvg === this.el.querySelector("[data-range-svg]") &&
      this.rangeOverlay === this.el.querySelector("[data-range-overlay]") &&
      this.rangeStatus === this.el.querySelector("[data-range-status]") &&
      this.rangeBucketsJSON === this.el.dataset.rangeBuckets &&
      this.rangeEventName === this.el.dataset.rangeEvent
    )
  },

  rangePointerDown(event) {
    if (this.rangePointer) return

    const index = this.rangeBucketIndexForEvent(event)
    if (index === null) return

    this.resetRangeSelection()
    this.rangePointer = {
      anchorIndex: index,
      clientX: event.clientX,
      moved: false,
      pointerId: event.pointerId,
    }
    this.rangeSvg.setPointerCapture(event.pointerId)
  },

  rangePointerMove(event) {
    const pointer = this.rangePointer
    if (!pointer || pointer.pointerId !== event.pointerId) return

    if (Math.abs(event.clientX - pointer.clientX) <= DRAG_THRESHOLD_PX) return

    const activeIndex = this.rangeBucketIndexForEvent(event)
    if (activeIndex === null) return

    pointer.moved = true
    this.rangeAnchorIndex = pointer.anchorIndex
    this.rangeActiveIndex = activeIndex
    this.renderRangeSelection()
  },

  rangePointerUp(event) {
    const pointer = this.rangePointer
    if (!pointer || pointer.pointerId !== event.pointerId) return

    const activeIndex = this.rangeBucketIndexForEvent(event)
    const moved =
      (pointer.moved || Math.abs(event.clientX - pointer.clientX) > DRAG_THRESHOLD_PX) && activeIndex !== null
    this.releaseRangePointerCapture()
    this.rangePointer = null

    if (!moved) {
      this.resetRangeSelection()
      return
    }

    this.rangeAnchorIndex = pointer.anchorIndex
    this.rangeActiveIndex = activeIndex
    this.renderRangeSelection()
    this.emitRangeSelection()
  },

  rangePointerCancel(event) {
    if (this.rangePointer?.pointerId !== event.pointerId) return

    this.resetRangeSelection()
  },

  rangeLostPointerCapture(event) {
    if (this.rangePointer?.pointerId !== event.pointerId) return

    this.resetRangeSelection()
  },

  rangeKeyDown(event) {
    const isArrow = event.key === "ArrowLeft" || event.key === "ArrowRight"
    if (!isArrow && event.key !== "Enter" && event.key !== "Escape") return

    event.preventDefault()

    if (event.key === "Escape") {
      this.cancelRangeSelection()
      return
    }

    if (event.key === "Enter") {
      this.emitRangeSelection()
      return
    }

    const direction = event.key === "ArrowLeft" ? -1 : 1
    const currentIndex = this.rangeActiveIndex ?? this.rangeBuckets.length - 1
    const nextIndex = Math.max(0, Math.min(this.rangeBuckets.length - 1, currentIndex + direction))

    if (event.shiftKey) {
      this.rangeAnchorIndex ??= currentIndex
      this.rangeActiveIndex = nextIndex
    } else {
      this.rangeAnchorIndex = nextIndex
      this.rangeActiveIndex = nextIndex
    }

    this.renderRangeSelection()
  },

  rangeBucketIndexForEvent(event) {
    if (!this.rangeSvg || !this.rangeBuckets) return null

    const rect = this.rangeSvg.getBoundingClientRect()
    const geometry = plotGeometryFromDataset(this.el, this.rangeSvg, rect)
    const position = hoverPosition(event.clientX, rect, geometry)
    const viewX = geometry.plotLeft + position.pct * geometry.plotWidth

    return nearestRangeBucketIndex(this.rangeBuckets, viewX)
  },

  renderRangeSelection() {
    const selectedRange = this.currentRangeSelection()
    const rect = this.rangeSvg?.getBoundingClientRect()
    if (!selectedRange || !rect) return

    const geometry = plotGeometryFromDataset(this.el, this.rangeSvg, rect)
    const overlay = overlayForBucketIndexes(
      this.rangeBuckets,
      this.rangeAnchorIndex,
      this.rangeActiveIndex,
      geometry.plotLeft,
      geometry.viewBoxWidth - geometry.plotRight,
    )
    if (!overlay) return

    this.rangeOverlay.setAttribute("x", overlay.x)
    this.rangeOverlay.setAttribute("width", overlay.width)
    this.rangeOverlay.classList.remove("hidden")
    this.rangeStatus.textContent = `Selected ${selectedRange.start} to ${selectedRange.end}`
  },

  emitRangeSelection() {
    const selectedRange = this.currentRangeSelection()
    if (!selectedRange || !this.rangeEventName) return

    this.pushEvent(this.rangeEventName, {start: selectedRange.start, end: selectedRange.end})
  },

  resetRangeSelection() {
    this.cancelRangeSelection()
    this.rangeActiveIndex = null
  },

  cancelRangeSelection() {
    this.releaseRangePointerCapture()
    this.rangePointer = null
    this.rangeAnchorIndex = null
    this.rangeOverlay?.classList.add("hidden")
    this.rangeOverlay?.removeAttribute("x")
    this.rangeOverlay?.removeAttribute("width")
    if (this.rangeStatus) this.rangeStatus.textContent = ""
  },

  currentRangeSelection() {
    const activeIndex = this.rangeActiveIndex
    const anchorIndex = this.rangeAnchorIndex ?? activeIndex
    return rangeForBucketIndexes(this.rangeBuckets, anchorIndex, activeIndex)
  },

  releaseRangePointerCapture() {
    const pointer = this.rangePointer
    if (!pointer || !this.rangeSvg) return

    if (typeof this.rangeSvg.hasPointerCapture === "function" && !this.rangeSvg.hasPointerCapture(pointer.pointerId)) {
      return
    }

    this.rangeSvg.releasePointerCapture(pointer.pointerId)
  },
}

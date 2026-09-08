import {
  nearestRangeBucketIndex,
  overlayForBucketIndexes,
  rangeForBucketIndexes,
  validRangeBuckets,
} from "./chart_range_selection"

const DRAG_THRESHOLD_PX = 6

export default class ChartRangeSelectionController {
  constructor(options) {
    this.options = null
    this.pointer = null
    this.anchorIndex = null
    this.activeIndex = null
    this.suppressChartClick = false
    this.cleanup = null
    this.gestureCleanup = null
    this.clickCleanup = null
    this.update(options)
  }

  update(options) {
    const normalized = this.normalizeOptions(options)
    const unchanged = this.options && this.bindingIsUnchanged(normalized)

    if (unchanged) {
      const statusChanged = this.options.statusKey !== normalized.statusKey
      this.options = normalized
      if (statusChanged && normalized.enabled && !normalized.overlay.classList.contains("hidden")) {
        this.renderSelection()
      }
      return
    }

    if (this.pointer && this.gestureBindingIsCompatible(normalized)) {
      const svgChanged = this.options.svg !== normalized.svg

      if (svgChanged) {
        this.unbind()
        this.options = normalized
        this.bind()
      } else {
        this.options = normalized
        normalized.status.setAttribute("aria-live", "polite")
      }

      this.renderSelection()
      return
    }

    this.unbind()
    this.resetSelection()
    this.options = normalized

    if (!normalized.enabled) {
      normalized.root?.removeAttribute("tabindex")
      normalized.root?.setAttribute("aria-disabled", "true")
      return
    }

    this.activeIndex = normalized.buckets.length - 1
    this.bind()
  }

  bind() {
    const {root, status, svg} = this.options
    root.setAttribute("tabindex", "0")
    root.removeAttribute("aria-disabled")
    status.setAttribute("aria-live", "polite")

    const onPointerDown = (event) => this.pointerDown(event)
    const onPointerMove = (event) => this.pointerMove(event)
    const onPointerUp = (event) => this.pointerUp(event)
    const onPointerCancel = (event) => this.pointerCancel(event)
    const onLostPointerCapture = (event) => this.lostPointerCapture(event)
    const onKeyDown = (event) => this.keyDown(event)

    svg.addEventListener("pointerdown", onPointerDown)
    svg.addEventListener("pointermove", onPointerMove)
    svg.addEventListener("pointerup", onPointerUp)
    svg.addEventListener("pointercancel", onPointerCancel)
    root.addEventListener("pointermove", onPointerMove)
    root.addEventListener("pointerup", onPointerUp)
    root.addEventListener("pointercancel", onPointerCancel)
    root.addEventListener("lostpointercapture", onLostPointerCapture)
    root.addEventListener("keydown", onKeyDown)

    this.cleanup = () => {
      svg.removeEventListener("pointerdown", onPointerDown)
      svg.removeEventListener("pointermove", onPointerMove)
      svg.removeEventListener("pointerup", onPointerUp)
      svg.removeEventListener("pointercancel", onPointerCancel)
      root.removeEventListener("pointermove", onPointerMove)
      root.removeEventListener("pointerup", onPointerUp)
      root.removeEventListener("pointercancel", onPointerCancel)
      root.removeEventListener("lostpointercapture", onLostPointerCapture)
      root.removeEventListener("keydown", onKeyDown)
    }
  }

  destroy() {
    this.unbind()
    this.resetSelection()
    this.options = null
  }

  consumeChartClick() {
    const suppress = this.suppressChartClick
    this.clearChartClickSuppression()
    return suppress
  }

  normalizeOptions(options = {}) {
    const enabled =
      options.root &&
      options.svg &&
      options.overlay &&
      options.status &&
      validRangeBuckets(options.buckets) &&
      typeof options.emit === "function" &&
      typeof options.viewXForEvent === "function" &&
      typeof options.plotBounds === "function"

    return {...options, enabled}
  }

  bindingIsUnchanged(next) {
    const current = this.options
    return (
      current.enabled === next.enabled &&
      current.bindingKey === next.bindingKey &&
      current.eventKey === next.eventKey &&
      sameBuckets(current.buckets, next.buckets) &&
      current.root === next.root &&
      current.svg === next.svg &&
      current.overlay === next.overlay &&
      current.status === next.status
    )
  }

  gestureBindingIsCompatible(next) {
    const current = this.options
    return (
      current.enabled &&
      next.enabled &&
      current.eventKey === next.eventKey &&
      current.root === next.root &&
      sameBucketIntervals(current.buckets, next.buckets)
    )
  }

  unbind() {
    this.cleanup?.()
    this.cleanup = null
  }

  pointerDown(event) {
    if (this.pointer) return
    const index = this.bucketIndexForEvent(event)
    if (index === null) return

    this.resetSelection()
    this.pointer = {
      anchorIndex: index,
      captured: false,
      clientX: event.clientX,
      lastRenderedActiveIndex: null,
      pointerId: event.pointerId,
    }
    this.trackGestureOutsideChart()
  }

  pointerMove(event) {
    const pointer = this.pointer
    if (!pointer || pointer.pointerId !== event.pointerId || !this.displacementQualifies(event, pointer)) return

    this.capturePointer()
    const activeIndex = this.bucketIndexForEvent(event, true)
    if (activeIndex === null) return

    this.anchorIndex = pointer.anchorIndex
    this.activeIndex = activeIndex
    this.renderSelection()
  }

  pointerUp(event) {
    const pointer = this.pointer
    if (!pointer || pointer.pointerId !== event.pointerId) return

    const releaseIndex = this.bucketIndexForEvent(event, true)
    const activeIndex = releaseIndex ?? pointer.lastRenderedActiveIndex
    const moved = this.displacementQualifies(event, pointer) && activeIndex !== null
    this.releasePointerCapture()
    this.stopTrackingGesture()
    this.pointer = null

    if (!moved) {
      this.resetSelection()
      return
    }

    this.anchorIndex = pointer.anchorIndex
    this.activeIndex = activeIndex
    this.renderSelection()
    this.emitSelection()
    this.armChartClickSuppression()
  }

  pointerCancel(event) {
    if (this.pointer?.pointerId === event.pointerId) this.resetSelection()
  }

  lostPointerCapture(event) {
    if (event.target && event.target !== this.options.root) return
    if (this.pointer?.pointerId === event.pointerId) this.resetSelection()
  }

  keyDown(event) {
    const isArrow = event.key === "ArrowLeft" || event.key === "ArrowRight"
    if (!isArrow && event.key !== "Enter" && event.key !== "Escape") return

    event.preventDefault()
    if (event.key === "Escape") {
      this.cancelSelection()
      return
    }
    if (event.key === "Enter") {
      this.emitSelection()
      return
    }

    const direction = event.key === "ArrowLeft" ? -1 : 1
    const currentIndex = this.activeIndex ?? this.options.buckets.length - 1
    const nextIndex = Math.max(0, Math.min(this.options.buckets.length - 1, currentIndex + direction))

    if (event.shiftKey) {
      this.anchorIndex ??= currentIndex
      this.activeIndex = nextIndex
    } else {
      this.anchorIndex = nextIndex
      this.activeIndex = nextIndex
    }
    this.renderSelection()
  }

  displacementQualifies(event, pointer) {
    return Math.abs(event.clientX - pointer.clientX) > DRAG_THRESHOLD_PX
  }

  bucketIndexForEvent(event, continuing = false) {
    let viewX = this.options.viewXForEvent(event)
    if (viewX === null && continuing && typeof this.options.continuationXForEvent === "function") {
      viewX = this.options.continuationXForEvent(event)
    }
    return nearestRangeBucketIndex(this.options.buckets, viewX)
  }

  renderSelection() {
    const selectedRange = this.currentSelection()
    if (!selectedRange) return

    const bounds = this.options.plotBounds()
    const overlay = overlayForBucketIndexes(
      this.options.buckets,
      this.anchorIndex,
      this.activeIndex,
      bounds?.left,
      bounds?.right,
    )
    if (!overlay) return

    this.options.overlay.setAttribute("x", overlay.x)
    this.options.overlay.setAttribute("width", overlay.width)
    this.options.overlay.classList.remove("hidden")
    const formattedStatus = this.options.formatStatus?.(selectedRange)
    this.options.status.textContent =
      typeof formattedStatus === "string" && formattedStatus !== ""
        ? formattedStatus
        : `Selected ${selectedRange.start} to ${selectedRange.end}`
    if (this.pointer) this.pointer.lastRenderedActiveIndex = this.activeIndex
  }

  emitSelection() {
    const selectedRange = this.currentSelection()
    if (selectedRange) this.options.emit({start: selectedRange.start, end: selectedRange.end})
  }

  resetSelection() {
    this.cancelSelection()
    this.activeIndex = null
    this.clearChartClickSuppression()
  }

  cancelSelection() {
    this.releasePointerCapture()
    this.stopTrackingGesture()
    this.pointer = null
    this.anchorIndex = null
    this.options?.overlay?.classList.add("hidden")
    this.options?.overlay?.removeAttribute("x")
    this.options?.overlay?.removeAttribute("width")
    if (this.options?.status) this.options.status.textContent = ""
  }

  currentSelection() {
    return rangeForBucketIndexes(this.options?.buckets, this.anchorIndex ?? this.activeIndex, this.activeIndex)
  }

  capturePointer() {
    const pointer = this.pointer
    const root = this.options?.root
    if (!pointer || pointer.captured || !root || typeof root.setPointerCapture !== "function") return

    try {
      root.setPointerCapture(pointer.pointerId)
      pointer.captured =
        typeof root.hasPointerCapture !== "function" || root.hasPointerCapture(pointer.pointerId)
    } catch (_error) {
      pointer.captured = false
    }
  }

  trackGestureOutsideChart() {
    this.stopTrackingGesture()
    const root = this.options?.root
    const target = root?.ownerDocument
    if (!target || target === root || typeof target.addEventListener !== "function") return

    const onPointerMove = (event) => this.pointerMove(event)
    const onPointerUp = (event) => this.pointerUp(event)
    const onPointerCancel = (event) => this.pointerCancel(event)
    target.addEventListener("pointermove", onPointerMove)
    target.addEventListener("pointerup", onPointerUp)
    target.addEventListener("pointercancel", onPointerCancel)

    this.gestureCleanup = () => {
      target.removeEventListener("pointermove", onPointerMove)
      target.removeEventListener("pointerup", onPointerUp)
      target.removeEventListener("pointercancel", onPointerCancel)
    }
  }

  stopTrackingGesture() {
    this.gestureCleanup?.()
    this.gestureCleanup = null
  }

  armChartClickSuppression() {
    this.clearChartClickSuppression()
    this.suppressChartClick = true

    const root = this.options?.root
    const target = root?.ownerDocument
    if (!target || target === root || typeof target.addEventListener !== "function") return

    const onClick = () => this.clearChartClickSuppression()
    target.addEventListener("click", onClick)
    this.clickCleanup = () => target.removeEventListener("click", onClick)
  }

  clearChartClickSuppression() {
    this.clickCleanup?.()
    this.clickCleanup = null
    this.suppressChartClick = false
  }

  releasePointerCapture() {
    const root = this.options?.root
    const pointer = this.pointer
    if (!pointer?.captured || !root || typeof root.releasePointerCapture !== "function") return

    try {
      if (typeof root.hasPointerCapture !== "function" || root.hasPointerCapture(pointer.pointerId)) {
        root.releasePointerCapture(pointer.pointerId)
      }
    } finally {
      pointer.captured = false
    }
  }
}

function sameBuckets(left, right) {
  if (left === right) return true
  if (!Array.isArray(left) || !Array.isArray(right) || left.length !== right.length) return false

  return left.every(
    (bucket, index) =>
      bucket?.x === right[index]?.x &&
      bucket?.start === right[index]?.start &&
      bucket?.end === right[index]?.end,
  )
}

function sameBucketIntervals(left, right) {
  if (!Array.isArray(left) || !Array.isArray(right) || left.length !== right.length) return false

  return left.every(
    (bucket, index) => bucket?.start === right[index]?.start && bucket?.end === right[index]?.end,
  )
}

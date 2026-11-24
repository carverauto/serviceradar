const MAX_LIVE_DRIFT_US = 60_000_000

export function computeVerticalFraction(clientY, rect) {
  if (!rect || !Number.isFinite(rect.height) || rect.height <= 0) return null
  const raw = (clientY - rect.top) / rect.height
  const clamped = Math.min(1, Math.max(0, raw))
  return Number(clamped.toFixed(6))
}

export function computeLiveWindowUs(fromUs, toUs, elapsedMs, {maxDriftUs = MAX_LIVE_DRIFT_US} = {}) {
  const from = Number(fromUs)
  const to = Number(toUs)
  if (!Number.isFinite(from) || !Number.isFinite(to) || to <= from) return null

  const rawDriftUs = Math.max(0, Math.round((Number(elapsedMs) || 0) * 1000))
  const driftUs = Math.min(rawDriftUs, maxDriftUs)
  return {
    fromUs: from + driftUs,
    toUs: to + driftUs,
    spanUs: to - from,
  }
}

export function computeMarkerTopPct(eventTsUs, fromUs, toUs, {minPct = 0.5, maxPct = 99.5} = {}) {
  const ts = Number(eventTsUs)
  const from = Number(fromUs)
  const to = Number(toUs)
  if (!Number.isFinite(ts) || !Number.isFinite(from) || !Number.isFinite(to) || to <= from) {
    return null
  }
  const pct = ((to - ts) / (to - from)) * 100
  return Number(Math.min(maxPct, Math.max(minPct, pct)).toFixed(2))
}

export function formatRailTime(tsUs, timezone = "Etc/UTC", {includeSeconds = false} = {}) {
  const us = Number(tsUs)
  if (!Number.isFinite(us)) return ""
  const date = new Date(Math.round(us / 1000))
  if (Number.isNaN(date.getTime())) return ""

  const baseOptions = includeSeconds
    ? {hour: "2-digit", minute: "2-digit", second: "2-digit"}
    : {hour: "2-digit", minute: "2-digit"}

  try {
    return new Intl.DateTimeFormat(undefined, {
      ...baseOptions,
      timeZone: timezone || "Etc/UTC",
    }).format(date)
  } catch (_err) {
    return new Intl.DateTimeFormat(undefined, {
      ...baseOptions,
      timeZone: "Etc/UTC",
    }).format(date)
  }
}

export default {
  mounted() {
    this.listeners = new AbortController()
    this.liveTimer = null
    this.syncAnchorState()
    const options = {signal: this.listeners.signal}

    this.el.addEventListener(
      "click",
      event => {
        // Let dedicated detection/thumbnail/semantic marker buttons handle their own phx-click
        if (
          event.target?.closest?.(
            "[data-role='event-clip-marker'], [data-role='event-thumb-marker'], [data-role='semantic-hit-marker']"
          )
        ) {
          return
        }

        const rect = this.el.getBoundingClientRect?.()
        const fraction = computeVerticalFraction(event.clientY, rect)
        if (fraction === null) return

        this.pushEvent?.("seek_timeline_fraction", {fraction})
      },
      options
    )

    this.el.addEventListener(
      "mousemove",
      event => {
        const hoverLine = this.el.querySelector("[data-role='vertical-timeline-hover']")
        if (!hoverLine) return
        const rect = this.el.getBoundingClientRect?.()
        const fraction = computeVerticalFraction(event.clientY, rect)
        if (fraction === null) return
        hoverLine.style.top = `${(fraction * 100).toFixed(2)}%`
        hoverLine.hidden = false

        const hoverLabel = hoverLine.querySelector?.("[data-role='vertical-timeline-hover-time']")
        if (hoverLabel) {
          const win = this.currentWindowUs()
          if (win) {
            const hoverTsUs = Math.round(win.toUs - fraction * win.spanUs)
            hoverLabel.textContent = formatRailTime(hoverTsUs, this.timezone, {includeSeconds: true})
          }
        }
      },
      options
    )

    this.el.addEventListener(
      "mouseleave",
      () => {
        const hoverLine = this.el.querySelector("[data-role='vertical-timeline-hover']")
        if (hoverLine) hoverLine.hidden = true
      },
      options
    )

    this.startOrStopLiveTicker()
  },

  updated() {
    this.syncAnchorState()
    this.startOrStopLiveTicker()
  },

  destroyed() {
    this.stopLiveTicker()
    this.listeners?.abort()
  },

  syncAnchorState() {
    const ds = this.el.dataset || {}
    this.anchorFromUs = Number(ds.fromUs)
    this.anchorToUs = Number(ds.toUs)
    this.anchoredLatest = ds.anchoredLatest === "true"
    this.timezone = ds.timezone || "Etc/UTC"
    this.anchorClientMs = Date.now()
  },

  currentWindowUs() {
    if (!Number.isFinite(this.anchorFromUs) || !Number.isFinite(this.anchorToUs) || this.anchorToUs <= this.anchorFromUs) {
      return null
    }
    if (!this.anchoredLatest) {
      return {
        fromUs: this.anchorFromUs,
        toUs: this.anchorToUs,
        spanUs: this.anchorToUs - this.anchorFromUs,
      }
    }
    return computeLiveWindowUs(this.anchorFromUs, this.anchorToUs, Date.now() - this.anchorClientMs)
  },

  startOrStopLiveTicker() {
    this.stopLiveTicker()
    if (!this.anchoredLatest) return
    if (!Number.isFinite(this.anchorFromUs) || !Number.isFinite(this.anchorToUs) || this.anchorToUs <= this.anchorFromUs) {
      return
    }
    this.liveTimer = setInterval(() => this.tickLiveRail(), 1000)
  },

  stopLiveTicker() {
    if (this.liveTimer !== null && this.liveTimer !== undefined) {
      clearInterval(this.liveTimer)
      this.liveTimer = null
    }
  },

  tickLiveRail() {
    const win = this.currentWindowUs()
    if (!win) return

    const includeSeconds = win.spanUs <= 3_600_000_000
    const container = this.el.parentElement || this.el
    const tickEls = container.querySelectorAll?.("[data-role='vertical-tick-label']") || []
    for (const tickEl of tickEls) {
      const frac = Number(tickEl.dataset?.tickFraction)
      if (!Number.isFinite(frac)) continue
      const tickUs = Math.round(win.toUs - frac * win.spanUs)
      tickEl.textContent = formatRailTime(tickUs, this.timezone, {includeSeconds})
    }

    const markers = this.el.querySelectorAll?.("[data-role='event-clip-marker'][data-event-ts-us]") || []
    for (const marker of markers) {
      const topPct = computeMarkerTopPct(marker.dataset?.eventTsUs, win.fromUs, win.toUs)
      if (topPct !== null) {
        marker.style.top = `${topPct}%`
      }
    }

    const thumbs = this.el.querySelectorAll?.("[data-role='event-thumb-marker'][data-event-ts-us]") || []
    for (const thumb of thumbs) {
      const topPct = computeMarkerTopPct(thumb.dataset?.eventTsUs, win.fromUs, win.toUs, {
        minPct: 6.0,
        maxPct: 94.0,
      })
      if (topPct !== null) {
        thumb.style.top = `${topPct}%`
      }
    }
  },
}

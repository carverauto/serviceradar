export function computeVerticalFraction(clientY, rect) {
  if (!rect || !Number.isFinite(rect.height) || rect.height <= 0) return null
  const raw = (clientY - rect.top) / rect.height
  const clamped = Math.min(1, Math.max(0, raw))
  return Number(clamped.toFixed(6))
}

export default {
  mounted() {
    this.listeners = new AbortController()
    const options = {signal: this.listeners.signal}

    this.el.addEventListener(
      "click",
      event => {
        // Let dedicated detection/semantic marker buttons handle their own phx-click
        if (
          event.target?.closest?.(
            "[data-role='event-clip-marker'], [data-role='semantic-hit-marker']"
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
  },

  destroyed() {
    this.listeners?.abort()
  },
}

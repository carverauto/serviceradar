/**
 * FlowSparkline — lightweight inline area chart.
 *
 * Uses <canvas> (no D3) for minimal overhead. Designed for embedding in
 * stat cards and table cells.
 *
 * Data attrs:
 *   data-points  — JSON array of {t: epoch_ms, v: number}
 *   data-color   — CSS color for fill/stroke (default: oklch primary)
 */
export default {
  mounted() {
    this.draw()
    this._resizeObserver = new ResizeObserver(() => this.draw())
    this._resizeObserver.observe(this.el)
  },

  updated() {
    this.draw()
  },

  destroyed() {
    if (this._resizeObserver) this._resizeObserver.disconnect()
  },

  draw() {
    const canvas = this.el.querySelector("canvas")
    if (!canvas) return

    let points = []
    try {
      const parsed = JSON.parse(this.el.dataset.points || "[]")
      points = Array.isArray(parsed)
        ? parsed
            .map((p) => ({ t: p?.t, v: Number(p?.v) }))
            .filter((p) => Number.isFinite(p.v))
        : []
    } catch (_e) {
      points = []
    }
    if (points.length < 2) return

    const dpr = window.devicePixelRatio || 1
    const rect = this.el.getBoundingClientRect()
    const w = Math.max(0, Math.floor(rect.width))
    const h = Math.max(0, Math.floor(rect.height))
    if (w === 0 || h === 0) return

    canvas.width = w * dpr
    canvas.height = h * dpr
    canvas.style.width = `${w}px`
    canvas.style.height = `${h}px`

    const ctx = canvas.getContext("2d")
    if (!ctx) return
    ctx.setTransform(1, 0, 0, 1, 0, 0)
    ctx.scale(dpr, dpr)
    ctx.clearRect(0, 0, w, h)

    const values = points.map((p) => p.v)
    const min = Math.min(...values)
    const max = Math.max(...values)
    const range = max - min || 1
    const padY = h * 0.1

    // Canvas does NOT resolve CSS custom properties: assigning
    // "var(--sr-color-brand)" to fillStyle/strokeStyle is invalid, the
    // assignment is silently ignored, and the canvas keeps its default black --
    // which on a dark card renders the line invisible. Resolve the variable to
    // a concrete colour first. Doing it here (rather than hardcoding a literal)
    // keeps the sparkline theme-aware, since getComputedStyle reflects whichever
    // theme is active.
    const color = resolveColor(this.el.dataset.color, this.el)

    // Draw filled area
    ctx.beginPath()
    ctx.moveTo(0, h)

    for (let i = 0; i < points.length; i++) {
      const x = (i / (points.length - 1)) * w
      const y = h - padY - ((values[i] - min) / range) * (h - 2 * padY)
      if (i === 0) ctx.lineTo(x, y)
      else ctx.lineTo(x, y)
    }

    ctx.lineTo(w, h)
    ctx.closePath()
    ctx.fillStyle = color
    ctx.globalAlpha = 0.15
    ctx.fill()

    // Draw line
    ctx.globalAlpha = 1
    ctx.beginPath()

    for (let i = 0; i < points.length; i++) {
      const x = (i / (points.length - 1)) * w
      const y = h - padY - ((values[i] - min) / range) * (h - 2 * padY)
      if (i === 0) ctx.moveTo(x, y)
      else ctx.lineTo(x, y)
    }

    ctx.strokeStyle = color
    ctx.lineWidth = 1.5
    ctx.stroke()
  },
}

/**
 * Resolve a colour that may be a `var(--token)` reference into a concrete value
 * canvas can use. Returns the fallback when the token is undefined, so a
 * removed design token degrades to a visible line instead of an invisible one.
 */
function resolveColor(raw, el, fallback = "#3ecf87") {
  const value = (raw || "").trim()
  if (!value) return fallback

  const match = value.match(/^var\(\s*(--[\w-]+)\s*(?:,\s*(.+?)\s*)?\)$/)
  if (!match) return value

  const [, token, inlineFallback] = match
  const resolved = getComputedStyle(el).getPropertyValue(token).trim()
  return resolved || (inlineFallback || "").trim() || fallback
}

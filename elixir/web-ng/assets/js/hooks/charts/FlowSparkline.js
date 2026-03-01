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

    const color = this.el.dataset.color || "oklch(0.65 0.24 264)"

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

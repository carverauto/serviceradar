/**
 * FlowDonut — lightweight donut/pie chart using <canvas>.
 *
 * Data attrs:
 *   data-slices — JSON array of {label: string, value: number, color?: string}
 */

const DEFAULT_COLORS = [
  "oklch(0.65 0.24 264)", // primary
  "oklch(0.70 0.18 150)", // green
  "oklch(0.72 0.20 50)", // amber
  "oklch(0.60 0.22 320)", // purple
  "oklch(0.68 0.16 200)", // teal
  "oklch(0.75 0.14 80)", // lime
  "oklch(0.55 0.25 30)", // red-orange
  "oklch(0.65 0.20 230)", // blue
]

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
    const legendEl = this.el.querySelector("[data-legend]")
    if (!canvas) return

    let slices = []
    try {
      const parsed = JSON.parse(this.el.dataset.slices || "[]")
      slices = Array.isArray(parsed) ? parsed : []
    } catch (_e) {
      slices = []
    }
    if (slices.length === 0) return

    const total = slices.reduce((s, d) => s + (Number(d.value) || 0), 0)
    if (total === 0) return

    const dpr = window.devicePixelRatio || 1
    const container = canvas.parentElement
    if (!container) return
    const size = Math.max(0, Math.floor(Math.min(container.clientWidth, container.clientHeight)))
    if (size === 0) return

    canvas.width = size * dpr
    canvas.height = size * dpr
    canvas.style.width = `${size}px`
    canvas.style.height = `${size}px`

    const ctx = canvas.getContext("2d")
    if (!ctx) return
    ctx.setTransform(1, 0, 0, 1, 0, 0)
    ctx.scale(dpr, dpr)
    ctx.clearRect(0, 0, size, size)

    const cx = size / 2
    const cy = size / 2
    const outerR = size / 2 - 4
    const innerR = outerR * 0.55

    let startAngle = -Math.PI / 2

    slices.forEach((slice, i) => {
      const sweep = (slice.value / total) * Math.PI * 2
      const color = slice.color || DEFAULT_COLORS[i % DEFAULT_COLORS.length]

      ctx.beginPath()
      ctx.moveTo(
        cx + innerR * Math.cos(startAngle),
        cy + innerR * Math.sin(startAngle),
      )
      ctx.arc(cx, cy, outerR, startAngle, startAngle + sweep)
      ctx.arc(cx, cy, innerR, startAngle + sweep, startAngle, true)
      ctx.closePath()
      ctx.fillStyle = color
      ctx.fill()

      startAngle += sweep
    })

    // Legend (built via DOM API to avoid innerHTML XSS)
    if (legendEl) {
      legendEl.textContent = ""
      slices.forEach((s, i) => {
        const color = s.color || DEFAULT_COLORS[i % DEFAULT_COLORS.length]
        const pct = ((s.value / total) * 100).toFixed(1)

        const wrapper = document.createElement("span")
        wrapper.className = "inline-flex items-center gap-1"

        const dot = document.createElement("span")
        dot.className = "w-2 h-2 rounded-full inline-block"
        dot.style.background = color

        wrapper.appendChild(dot)
        wrapper.appendChild(document.createTextNode(` ${s.label} (${pct}%)`))
        legendEl.appendChild(wrapper)
      })
    }
  },
}

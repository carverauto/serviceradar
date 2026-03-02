import {ensureTooltip as nfEnsureTooltip, parseJSON as nfParseJSON} from "../../netflow_charts/util"
import {nfFormatRateValue} from "../../utils/formatters"

export default {
  mounted() {
    this._bind()
  },
  updated() {
    this._unbind()
    this._bind()
  },
  destroyed() {
    this._unbind()
  },
  _bind() {
    const el = this.el
    const tooltip = nfEnsureTooltip(el)
    const points = nfParseJSON(el.dataset.points || "[]", [])

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
        <div class="text-[10px] text-base-content/60 font-mono">${escapeHtml(point.start || "")} → ${escapeHtml(point.end || "")}</div>
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

    this._cleanup = () => {
      el.removeEventListener("mousemove", onMove)
      el.removeEventListener("mouseleave", onLeave)
      tooltip.classList.add("hidden")
    }
  },
  _unbind() {
    try {
      this._cleanup?.()
    } catch (_e) {}
    this._cleanup = null
  },
}

function escapeHtml(s) {
  return String(s || "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;")
}

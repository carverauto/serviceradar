export const godViewRenderingStyleEdgeTelemetryMethods = {
  formatPps(value) {
    const n = Number(value || 0)
    if (!Number.isFinite(n) || n <= 0) return "0 pps"
    if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)} Mpps`
    if (n >= 1_000) return `${(n / 1_000).toFixed(1)} Kpps`
    return `${Math.round(n)} pps`
  },
  formatCapacity(value) {
    const n = Number(value || 0)
    if (!Number.isFinite(n) || n <= 0) return "UNK"
    if (n >= 100_000_000_000) return `${Math.round(n / 1_000_000_000)}G`
    if (n >= 10_000_000_000) return `${Math.round(n / 1_000_000_000)}G`
    if (n >= 1_000_000_000) return `${Math.round(n / 1_000_000_000)}G`
    if (n >= 100_000_000) return `${Math.round(n / 1_000_000)}M`
    return `${Math.max(1, Math.round(n / 1_000_000))}M`
  },
  edgeTelemetryColor(flowBps, capacityBps, flowPps, vivid = false) {
    const bps = Number(flowBps || 0)
    const cap = Number(capacityBps || 0)
    const pps = Number(flowPps || 0)
    const util = cap > 0 ? Math.min(1, bps / cap) : 0
    const spark = pps > 0 ? Math.min(1, Math.log10(Math.max(10, pps)) / 6) : 0
    const t = Math.min(1, Math.max(util, spark))

    const low = vivid ? [56, 210, 255, 88] : [48, 158, 226, 58]
    const high = vivid ? [255, 110, 220, 142] : [196, 122, 255, 98]

    return [
      Math.round(low[0] * (1 - t) + high[0] * t),
      Math.round(low[1] * (1 - t) + high[1] * t),
      Math.round(low[2] * (1 - t) + high[2] * t),
      Math.round(low[3] * (1 - t) + high[3] * t),
    ]
  },
  edgeTelemetryArcColors(flowBps, capacityBps, flowPps) {
    const source = this.edgeTelemetryColor(flowBps, capacityBps, flowPps, true)
    const target = this.edgeTelemetryColor(flowBps, capacityBps, flowPps, false)
    return {source, target}
  },
  edgeWidthPixels(capacityBps, flowPps, flowBps) {
    const cap = Number(capacityBps || 0)
    const pps = Number(flowPps || 0)
    const bps = Number(flowBps || 0)

    let base = 1.2
    if (cap >= 100_000_000_000) base = 3.2
    else if (cap >= 40_000_000_000) base = 2.8
    else if (cap >= 10_000_000_000) base = 2.4
    else if (cap >= 1_000_000_000) base = 2.0
    else if (cap >= 100_000_000) base = 1.6

    const ppsBoost = Math.min(3.4, Math.log10(Math.max(1, pps)) * 0.95)
    const utilization = cap > 0 ? Math.min(1, bps / cap) : 0
    const bpsBoost = utilization > 0 ? Math.min(4.2, Math.sqrt(utilization) * 4.2) : 0
    const flowBoost = Math.max(ppsBoost, bpsBoost) * 0.55
    return Math.min(7.2, Math.max(1.2, base + flowBoost))
  },
  connectionKindFromLabel(label) {
    const text = String(label == null ? "" : label).trim()
    if (text === "") return "LINK"
    const token = text.split(/\s+/)[0] || ""
    const clean = token.replace(/[^a-zA-Z0-9_-]/g, "").toUpperCase()
    if (!clean || clean === "NODE") return "LINK"
    return clean
  },
}

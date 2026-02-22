export const godViewRenderingStyleEdgeMethods = {
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

    const low = vivid ? [48, 226, 255, 65] : [40, 170, 220, 45]
    const high = vivid ? [255, 74, 212, 90] : [214, 97, 255, 70]

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

    let base = 0.75
    if (cap >= 100_000_000_000) base = 3.5
    else if (cap >= 40_000_000_000) base = 2.8
    else if (cap >= 10_000_000_000) base = 2
    else if (cap >= 1_000_000_000) base = 1.5
    else if (cap >= 100_000_000) base = 1

    const ppsBoost = Math.min(2.8, Math.log10(Math.max(1, pps)) * 0.85)
    const utilization = cap > 0 ? Math.min(1, bps / cap) : 0
    const bpsBoost = utilization > 0 ? Math.min(3.2, Math.sqrt(utilization) * 3.2) : 0
    const flowBoost = Math.max(ppsBoost, bpsBoost) * 0.6
    return Math.min(4.5, Math.max(0.75, base + flowBoost))
  },
  connectionKindFromLabel(label) {
    const text = String(label == null ? "" : label).trim()
    if (text === "") return "LINK"
    const token = text.split(/\s+/)[0] || ""
    const clean = token.replace(/[^a-zA-Z0-9_-]/g, "").toUpperCase()
    if (!clean || clean === "NODE") return "LINK"
    return clean
  },
  edgeTopologyClassFromLabel(label) {
    const text = String(label == null ? "" : label).trim().toUpperCase()
    if (text.includes(" ENDPOINT ")) return "endpoints"
    if (text.includes(" INFERRED ")) return "inferred"
    return "backbone"
  },
  edgeTopologyClass(edge) {
    const explicit = String(edge?.topologyClass || "").trim().toLowerCase()
    if (explicit === "inferred" || explicit === "endpoints" || explicit === "backbone") {
      return explicit
    }
    return this.edgeTopologyClassFromLabel(edge?.label || "")
  },
  edgeEnabledByTopologyLayer(edge) {
    const classCounts = edge?.topologyClassCounts
    if (classCounts && typeof classCounts === "object") {
      const showBackbone =
        Number(classCounts.backbone || 0) > 0 && this.topologyLayers.backbone !== false
      const showInferred =
        Number(classCounts.inferred || 0) > 0 && this.topologyLayers.inferred === true
      const showEndpoints =
        Number(classCounts.endpoints || 0) > 0 && this.topologyLayers.endpoints === true
      return showBackbone || showInferred || showEndpoints
    }

    const topologyClass = this.edgeTopologyClass(edge)
    if (topologyClass === "inferred") return this.topologyLayers.inferred === true
    if (topologyClass === "endpoints") return this.topologyLayers.endpoints === true
    return this.topologyLayers.backbone !== false
  },
  buildPacketFlowInstances(edgeData) {
    if (!Array.isArray(edgeData) || edgeData.length === 0) return []
    const maxParticles = 22000
    const particles = []

    for (let i = 0; i < edgeData.length; i += 1) {
      if (particles.length >= maxParticles) break
      const edge = edgeData[i]
      const src = edge?.sourcePosition
      const dst = edge?.targetPosition
      if (!Array.isArray(src) || !Array.isArray(dst)) continue
      const pps = Number(edge?.flowPps || 0)
      const bps = Number(edge?.flowBps || 0)
      const cap = Number(edge?.capacityBps || 0)
      const utilization = cap > 0 ? Math.min(1, bps / cap) : 0
      const ppsSignal = pps > 0 ? Math.log10(Math.max(10, pps)) : 0
      const bpsSignal = utilization > 0 ? utilization * 3.2 : 0
      const baseline = 1.05 + Math.min(1.1, Math.log10(Math.max(1, edge.weight || 1)) * 0.72)
      const intensity = Math.max(baseline, ppsSignal, bpsSignal)
      const particlesOnEdge = Math.max(24, Math.min(140, Math.floor(intensity * 10.5)))
      const baseSpeed = 0.11 + Math.min(1.35, intensity * 0.11)

      for (let j = 0; j < particlesOnEdge; j += 1) {
        if (particles.length >= maxParticles) break
        const seed = (((i * 17 + j * 37) % 997) + 1) / 997
        const speedModifier = 0.7 + (((j * 43) % 101) / 100) * 0.6
        const particleSpeed = baseSpeed * speedModifier
        const hue = Math.min(1, intensity / 4)
        const cyan = [73, 231, 255, 95]
        const magenta = [244, 114, 255, 120]
        const color = [
          Math.round(cyan[0] * (1 - hue) + magenta[0] * hue),
          Math.round(cyan[1] * (1 - hue) + magenta[1] * hue),
          Math.round(cyan[2] * (1 - hue) + magenta[2] * hue),
          Math.round(cyan[3] * (1 - hue) + magenta[3] * hue),
        ]
        particles.push({
          from: [src[0], src[1]],
          to: [dst[0], dst[1]],
          seed,
          speed: particleSpeed,
          jitter: 8 + Math.min(26, intensity * 6.5),
          size: Math.min(24.0, 10.0 + intensity * 2.5),
          color,
        })
      }
    }

    return particles
  },
}

export const godViewRenderingStyleEdgeParticleMethods = {
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

function packetFlowStamp(edgeData) {
  if (!Array.isArray(edgeData) || edgeData.length === 0) return "empty"
  const sampleCount = Math.min(edgeData.length, 96)
  let acc = `${edgeData.length}`
  const step = Math.max(1, Math.floor(edgeData.length / sampleCount))
  for (let i = 0; i < edgeData.length; i += step) {
    const edge = edgeData[i] || {}
    const key = edge.interactionKey || `${edge.sourceId || "s"}:${edge.targetId || "t"}:${i}`
    acc += `|${key}:${Number(edge.flowPps || 0)}:${Number(edge.flowBps || 0)}:${Number(edge.capacityBps || 0)}`
  }
  return acc
}

export const godViewRenderingStyleEdgeParticleMethods = {
  buildPacketFlowInstances(edgeData) {
    if (!Array.isArray(edgeData) || edgeData.length === 0) return []
    const cacheState = this?.state
    const stamp = packetFlowStamp(edgeData)
    if (cacheState && cacheState.packetFlowCacheStamp === stamp && Array.isArray(cacheState.packetFlowCache)) {
      return cacheState.packetFlowCache
    }
    const maxParticles = 60000
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
      const particlesOnEdge = Math.max(24, Math.min(600, Math.floor(intensity * 35.5)))
      const baseSpeed = 0.11 + Math.min(1.35, intensity * 0.11)

      for (let j = 0; j < particlesOnEdge; j += 1) {
        if (particles.length >= maxParticles) break
        const seed = (((i * 17 + j * 37) % 997) + 1) / 997
        const speedModifier = 0.7 + (((j * 43) % 101) / 100) * 0.6
        const particleSpeed = baseSpeed * speedModifier
        const hue = Math.min(1, intensity / 4)
        const isHead = j % 5 === 0
        const sky = [56, 189, 248, isHead ? 140 : 42]
        const indigo = [99, 102, 241, isHead ? 165 : 55]
        const color = [
          Math.round(sky[0] * (1 - hue) + indigo[0] * hue),
          Math.round(sky[1] * (1 - hue) + indigo[1] * hue),
          Math.round(sky[2] * (1 - hue) + indigo[2] * hue),
          Math.round(sky[3] * (1 - hue) + indigo[3] * hue),
        ]
        particles.push({
          sourcePosition: [src[0], src[1], 0],
          targetPosition: [dst[0], dst[1], 0],
          from: [src[0], src[1]],
          to: [dst[0], dst[1]],
          seed,
          speed: particleSpeed,
          jitter: 14 + Math.min(45, intensity * 9.0),
          size: isHead
            ? Math.min(32.0, 15.0 + intensity * 3.5)
            : Math.min(12.0, 4.0 + intensity * 1.5),
          color,
        })
      }
    }

    if (cacheState) {
      cacheState.packetFlowCacheStamp = stamp
      cacheState.packetFlowCache = particles
    }
    return particles
  },
}

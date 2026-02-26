function packetFlowStamp(edgeData) {
  if (!Array.isArray(edgeData) || edgeData.length === 0) return "empty"
  const sampleCount = Math.min(edgeData.length, 96)
  let acc = `${edgeData.length}`
  const step = Math.max(1, Math.floor(edgeData.length / sampleCount))
  for (let i = 0; i < edgeData.length; i += step) {
    const edge = edgeData[i] || {}
    const key = edge.interactionKey || `${edge.sourceId || "s"}:${edge.targetId || "t"}:${i}`
    const telemetryEligible = edge.telemetryEligible === false || edge.telemetry_eligible === false ? 0 : 1
    acc += `|${key}:${Number(edge.flowPps || 0)}:${Number(edge.flowBps || 0)}:${Number(edge.flowPpsAb || 0)}:${Number(edge.flowPpsBa || 0)}:${Number(edge.flowBpsAb || 0)}:${Number(edge.flowBpsBa || 0)}:${Number(edge.capacityBps || 0)}:${telemetryEligible}`
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
    const zoom = Number(this?.state?.viewState?.zoom || 0)
    const zoomDensity = Math.max(0.55, Math.min(1.25, (zoom + 2.5) / 4.5))

    const pushDirectionParticles = ({src, dst, edgeIndex, count, speedBase, jitter, utilization, laneOffset}) => {
      for (let j = 0; j < count; j += 1) {
        if (particles.length >= maxParticles) break
        const seed = (((edgeIndex * 17 + j * 37) % 997) + 1) / 997
        const speedModifier = 0.9 + (((j * 43) % 101) / 100) * 0.18
        const particleSpeed = Math.min(0.12, speedBase * speedModifier)
        const noise = (((edgeIndex * 131) + (j * 17)) % 100) / 100
        const isHead = noise > 0.95
        const cyan = [73, 231, 255, 255]
        const magenta = [244, 114, 255, 255]
        const magentaBias = Math.min(0.85, Math.max(0.15, (utilization * 0.65) + 0.2))
        const mix = noise < magentaBias ? 1 : 0
        const color = [
          Math.round(cyan[0] * (1 - mix) + magenta[0] * mix),
          Math.round(cyan[1] * (1 - mix) + magenta[1] * mix),
          Math.round(cyan[2] * (1 - mix) + magenta[2] * mix),
          255,
        ]

        particles.push({
          sourcePosition: [src[0], src[1], 0],
          targetPosition: [dst[0], dst[1], 0],
          from: [src[0], src[1]],
          to: [dst[0], dst[1]],
          seed,
          speed: particleSpeed,
          jitter,
          laneOffset,
          size: isHead ? (6 + (seed * 3)) : (2 + (seed * 3)),
          color,
        })
      }
    }

    for (let i = 0; i < edgeData.length; i += 1) {
      if (particles.length >= maxParticles) break
      const edge = edgeData[i]
      if (edge?.telemetryEligible === false || edge?.telemetry_eligible === false) continue
      const src = edge?.sourcePosition
      const dst = edge?.targetPosition
      if (!Array.isArray(src) || !Array.isArray(dst)) continue
      const pps = Number(edge?.flowPps || 0)
      const bps = Number(edge?.flowBps || 0)
      const ppsAb = Number(edge?.flowPpsAb || 0)
      const ppsBa = Number(edge?.flowPpsBa || 0)
      const bpsAb = Number(edge?.flowBpsAb || 0)
      const bpsBa = Number(edge?.flowBpsBa || 0)
      const cap = Number(edge?.capacityBps || 0)
      const utilization = cap > 0 ? Math.min(1, bps / cap) : 0
      const bpsSignal = bps > 0 ? Math.min(1, Math.log10(Math.max(1, bps)) / 10) : 0
      const baseline = 1.05 + Math.min(1.0, Math.log10(Math.max(1, edge.weight || 1)) * 0.7)
      const trafficSignal = cap > 0 ? utilization : bpsSignal
      const intensity = Math.max(0.9, (baseline * 0.45) + (trafficSignal * 3.0))
      const totalDirectionalPps = ppsAb + ppsBa
      const totalDirectionalBps = bpsAb + bpsBa
      const totalSignal = totalDirectionalPps > 0 || totalDirectionalBps > 0
        ? Math.max(totalDirectionalPps, totalDirectionalBps)
        : Math.max(pps, bps)
      const abWeight = totalDirectionalPps > 0 ? (ppsAb / Math.max(1, totalDirectionalPps))
        : (totalDirectionalBps > 0 ? (bpsAb / Math.max(1, totalDirectionalBps)) : 1.0)
      const baWeight = totalDirectionalPps > 0 ? (ppsBa / Math.max(1, totalDirectionalPps))
        : (totalDirectionalBps > 0 ? (bpsBa / Math.max(1, totalDirectionalBps)) : 0.0)
      const baseSpeed = Math.min(0.11, 0.045 + (intensity * 0.014))
      const tubeWidth = typeof this.edgeWidthPixels === "function"
        ? this.edgeWidthPixels(cap, pps, bps)
        : 3.2
      const laneSeparation = Math.max(0.35, Math.min(2.6, tubeWidth * 0.22))
      const jitterBase = Math.max(1.1, Math.min(6.2, (tubeWidth * 0.32) + 0.95))
      const spreadFill = Math.max(0.8, Math.min(1.4, 0.9 + (utilization * 0.7)))
      const particlesOnEdge = Math.max(
        96,
        Math.min(1400, Math.floor((95 + (intensity * 85)) * (0.78 + (tubeWidth * 0.16)) * zoomDensity)),
      )
      const bidirectional = baWeight > 0
      const abMinWeight = bidirectional ? 0.1 : 0.05
      const abCount = Math.max(1, Math.floor(particlesOnEdge * Math.max(abMinWeight, abWeight)))
      const baCount = bidirectional ? Math.max(1, Math.floor(particlesOnEdge * Math.max(0.1, baWeight))) : 0
      const totalWeight = Math.max(0.0001, abWeight + baWeight)
      const abRatio = abWeight / totalWeight
      const baRatio = baWeight / totalWeight
      const abSpeed = Math.max(0.02, Math.min(0.12, baseSpeed * (0.86 + (abRatio * 0.24))))
      const baSpeed = Math.max(0.02, Math.min(0.12, baseSpeed * (0.86 + (baRatio * 0.24))))

      if (totalSignal > 0) {
        pushDirectionParticles({
          src,
          dst,
          edgeIndex: i,
          count: abCount,
          speedBase: abSpeed,
          jitter: jitterBase * spreadFill,
          utilization,
          laneOffset: baCount > 0 ? laneSeparation : 0,
        })

        if (baCount > 0) {
          pushDirectionParticles({
            src: dst,
            dst: src,
            edgeIndex: i + 700_000,
            count: baCount,
            speedBase: baSpeed,
            jitter: jitterBase * spreadFill,
            utilization,
            // Keep same signed offset for reverse direction; the segment normal flips with direction,
            // so this lands on the opposite side of the tube in world space.
            laneOffset: laneSeparation,
          })
        }
      }
    }

    if (cacheState) {
      cacheState.packetFlowCacheStamp = stamp
      cacheState.packetFlowCache = particles
    }
    return particles
  },
}

import {edgeTopologyVisualStyleValue} from "./rendering_style_edge_topology_methods"

const flowBlocks = new WeakMap()

/**
 * Packet flow is drawn one instance per edge: the particles themselves are computed in the
 * shader (see PacketFlowLayer). This builds the per-edge inputs as deck.gl binary attributes,
 * once per edge list -- a filter or a new snapshot produces a new list, the animation clock
 * and the camera do not.
 */
export const godViewRenderingStyleEdgeParticleMethods = {
  buildPacketFlowEdges(edgeData) {
    const edges = Array.isArray(edgeData) ? edgeData : []
    const cached = flowBlocks.get(edges)
    if (cached && cached.owner === this) return cached.block

    const endpoints = new Float32Array(edges.length * 4)
    const flow = new Float32Array(edges.length * 4)
    const shape = new Float32Array(edges.length * 4)
    const style = new Float32Array(edges.length * 2)
    const phase = edges.some(edge => edge.phaseStart !== undefined) ? new Float32Array(edges.length * 2) : null
    let count = 0
    let maxParticleBase = 0
    let particleBaseSum = 0

    for (let i = 0; i < edges.length; i += 1) {
      const edge = edges[i]
      if (edge?.telemetryEligible === false || edge?.telemetry_eligible === false) continue
      if (Array.isArray(edge?.path) && edge.path.length > 2) continue
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
      const totalDirectionalPps = ppsAb + ppsBa
      const totalDirectionalBps = bpsAb + bpsBa
      const totalSignal = totalDirectionalPps > 0 || totalDirectionalBps > 0
        ? Math.max(totalDirectionalPps, totalDirectionalBps)
        : Math.max(pps, bps)
      if (!(totalSignal > 0)) continue

      const topologyStyle = edgeTopologyVisualStyleValue(edge)
      const utilization = cap > 0 ? Math.min(1, bps / cap) : 0
      const bpsSignal = bps > 0 ? Math.min(1, Math.log10(Math.max(1, bps)) / 10) : 0
      const baseline = 1.05 + Math.min(1.0, Math.log10(Math.max(1, edge.weight || 1)) * 0.7)
      const trafficSignal = cap > 0 ? utilization : bpsSignal
      const intensity = Math.max(0.9, (baseline * 0.45) + (trafficSignal * 3.0))
      const abWeight = totalDirectionalPps > 0 ? (ppsAb / Math.max(1, totalDirectionalPps))
        : (totalDirectionalBps > 0 ? (bpsAb / Math.max(1, totalDirectionalBps)) : 1.0)
      const baWeight = totalDirectionalPps > 0 ? (ppsBa / Math.max(1, totalDirectionalPps))
        : (totalDirectionalBps > 0 ? (bpsBa / Math.max(1, totalDirectionalBps)) : 0.0)
      const baseSpeed = Math.min(0.11, 0.045 + (intensity * 0.014))
      const tubeWidth = typeof this.edgeWidthPixels === "function" ? this.edgeWidthPixels(cap, pps, bps) : 3.2
      const laneSeparation = Math.max(0.35, Math.min(2.6, tubeWidth * 0.22))
      const jitterBase = Math.max(1.1, Math.min(6.2, (tubeWidth * 0.32) + 0.95))
      const spreadFill = Math.max(0.8, Math.min(1.4, 0.9 + (utilization * 0.7)))
      // Particles per edge before the camera's density scale, which the shader applies.
      const particleBase = (95 + (intensity * 85)) * (0.78 + (tubeWidth * 0.16)) * topologyStyle.particleDensityScale

      if (particleBase > maxParticleBase) maxParticleBase = particleBase
      particleBaseSum += particleBase
      endpoints.set([Number(src[0]) || 0, Number(src[1]) || 0, Number(dst[0]) || 0, Number(dst[1]) || 0], count * 4)
      flow.set([particleBase, abWeight, baWeight, baseSpeed], count * 4)
      // The edge's index in the list seeds its particles, exactly as the per-particle layer did.
      const unit = edge.worldUnitsPerPixel ?? 1
      shape.set([laneSeparation * unit, jitterBase * spreadFill * unit, utilization, edge.flowSeed ?? i], count * 4)
      if (phase) phase.set([edge.phaseStart ?? 0, edge.phaseEnd ?? 1], count * 2)
      style.set([topologyStyle.particleAlphaScale, topologyStyle.particleSizeScale], count * 2)
      count += 1
    }

    const block = {
      length: count,
      // Sizes the draw: the busiest edge decides how many particles each instance issues.
      maxParticleBase,
      particleBaseSum,
      attributes: {
        instanceEndpoints: endpoints.subarray(0, count * 4),
        instanceFlow: flow.subarray(0, count * 4),
        instanceShape: shape.subarray(0, count * 4),
        instanceStyle: style.subarray(0, count * 2),
        ...(phase ? {instancePhase: phase.subarray(0, count * 2)} : {}),
      },
    }
    flowBlocks.set(edges, {owner: this, block})
    return block
  },
}

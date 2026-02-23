import {describe, expect, it} from "vitest"

import {godViewRenderingStyleEdgeParticleMethods} from "./rendering_style_edge_particle_methods"

describe("rendering_style_edge_particle_methods", () => {
  it("buildPacketFlowInstances enforces visibility floors on low-telemetry links", () => {
    const particles = godViewRenderingStyleEdgeParticleMethods.buildPacketFlowInstances([
      {
        sourcePosition: [0, 0, 0],
        targetPosition: [100, 0, 0],
        flowPps: 0,
        flowBps: 0,
        capacityBps: 0,
        weight: 1,
      },
    ])

    expect(particles.length).toBeGreaterThanOrEqual(24)
    const headParticles = particles.filter((p) => p.size > 12)
    const dustParticles = particles.filter((p) => p.size <= 12)
    expect(headParticles.length).toBeGreaterThan(0)
    expect(dustParticles.length).toBeGreaterThan(0)
    for (const particle of headParticles) {
      expect(particle.color[3]).toBeGreaterThanOrEqual(255)
      expect(particle.color[3]).toBeLessThanOrEqual(255)
    }
    for (const particle of dustParticles) {
      expect(particle.color[3]).toBeGreaterThanOrEqual(120)
      expect(particle.color[3]).toBeLessThanOrEqual(140)
    }
  })

  it("buildPacketFlowInstances keeps particle count bounded for larger edge sets", () => {
    const edgeData = Array.from({length: 2000}, (_, i) => ({
      sourcePosition: [i, 0, 0],
      targetPosition: [i + 1, 10, 0],
      flowPps: 10_000,
      flowBps: 100_000_000,
      capacityBps: 1_000_000_000,
      weight: 1,
    }))

    const particles = godViewRenderingStyleEdgeParticleMethods.buildPacketFlowInstances(edgeData)
    expect(particles.length).toBeLessThanOrEqual(60000)
  })
})

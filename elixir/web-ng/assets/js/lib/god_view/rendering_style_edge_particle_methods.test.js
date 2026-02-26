import {describe, expect, it} from "vitest"

import {godViewRenderingStyleEdgeParticleMethods} from "./rendering_style_edge_particle_methods"

describe("rendering_style_edge_particle_methods", () => {
  it("buildPacketFlowInstances enforces visibility floors on low-but-real telemetry links", () => {
    const particles = godViewRenderingStyleEdgeParticleMethods.buildPacketFlowInstances([
      {
        sourcePosition: [0, 0, 0],
        targetPosition: [100, 0, 0],
        flowPps: 10,
        flowBps: 1000,
        flowPpsAb: 10,
        flowPpsBa: 0,
        flowBpsAb: 1000,
        flowBpsBa: 0,
        capacityBps: 0,
        weight: 1,
      },
    ])

    expect(particles.length).toBeGreaterThanOrEqual(32)
    const headParticles = particles.filter((p) => p.size >= 3.8)
    const dustParticles = particles.filter((p) => p.size < 3.8)
    expect(headParticles.length).toBeGreaterThan(0)
    expect(dustParticles.length).toBeGreaterThan(0)
    for (const particle of headParticles) {
      expect(particle.size).toBeLessThanOrEqual(9.1)
      expect(particle.jitter).toBeLessThanOrEqual(10.5)
      expect(particle.color[3]).toBeGreaterThanOrEqual(90)
      expect(particle.color[3]).toBeLessThanOrEqual(255)
    }
    for (const particle of dustParticles) {
      expect(particle.size).toBeLessThanOrEqual(3.8)
      expect(particle.jitter).toBeLessThanOrEqual(10.5)
      expect(particle.color[3]).toBeGreaterThanOrEqual(75)
      expect(particle.color[3]).toBeLessThanOrEqual(255)
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

  it("buildPacketFlowInstances skips telemetry-ineligible edges", () => {
    const particles = godViewRenderingStyleEdgeParticleMethods.buildPacketFlowInstances([
      {
        sourcePosition: [0, 0, 0],
        targetPosition: [20, 0, 0],
        flowPps: 1000,
        flowBps: 1_000_000,
        capacityBps: 10_000_000,
        telemetryEligible: false,
      },
      {
        sourcePosition: [0, 5, 0],
        targetPosition: [20, 5, 0],
        flowPps: 1000,
        flowBps: 1_000_000,
        capacityBps: 10_000_000,
        telemetryEligible: true,
      },
    ])

    expect(particles.length).toBeGreaterThan(0)
    for (const particle of particles) {
      expect(particle.from).toEqual([0, 5])
      expect(particle.to).toEqual([20, 5])
    }
  })

  it("buildPacketFlowInstances renders reverse lane only when real BA directional telemetry exists", () => {
    const noReverse = godViewRenderingStyleEdgeParticleMethods.buildPacketFlowInstances([
      {
        sourcePosition: [0, 0, 0],
        targetPosition: [100, 0, 0],
        flowPps: 500,
        flowBps: 5_000_000,
        flowPpsAb: 500,
        flowPpsBa: 0,
        flowBpsAb: 5_000_000,
        flowBpsBa: 0,
        capacityBps: 10_000_000,
        telemetryEligible: true,
      },
    ])

    expect(noReverse.length).toBeGreaterThan(0)
    expect(noReverse.every((p) => p.from[0] === 0 && p.to[0] === 100)).toBe(true)
    expect(noReverse.every((p) => p.laneOffset === 0)).toBe(true)

    const withReverse = godViewRenderingStyleEdgeParticleMethods.buildPacketFlowInstances([
      {
        sourcePosition: [0, 0, 0],
        targetPosition: [100, 0, 0],
        flowPps: 500,
        flowBps: 5_000_000,
        flowPpsAb: 300,
        flowPpsBa: 200,
        flowBpsAb: 3_000_000,
        flowBpsBa: 2_000_000,
        capacityBps: 10_000_000,
        telemetryEligible: true,
      },
    ])

    expect(withReverse.length).toBeGreaterThan(0)
    const forward = withReverse.filter((p) => p.from[0] === 0 && p.to[0] === 100)
    const reverse = withReverse.filter((p) => p.from[0] === 100 && p.to[0] === 0)
    expect(forward.length).toBeGreaterThan(0)
    expect(reverse.length).toBeGreaterThan(0)
    expect(forward.every((p) => p.laneOffset > 0)).toBe(true)
    expect(reverse.every((p) => p.laneOffset > 0)).toBe(true)
  })

  it("buildPacketFlowInstances uses directional ratios to bias per-lane density", () => {
    const particles = godViewRenderingStyleEdgeParticleMethods.buildPacketFlowInstances([
      {
        sourcePosition: [0, 0, 0],
        targetPosition: [100, 0, 0],
        flowPps: 1000,
        flowBps: 10_000_000,
        flowPpsAb: 900,
        flowPpsBa: 100,
        flowBpsAb: 9_000_000,
        flowBpsBa: 1_000_000,
        capacityBps: 20_000_000,
        telemetryEligible: true,
      },
    ])

    const forward = particles.filter((p) => p.from[0] === 0 && p.to[0] === 100)
    const reverse = particles.filter((p) => p.from[0] === 100 && p.to[0] === 0)
    expect(forward.length).toBeGreaterThan(reverse.length)
  })

  it("buildPacketFlowInstances scales density by zoom tier", () => {
    const edge = {
      sourcePosition: [0, 0, 0],
      targetPosition: [100, 0, 0],
      flowPps: 1000,
      flowBps: 10_000_000,
      flowPpsAb: 600,
      flowPpsBa: 400,
      flowBpsAb: 6_000_000,
      flowBpsBa: 4_000_000,
      capacityBps: 20_000_000,
      telemetryEligible: true,
    }

    const farCtx = {
      state: {viewState: {zoom: -1}},
      edgeWidthPixels: () => 4.0,
      ...godViewRenderingStyleEdgeParticleMethods,
    }
    const nearCtx = {
      state: {viewState: {zoom: 3}},
      edgeWidthPixels: () => 4.0,
      ...godViewRenderingStyleEdgeParticleMethods,
    }

    const farParticles = farCtx.buildPacketFlowInstances([edge])
    const nearParticles = nearCtx.buildPacketFlowInstances([edge])
    expect(nearParticles.length).toBeGreaterThan(farParticles.length)
  })
})

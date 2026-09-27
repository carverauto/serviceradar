import {describe, expect, it, vi} from "vitest"

import {bindApi, createStateBackedContext} from "./api_helpers"
import {godViewRenderingGraphLayerTransportMethods} from "./rendering_graph_layer_transport_methods"
import {godViewRenderingStyleEdgeParticleMethods} from "./rendering_style_edge_particle_methods"
import {edgeTopologyVisualStyleValue} from "./rendering_style_edge_topology_methods"
import {GOD_VIEW_ADDITIVE_BLEND} from "./gpu_parameters"
import {
  MAX_PARTICLES_PER_LANE,
  MAX_PARTICLE_SIZE,
  MIN_PARTICLES_PER_LANE,
  PACKET_FLOW_STYLE,
  PACKET_FLOW_WGSL,
  packetFlowMagentaBias,
} from "../deckgl/PacketFlowLayer"

// Packet flow used to be one instance per dot, built on the CPU; the WebGPU layer computes the
// dots in its shader from one instance per edge. This pins the look to the old layer: the
// reference below is its particle builder and layer accessors, transcribed, minus the 60000-dot
// global cap (which dropped every edge past the first few hundred rather than styling any).

const CYAN = [116, 223, 166, 255]
const MAGENTA = [244, 114, 255, 255]

function cameraScales(zoom) {
  const zoomParticleVisibility = Math.max(0.14, Math.min(1.0, (zoom + 2.2) / 3.6))
  return {
    zoomDensity: Math.max(0.55, Math.min(1.25, (zoom + 2.5) / 4.5)),
    zoomParticleAlphaScale: Math.max(0.35, zoomParticleVisibility),
    zoomSpreadScale: Math.max(1.0, Math.min(1.35, 1.0 + ((1.0 - zoomParticleVisibility) * 0.35))),
  }
}

// The per-particle reference, as drawn: sizes in device pixels, jitter and lane offset in world
// units along the edge normal, alpha after the camera's scale.
function referenceParticles(edgeData, zoom, edgeWidthPixels) {
  const {zoomDensity, zoomParticleAlphaScale, zoomSpreadScale} = cameraScales(zoom)
  const lanes = []
  edgeData.forEach((edge, i) => {
    const topologyStyle = edgeTopologyVisualStyleValue(edge)
    const pps = Number(edge.flowPps || 0)
    const bps = Number(edge.flowBps || 0)
    const ppsAb = Number(edge.flowPpsAb || 0)
    const ppsBa = Number(edge.flowPpsBa || 0)
    const cap = Number(edge.capacityBps || 0)
    const utilization = cap > 0 ? Math.min(1, bps / cap) : 0
    const bpsSignal = bps > 0 ? Math.min(1, Math.log10(Math.max(1, bps)) / 10) : 0
    const baseline = 1.05 + Math.min(1.0, Math.log10(Math.max(1, edge.weight || 1)) * 0.7)
    const trafficSignal = cap > 0 ? utilization : bpsSignal
    const intensity = Math.max(0.9, (baseline * 0.45) + (trafficSignal * 3.0))
    const totalDirectionalPps = ppsAb + ppsBa
    const abWeight = totalDirectionalPps > 0 ? ppsAb / Math.max(1, totalDirectionalPps) : 1.0
    const baWeight = totalDirectionalPps > 0 ? ppsBa / Math.max(1, totalDirectionalPps) : 0.0
    const baseSpeed = Math.min(0.11, 0.045 + (intensity * 0.014))
    const tubeWidth = edgeWidthPixels(cap, pps, bps)
    const laneSeparation = Math.max(0.35, Math.min(2.6, tubeWidth * 0.22))
    const jitterBase = Math.max(1.1, Math.min(6.2, (tubeWidth * 0.32) + 0.95))
    const spreadFill = Math.max(0.8, Math.min(1.4, 0.9 + (utilization * 0.7)))
    const particlesOnEdge = Math.max(18, Math.min(1400, Math.floor(
      (95 + (intensity * 85)) * (0.78 + (tubeWidth * 0.16)) * zoomDensity * topologyStyle.particleDensityScale,
    )))
    const bidirectional = baWeight > 0
    const abCount = Math.max(1, Math.floor(particlesOnEdge * Math.max(bidirectional ? 0.1 : 0.05, abWeight)))
    const baCount = bidirectional ? Math.max(1, Math.floor(particlesOnEdge * Math.max(0.1, baWeight))) : 0
    const totalWeight = Math.max(0.0001, abWeight + baWeight)
    const abSpeed = Math.max(0.02, Math.min(0.12, baseSpeed * (0.86 + ((abWeight / totalWeight) * 0.24))))
    const baSpeed = Math.max(0.02, Math.min(0.12, baseSpeed * (0.86 + ((baWeight / totalWeight) * 0.24))))

    const lane = (edgeIndex, count, speedBase, laneOffset) => {
      const particles = []
      for (let j = 0; j < count; j += 1) {
        const seed = (((edgeIndex * 17 + j * 37) % 997) + 1) / 997
        const noise = (((edgeIndex * 131) + (j * 17)) % 100) / 100
        const isHead = noise > 0.95
        const magentaBias = Math.min(0.85, Math.max(0.15, (utilization * 0.65) + 0.2))
        const color = noise < magentaBias ? MAGENTA : CYAN
        const alpha = Math.max(70, Math.min(255, Math.round(255 * topologyStyle.particleAlphaScale)))
        particles.push({
          speed: Math.min(0.12, speedBase * (0.9 + (((j * 43) % 101) / 100) * 0.18)),
          size: Math.max(1, (isHead ? (6 + (seed * 3)) : (2 + (seed * 3))) * topologyStyle.particleSizeScale),
          isHead,
          jitter: jitterBase * spreadFill * zoomSpreadScale,
          laneOffset,
          magenta: color === MAGENTA,
          alpha: Math.round(alpha * zoomParticleAlphaScale) / 255,
        })
      }
      return particles
    }
    lanes.push({
      edge: i,
      utilization,
      sizeScale: topologyStyle.particleSizeScale,
      ab: {count: abCount, speed: abSpeed, particles: lane(i, abCount, abSpeed, baCount > 0 ? laneSeparation : 0)},
      ba: {count: baCount, speed: baSpeed, particles: lane(i + 700_000, baCount, baSpeed, laneSeparation)},
    })
  })
  return lanes
}

// What the shader computes per lane from the per-edge attributes and the layer's uniforms.
function shaderLanes(flow, zoomDensity) {
  const [particleBase, abWeight, baWeight, baseSpeed] = flow
  const total = Math.min(MAX_PARTICLES_PER_LANE, Math.max(MIN_PARTICLES_PER_LANE, Math.floor(particleBase * zoomDensity)))
  const bidirectional = baWeight > 0
  const totalWeight = Math.max(0.0001, abWeight + baWeight)
  return {
    abCount: Math.max(1, Math.floor(total * Math.max(bidirectional ? 0.1 : 0.05, abWeight))),
    baCount: bidirectional ? Math.max(1, Math.floor(total * Math.max(0.1, baWeight))) : 0,
    abSpeed: Math.min(0.12, Math.max(0.02, baseSpeed * (0.86 + ((abWeight / totalWeight) * 0.24)))),
    baSpeed: Math.min(0.12, Math.max(0.02, baseSpeed * (0.86 + ((baWeight / totalWeight) * 0.24)))),
  }
}

const EDGES = [
  // idle-ish one-way link
  {sourcePosition: [0, 0, 0], targetPosition: [400, 0, 0], flowPps: 120, flowPpsAb: 120, flowBps: 2_000_000, capacityBps: 1_000_000_000},
  // half-utilized, mostly one direction
  {sourcePosition: [0, 0, 0], targetPosition: [0, 300, 0], flowPps: 900, flowPpsAb: 700, flowPpsBa: 200, flowBps: 500_000_000, capacityBps: 1_000_000_000},
  // saturated, balanced
  {sourcePosition: [10, 10, 0], targetPosition: [250, 190, 0], flowPps: 5000, flowPpsAb: 2500, flowPpsBa: 2500, flowBps: 1_000_000_000, capacityBps: 1_000_000_000},
  // no capacity known: utilization 0
  {sourcePosition: [0, 0, 0], targetPosition: [-200, 80, 0], flowPps: 300, flowPpsAb: 100, flowPpsBa: 200, flowBps: 40_000_000},
]

// A tube width that varies with traffic, like the real one, so the width-derived numbers vary.
const edgeWidthPixels = (capacityBps, flowPps, flowBps) =>
  1.2 + Math.min(4, Math.log10(Math.max(1, Number(flowBps || 0))) / 3) + (capacityBps ? 0.5 : 0)

function branchLayer(zoom) {
  const state = {
    animationPhase: 3,
    viewState: {zoom},
    layers: {mantle: false, crust: false, atmosphere: true, security: false},
    packetFlowEnabled: true,
    visual: {pulse: [255, 64, 64, 220], particleCyan: CYAN, particleMagenta: MAGENTA, particleBlend: GOD_VIEW_ADDITIVE_BLEND},
  }
  const ctx = createStateBackedContext(state, {geoGridData: vi.fn(() => [])})
  Object.assign(ctx, bindApi(ctx, godViewRenderingGraphLayerTransportMethods), {
    buildPacketFlowEdges: godViewRenderingStyleEdgeParticleMethods.buildPacketFlowEdges,
    edgeTelemetryColor: vi.fn(() => [40, 170, 220, 45]),
    edgeTelemetryArcColors: vi.fn(() => ({source: [100, 100, 255, 120], target: [200, 120, 255, 120]})),
    edgeWidthPixels,
    edgeIsFocused: vi.fn(() => false),
  })
  const [layer] = ctx.buildTransportAndEffectLayers({shape: "local"}, [], EDGES).atmosphereLayers
  const {attributes} = layer.props.data
  const row = (name, size, i) => Array.from(attributes[name].subarray(i * size, (i + 1) * size))
  return {
    props: layer.props,
    edges: EDGES.map((_, i) => ({
      flow: row("instanceFlow", 4, i),
      shape: row("instanceShape", 4, i),
      style: row("instanceStyle", 2, i),
    })),
  }
}

const ZOOMS = [-5, -3.5, -1, 0.5]

describe("packet flow parity with the per-particle layer it replaced", () => {
  it("builds its constants into the shader", () => {
    for (const [name, value] of [
      ["PARTICLE_SIZE", PACKET_FLOW_STYLE.particleSize],
      ["HEAD_SIZE", PACKET_FLOW_STYLE.headSize],
      ["SIZE_RANGE", PACKET_FLOW_STYLE.sizeRange],
      ["HEAD_THRESHOLD", PACKET_FLOW_STYLE.headThreshold],
      ["MAGENTA_BIAS_PER_UTILIZATION", PACKET_FLOW_STYLE.magentaBiasPerUtilization],
      ["MAX_PARTICLE_SIZE", MAX_PARTICLE_SIZE],
    ]) {
      expect(PACKET_FLOW_WGSL).toMatch(new RegExp(`const ${name}: f32 = ${String(value).replace(".", "\\.")}(\\.0)?;`))
    }
  })

  it.each(ZOOMS)("passes the same camera scales and colors as uniforms at zoom %s", (zoom) => {
    const {props} = branchLayer(zoom)
    const scales = cameraScales(zoom)
    expect(props.zoomDensity).toBeCloseTo(scales.zoomDensity, 10)
    expect(props.spreadScale).toBeCloseTo(scales.zoomSpreadScale, 10)
    expect(props.alphaScale).toBeCloseTo(scales.zoomParticleAlphaScale, 10)
    expect(props.cyan).toEqual(CYAN)
    expect(props.magenta).toEqual(MAGENTA)
    expect(props.parameters).toBe(GOD_VIEW_ADDITIVE_BLEND)
  })

  it.each(ZOOMS)("puts as many particles on each lane, at the same speeds, at zoom %s", (zoom) => {
    const {props, edges} = branchLayer(zoom)
    const reference = referenceParticles(EDGES, zoom, edgeWidthPixels)
    edges.forEach((edge, i) => {
      const lanes = shaderLanes(edge.flow, props.zoomDensity)
      // particleBase is stored as float32; flooring it can land one particle either side.
      expect(Math.abs(lanes.abCount - reference[i].ab.count)).toBeLessThanOrEqual(1)
      expect(Math.abs(lanes.baCount - reference[i].ba.count)).toBeLessThanOrEqual(1)
      expect(lanes.abSpeed).toBeCloseTo(reference[i].ab.speed, 5)
      if (reference[i].ba.count > 0) expect(lanes.baSpeed).toBeCloseTo(reference[i].ba.speed, 5)
      // The old layer varied each dot's speed by -10%..+8% around its lane's; the shader does not.
      for (const particle of reference[i].ab.particles) {
        expect(particle.speed / reference[i].ab.speed).toBeGreaterThanOrEqual(0.9 - 1e-9)
        expect(particle.speed / reference[i].ab.speed).toBeLessThanOrEqual(1.08 + 1e-9)
      }
    })
  })

  it("draws dots of the same pixel sizes", () => {
    const {edges} = branchLayer(-3.5)
    const reference = referenceParticles(EDGES, -3.5, edgeWidthPixels)
    edges.forEach((edge, i) => {
      // The attribute is float32; compare against the reference's exact scale.
      expect(edge.style[1]).toBeCloseTo(reference[i].sizeScale, 6)
      const sizeScale = reference[i].sizeScale
      const particles = [...reference[i].ab.particles, ...reference[i].ba.particles]
      const body = particles.filter((particle) => !particle.isHead).map((particle) => particle.size)
      const heads = particles.filter((particle) => particle.isHead).map((particle) => particle.size)
      const style = PACKET_FLOW_STYLE
      // The shader draws size = (base + seed * range) * scale, seed in [0, 1), in device pixels.
      expect(Math.min(...body)).toBeGreaterThanOrEqual(Math.max(1, style.particleSize * sizeScale) - 1e-9)
      expect(Math.max(...body)).toBeLessThanOrEqual((style.particleSize + style.sizeRange) * sizeScale + 1e-9)
      expect(Math.max(...body)).toBeGreaterThan((style.particleSize + style.sizeRange * 0.95) * sizeScale)
      expect(Math.min(...heads)).toBeGreaterThanOrEqual(style.headSize * sizeScale - 1e-9)
      expect(Math.max(...heads)).toBeLessThanOrEqual(MAX_PARTICLE_SIZE * sizeScale + 1e-9)
      // One dot in 25 is a head.
      expect(Math.abs((heads.length / particles.length) - (1 - style.headThreshold))).toBeLessThan(0.01)
    })
  })

  it.each(ZOOMS)("spreads dots across the same lanes and jitter at zoom %s", (zoom) => {
    const {props, edges} = branchLayer(zoom)
    const reference = referenceParticles(EDGES, zoom, edgeWidthPixels)
    edges.forEach((edge, i) => {
      const [laneSeparation, jitter] = edge.shape
      const bidirectional = reference[i].ba.count > 0
      // Old layer: a dot sits at laneOffset + u * jitter along the normal, u uniform in [-1, 1].
      const referenceReach = Math.max(...reference[i].ab.particles.map((particle) => particle.laneOffset + particle.jitter))
      const shaderReach = (bidirectional ? laneSeparation : 0) + (jitter * props.spreadScale)
      expect(shaderReach).toBeCloseTo(referenceReach, 4)
      if (bidirectional) {
        expect(laneSeparation).toBeCloseTo(reference[i].ba.particles[0].laneOffset, 5)
      }
    })
  })

  it("draws the same share of dots magenta for a given utilization", () => {
    const {edges} = branchLayer(-1)
    const reference = referenceParticles(EDGES, -1, edgeWidthPixels)
    edges.forEach((edge, i) => {
      const utilization = edge.shape[2]
      expect(utilization).toBeCloseTo(reference[i].utilization, 6)
      const particles = [...reference[i].ab.particles, ...reference[i].ba.particles]
      const referenceShare = particles.filter((particle) => particle.magenta).length / particles.length
      expect(Math.abs(packetFlowMagentaBias(utilization) - referenceShare)).toBeLessThan(0.03)
    })
    // Utilization moves the share between the clamps, so a busy link reads differently.
    expect(packetFlowMagentaBias(0)).toBeCloseTo(0.2, 6)
    expect(packetFlowMagentaBias(0.5)).toBeCloseTo(0.525, 6)
    expect(packetFlowMagentaBias(1)).toBeCloseTo(0.85, 6)
  })

  it.each(ZOOMS)("draws each dot at the same peak alpha at zoom %s", (zoom) => {
    const {props, edges} = branchLayer(zoom)
    const reference = referenceParticles(EDGES, zoom, edgeWidthPixels)
    edges.forEach((edge, i) => {
      const shaderAlpha = Math.max(PACKET_FLOW_STYLE.minAlpha, Math.min(1, edge.style[0])) * props.alphaScale
      expect(Math.abs(shaderAlpha - reference[i].ab.particles[0].alpha)).toBeLessThanOrEqual(1 / 255)
    })
  })
})

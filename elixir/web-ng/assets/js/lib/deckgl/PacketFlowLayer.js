import {Layer, project32} from "@deck.gl/core"
import {Model} from "@luma.gl/engine"

// Animated packet flow along topology edges, drawn on WebGPU with one instance per edge.
//
// Each instance is an edge; each particle on it is six vertices of a small screen-space square,
// numbered by `vertex_index`. The vertex shader derives particle j of the edge exactly as the
// per-particle layer this replaced did on the CPU -- its seed, speed variation, color, jitter and
// size from the edge index and j -- and places it by the time uniform. Vertices past the edge's
// own particle count collapse to nothing. So the look is that layer's, particle for particle:
// the same positions, the same clumping into beads as their speeds drift apart, the same colors.
//
// Nothing per particle exists on the CPU, animation only advances `time`, and the pipeline needs
// at most 5 vertex buffers (the per-edge attributes) whatever the traffic.

export const MAX_PARTICLES_PER_LANE = 1400
export const MIN_PARTICLES_PER_LANE = 18

// The look, number for number from the per-particle layer this replaced. Dots are 2-5 device
// pixels across; a "head" is 6-9. Noise is quantized to hundredths, so "above 0.95" is 4% of dots.
// Magenta takes a share of dots that grows with the link's utilization, cyan the rest; alpha is
// never below 70/255.
export const PACKET_FLOW_STYLE = Object.freeze({
  particleSize: 2,
  headSize: 6,
  sizeRange: 3,
  headThreshold: 0.95,
  magentaBiasBase: 0.2,
  magentaBiasPerUtilization: 0.65,
  magentaBiasMin: 0.15,
  magentaBiasMax: 0.85,
  minAlpha: 70,
})
// Largest particle diameter in device pixels at size scale 1: a head with the largest seed.
export const MAX_PARTICLE_SIZE = PACKET_FLOW_STYLE.headSize + PACKET_FLOW_STYLE.sizeRange
// Particles drawn per frame across all edges before every edge's density is scaled down alike.
// The old layer stopped at 60000 and left every later edge bare; this keeps all edges moving and
// bounds the vertex work on large graphs. Graphs under it draw exactly the old layer's particles.
export const PACKET_FLOW_PARTICLE_BUDGET = 1_000_000

/** The density uniform for a zoom density: scaled down only when the frame would pass the budget. */
export function packetFlowDensity(zoomDensity, particleBaseSum) {
  const wanted = Number(particleBaseSum) * zoomDensity
  return wanted > PACKET_FLOW_PARTICLE_BUDGET ? zoomDensity * (PACKET_FLOW_PARTICLE_BUDGET / wanted) : zoomDensity
}

// The reverse lane numbers its particles as edge index + this, as the old layer did.
export const REVERSE_LANE_EDGE_OFFSET = 700_000

/** Share of an edge's particles drawn magenta, for a utilization in 0..1. */
export function packetFlowMagentaBias(utilization) {
  const style = PACKET_FLOW_STYLE
  const bias = (utilization * style.magentaBiasPerUtilization) + style.magentaBiasBase
  return Math.max(style.magentaBiasMin, Math.min(style.magentaBiasMax, bias))
}

/**
 * Particles one edge can have at a zoom density: both lanes together, an upper bound. The draw
 * issues this many particles per edge; each edge collapses the ones past its own count.
 */
export function packetFlowParticleBound(maxParticleBase, zoomDensity) {
  const total = Math.min(MAX_PARTICLES_PER_LANE, Math.max(MIN_PARTICLES_PER_LANE, Math.floor(maxParticleBase * zoomDensity)))
  // Each lane takes max(0.1, its share) of the total, rounded down but at least 1.
  return Math.ceil(total * 1.1) + 2
}

function wgslFloat(value) {
  return Number.isInteger(value) ? `${value}.0` : String(value)
}

// Bound by name: the uniform variable below is `packetFlow`, matching the module name. The
// vec4 members come first so the WGSL struct and luma's uniform buffer agree on alignment.
const packetFlowUniforms = {
  name: "packetFlow",
  source: "",
  uniformTypes: {
    cyan: "vec4<f32>",
    magenta: "vec4<f32>",
    time: "f32",
    zoomDensity: "f32",
    spreadScale: "f32",
    alphaScale: "f32",
  },
}

export const PACKET_FLOW_WGSL = /* wgsl */ `\
struct PacketFlowUniforms {
  cyan: vec4<f32>,
  magenta: vec4<f32>,
  time: f32,
  zoomDensity: f32,
  spreadScale: f32,
  alphaScale: f32,
};

@group(0) @binding(0) var<uniform> packetFlow: PacketFlowUniforms;

const MAX_PARTICLES_PER_LANE: f32 = ${wgslFloat(MAX_PARTICLES_PER_LANE)};
const MIN_PARTICLES_PER_LANE: f32 = ${wgslFloat(MIN_PARTICLES_PER_LANE)};
const PARTICLE_SIZE: f32 = ${wgslFloat(PACKET_FLOW_STYLE.particleSize)};
const HEAD_SIZE: f32 = ${wgslFloat(PACKET_FLOW_STYLE.headSize)};
const SIZE_RANGE: f32 = ${wgslFloat(PACKET_FLOW_STYLE.sizeRange)};
const HEAD_THRESHOLD: f32 = ${wgslFloat(PACKET_FLOW_STYLE.headThreshold)};
const MAGENTA_BIAS_BASE: f32 = ${wgslFloat(PACKET_FLOW_STYLE.magentaBiasBase)};
const MAGENTA_BIAS_PER_UTILIZATION: f32 = ${wgslFloat(PACKET_FLOW_STYLE.magentaBiasPerUtilization)};
const MAGENTA_BIAS_MIN: f32 = ${wgslFloat(PACKET_FLOW_STYLE.magentaBiasMin)};
const MAGENTA_BIAS_MAX: f32 = ${wgslFloat(PACKET_FLOW_STYLE.magentaBiasMax)};
const MIN_ALPHA: f32 = ${wgslFloat(PACKET_FLOW_STYLE.minAlpha)};
const REVERSE_LANE_EDGE_OFFSET: i32 = ${REVERSE_LANE_EDGE_OFFSET};

struct Attributes {
  @builtin(vertex_index) vertexIndex: u32,
  // source.xy, target.xy
  @location(0) instanceEndpoints: vec4<f32>,
  // particle count before zoom density, A->B weight, B->A weight, base speed
  @location(1) instanceFlow: vec4<f32>,
  // lane separation, jitter, utilization, edge index
  @location(2) instanceShape: vec4<f32>,
  // alpha scale, size scale
  @location(3) instanceStyle: vec2<f32>,
  // The clipped interval of the canonical edge; ordinary scenes use 0..1.
  @location(4) instancePhase: vec2<f32>,
};

struct Varyings {
  @builtin(position) position: vec4<f32>,
  // Position inside the dot's square, -0.5..0.5 on both axes.
  @location(0) corner: vec2<f32>,
  @location(1) color: vec4<f32>,
};

fn packetFlowRand(seed: f32) -> f32 {
  return fract(sin(dot(vec2<f32>(seed, seed), vec2<f32>(12.9898, 78.233))) * 43758.5453);
}

fn collapsed() -> Varyings {
  var varyings: Varyings;
  varyings.position = vec4<f32>(-2.0, -2.0, 0.0, 1.0);
  varyings.corner = vec2<f32>(0.0);
  varyings.color = vec4<f32>(0.0);
  return varyings;
}

@vertex
fn vertexMain(attributes: Attributes) -> Varyings {
  let flowInputs = attributes.instanceFlow;
  let shapeInputs = attributes.instanceShape;
  let styleInputs = attributes.instanceStyle;

  let total = clamp(floor(flowInputs.x * packetFlow.zoomDensity), MIN_PARTICLES_PER_LANE, MAX_PARTICLES_PER_LANE);
  let bidirectional = flowInputs.z > 0.0;
  let abCount = select(0.0, max(1.0, floor(total * max(select(0.05, 0.1, bidirectional), flowInputs.y))), flowInputs.y > 0.0);
  let baCount = select(0.0, max(1.0, floor(total * max(0.1, flowInputs.z))), bidirectional);
  let particle = f32(attributes.vertexIndex / 6u);
  if (particle >= abCount + baCount) {
    return collapsed();
  }

  // A->B particles first, then B->A; each lane numbers its own from 0.
  let reverse = particle >= abCount;
  let j = i32(select(particle, particle - abCount, reverse));
  let edgeIndex = i32(shapeInputs.w) + select(0, REVERSE_LANE_EDGE_OFFSET, reverse);
  let totalWeight = max(0.0001, flowInputs.y + flowInputs.z);
  let laneWeight = select(flowInputs.y, flowInputs.z, reverse);
  let laneSpeed = clamp(flowInputs.w * (0.86 + ((laneWeight / totalWeight) * 0.24)), 0.02, 0.12);

  let seed = f32(((edgeIndex * 17 + j * 37) % 997) + 1) / 997.0;
  let speed = min(0.12, laneSpeed * (0.9 + (f32((j * 43) % 101) / 100.0) * 0.18));
  let noise = f32((edgeIndex * 131 + j * 17) % 100) / 100.0;
  let isHead = noise > HEAD_THRESHOLD;
  let magentaBias = clamp((shapeInputs.z * MAGENTA_BIAS_PER_UTILIZATION) + MAGENTA_BIAS_BASE, MAGENTA_BIAS_MIN, MAGENTA_BIAS_MAX);
  let tint = select(packetFlow.cyan.rgb, packetFlow.magenta.rgb, noise < magentaBias);
  let baseAlpha = round(clamp(round(255.0 * styleInputs.x), MIN_ALPHA, 255.0) * packetFlow.alphaScale) / 255.0;
  // Device pixels, as gl_PointSize was.
  let size = max(1.0, (select(PARTICLE_SIZE, HEAD_SIZE, isHead) + seed * SIZE_RANGE) * styleInputs.y);

  let sourcePosition = attributes.instanceEndpoints.xy;
  let targetPosition = attributes.instanceEndpoints.zw;
  let fromPosition = select(sourcePosition, targetPosition, reverse);
  let toPosition = select(targetPosition, sourcePosition, reverse);
  let span = toPosition - fromPosition;
  if (dot(span, span) <= 0.0) {
    return collapsed();
  }
  let progress = fract(seed + packetFlow.time * speed);
  let interval = select(attributes.instancePhase, vec2<f32>(1.0 - attributes.instancePhase.y, 1.0 - attributes.instancePhase.x), reverse);
  if (progress < interval.x || progress >= interval.y || interval.y <= interval.x) {
    return collapsed();
  }
  let localProgress = (progress - interval.x) / (interval.y - interval.x);
  let direction = normalize(span);
  let normal = vec2<f32>(-direction.y, direction.x);
  // The B->A lane keeps the same signed offset: its normal is flipped, so it lands opposite.
  let laneOffset = select(0.0, shapeInputs.x, baCount > 0.0);
  let jitter = (packetFlowRand(seed) - 0.5) * 2.0 * shapeInputs.y * packetFlow.spreadScale;
  let center = mix(fromPosition, toPosition, localProgress) + normal * (laneOffset + jitter);

  // Two triangles over the dot's square: corners 0 1 2 / 2 1 3.
  let vertex = attributes.vertexIndex % 6u;
  let cornerId = select(select(vertex, 2u, vertex == 3u), select(1u, 3u, vertex == 5u), vertex >= 4u);
  let corner = vec2<f32>(select(-0.5, 0.5, cornerId == 1u || cornerId == 3u), select(-0.5, 0.5, cornerId >= 2u));

  var varyings: Varyings;
  var clip = project_position_to_clipspace(vec3<f32>(center, 0.0), vec3<f32>(0.0), vec3<f32>(0.0));
  clip = vec4<f32>(clip.xy + corner * size * 2.0 / project.viewportSize * clip.w, clip.zw);
  varyings.position = clip;
  varyings.corner = corner;
  // Fade out near both endpoints so node areas stay clean.
  let fade = smoothstep(0.0, 0.18, progress) * (1.0 - smoothstep(0.82, 1.0, progress));
  varyings.color = vec4<f32>(tint, baseAlpha * fade);
  return varyings;
}

@fragment
fn fragmentMain(varyings: Varyings) -> @location(0) vec4<f32> {
  let dist = length(varyings.corner);
  if (dist > 0.5) {
    discard;
  }
  let core = 1.0 - smoothstep(0.0, 0.2, dist);
  let glow = (1.0 - smoothstep(0.2, 0.5, dist)) * 0.6;
  let alpha = varyings.color.a * (core + glow);
  // Premultiplied, for the additive blend: each dot adds its color times its alpha.
  return vec4<f32>(varyings.color.rgb * alpha, alpha);
}
`

const DEFAULT_CYAN = [73, 231, 255, 255]
const DEFAULT_MAGENTA = [244, 114, 255, 255]

function unitColor(value, fallback) {
  const rgba = Array.isArray(value) ? value : fallback
  return rgba.map((channel) => Math.max(0, Math.min(1, Number(channel ?? 255) / 255)))
}

export default class PacketFlowLayer extends Layer {
  static get layerName() {
    return "PacketFlowLayer"
  }

  static get componentName() {
    return "PacketFlowLayer"
  }

  getShaders() {
    return super.getShaders({source: PACKET_FLOW_WGSL, modules: [project32, packetFlowUniforms]})
  }

  initializeState() {
    // Per-edge inputs arrive as binary attributes (`data.attributes`), built once per edge list.
    this.getAttributeManager().addInstanced({
      instanceEndpoints: {size: 4, accessor: "getEndpoints"},
      instanceFlow: {size: 4, accessor: "getFlow"},
      instanceShape: {size: 4, accessor: "getShape"},
      instanceStyle: {size: 2, accessor: "getStyle"},
      instancePhase: {size: 2, accessor: "getPhase"},
    })
    this.state.model = this._getModel()
  }

  updateState(params) {
    super.updateState(params)
    if (params.changeFlags.extensionsChanged || !this.state.model) {
      this.state.model?.destroy()
      this.state.model = this._getModel()
      this.getAttributeManager().invalidateAll()
    }
  }

  _getModel() {
    // No per-vertex buffer: vertices are numbered, six per particle, and the shader builds them.
    return new Model(this.context.device, {
      ...this.getShaders(),
      id: this.props.id,
      bufferLayout: this.getAttributeManager().getBufferLayouts(),
      topology: "triangle-list",
      vertexCount: 6,
      isInstanced: true,
    })
  }

  /** Vertices each edge instance issues: six per particle, for the busiest edge at this zoom. */
  vertexCount() {
    const maxParticleBase = Number(this.props.data?.maxParticleBase) || 0
    return 6 * packetFlowParticleBound(maxParticleBase, Number(this.props.zoomDensity) || 1)
  }

  draw(opts) {
    const {time, zoomDensity, spreadScale, alphaScale, cyan, magenta} = this.props
    const model = this.state.model
    if (!model) return
    model.setVertexCount(this.vertexCount())
    model.shaderInputs.setProps({
      packetFlow: {
        cyan: unitColor(cyan, DEFAULT_CYAN),
        magenta: unitColor(magenta, DEFAULT_MAGENTA),
        time: this.props.animate ? performance.now() / 1000 : Number(time) || 0,
        zoomDensity: Number(zoomDensity) || 1,
        spreadScale: Number(spreadScale) || 1,
        alphaScale: Number(alphaScale) || 1,
      },
    })
    super.draw(opts)
  }
}

PacketFlowLayer.defaultProps = {
  // Binary data supplies these attributes; the accessors only exist so deck can name them.
  getEndpoints: {type: "accessor", value: [0, 0, 0, 0]},
  getFlow: {type: "accessor", value: [0, 0, 0, 0]},
  getShape: {type: "accessor", value: [0, 0, 0, 0]},
  getStyle: {type: "accessor", value: [1, 1]},
  getPhase: {type: "accessor", value: [0, 1]},
  time: 0,
  animate: false,
  zoomDensity: 1,
  spreadScale: 1,
  alphaScale: 1,
  cyan: {type: "array", value: DEFAULT_CYAN, compare: true},
  magenta: {type: "array", value: DEFAULT_MAGENTA, compare: true},
}

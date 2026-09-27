import {Layer, project32} from "@deck.gl/core"
import {Geometry, Model} from "@luma.gl/engine"

// Animated packet flow along topology edges, drawn on WebGPU with one instance per edge.
//
// Each edge is a quad covering its tube. The particles on it are not data: the fragment shader
// works out which particles could cover the pixel from the edge's flow inputs, the time uniform
// and a hash of each particle's slot, and draws the soft core-and-glow dot for each. Particles
// on one lane are spaced in even strata (one per slot, placed randomly inside it) and share the
// lane's speed, so only the slots within one dot radius of the pixel can reach it.
//
// Zoomed out, hundreds of particles overlap on a short edge and their additive sum is what
// makes the bright band. The shader visits every slot in reach up to MAX_SLOTS_PER_LANE; past
// that it visits every n-th slot (the same ones for every pixel, so dots stay whole) and weights
// each by n, which keeps the band's brightness while bounding the per-pixel work.
//
// Nothing per particle exists on the CPU, animation only advances `time`, and the pipeline
// needs 5 vertex buffers (the quad plus four per-edge attributes) whatever the traffic.

export const MAX_PARTICLES_PER_LANE = 1400
export const MIN_PARTICLES_PER_LANE = 18
export const MAX_SLOTS_PER_LANE = 48

// The look, carried over number for number from the per-particle layer this replaced: dots
// 2-5 device pixels across and one in twenty-five a 6-9 pixel "head" (that layer's noise was
// quantized to hundredths, so "above 0.95" meant 4%); magenta for a share of dots that grows
// with the link's utilization, cyan for the rest; alpha never below 70/255.
export const PACKET_FLOW_STYLE = Object.freeze({
  particleSize: 2,
  headSize: 6,
  sizeRange: 3,
  headThreshold: 0.96,
  magentaBiasBase: 0.2,
  magentaBiasPerUtilization: 0.65,
  magentaBiasMin: 0.15,
  magentaBiasMax: 0.85,
  minAlpha: 70 / 255,
})
// Largest particle diameter in device pixels at size scale 1: a head with the largest seed.
export const MAX_PARTICLE_SIZE = PACKET_FLOW_STYLE.headSize + PACKET_FLOW_STYLE.sizeRange

/** Share of an edge's particles drawn magenta, for a utilization in 0..1. */
export function packetFlowMagentaBias(utilization) {
  const style = PACKET_FLOW_STYLE
  const bias = (utilization * style.magentaBiasPerUtilization) + style.magentaBiasBase
  return Math.max(style.magentaBiasMin, Math.min(style.magentaBiasMax, bias))
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

const MAX_PARTICLES_PER_LANE: f32 = ${MAX_PARTICLES_PER_LANE}.0;
const MIN_PARTICLES_PER_LANE: f32 = ${MIN_PARTICLES_PER_LANE}.0;
const MAX_PARTICLE_SIZE: f32 = ${wgslFloat(MAX_PARTICLE_SIZE)};
const MAX_SLOTS_PER_LANE: f32 = ${wgslFloat(MAX_SLOTS_PER_LANE)};
const PARTICLE_SIZE: f32 = ${wgslFloat(PACKET_FLOW_STYLE.particleSize)};
const HEAD_SIZE: f32 = ${wgslFloat(PACKET_FLOW_STYLE.headSize)};
const SIZE_RANGE: f32 = ${wgslFloat(PACKET_FLOW_STYLE.sizeRange)};
const HEAD_THRESHOLD: f32 = ${wgslFloat(PACKET_FLOW_STYLE.headThreshold)};
const MAGENTA_BIAS_BASE: f32 = ${wgslFloat(PACKET_FLOW_STYLE.magentaBiasBase)};
const MAGENTA_BIAS_PER_UTILIZATION: f32 = ${wgslFloat(PACKET_FLOW_STYLE.magentaBiasPerUtilization)};
const MAGENTA_BIAS_MIN: f32 = ${wgslFloat(PACKET_FLOW_STYLE.magentaBiasMin)};
const MAGENTA_BIAS_MAX: f32 = ${wgslFloat(PACKET_FLOW_STYLE.magentaBiasMax)};
const MIN_ALPHA: f32 = ${wgslFloat(PACKET_FLOW_STYLE.minAlpha)};

struct Attributes {
  // x: 0 at the source end, 1 at the target end; y: -1 / 1 across the tube.
  @location(0) positions: vec3<f32>,
  // source.xy, target.xy
  @location(1) instanceEndpoints: vec4<f32>,
  // particle count before zoom density, A->B weight, B->A weight, base speed
  @location(2) instanceFlow: vec4<f32>,
  // lane separation, jitter, utilization, edge seed
  @location(3) instanceShape: vec4<f32>,
  // alpha scale, size scale
  @location(4) instanceStyle: vec2<f32>,
};

struct Varyings {
  @builtin(position) position: vec4<f32>,
  // Along the edge, 0..1 from source to target.
  @location(0) along: f32,
  // Across the edge in world units, positive on the A->B lane's side.
  @location(1) across: f32,
  @location(2) @interpolate(flat) lengthPixels: f32,
  @location(3) @interpolate(flat) pixelsPerWorld: f32,
  // A->B particle count, B->A particle count, A->B speed, B->A speed
  @location(4) @interpolate(flat) lanes: vec4<f32>,
  @location(5) @interpolate(flat) shape: vec4<f32>,
  @location(6) @interpolate(flat) style: vec2<f32>,
};

fn packetFlowHash(n: f32) -> f32 {
  return fract(sin(n * 12.9898 + 78.233) * 43758.5453);
}

@vertex
fn vertexMain(attributes: Attributes) -> Varyings {
  var varyings: Varyings;
  let sourcePosition = attributes.instanceEndpoints.xy;
  let targetPosition = attributes.instanceEndpoints.zw;
  let flowInputs = attributes.instanceFlow;
  let shapeInputs = attributes.instanceShape;

  let total = clamp(floor(flowInputs.x * packetFlow.zoomDensity), MIN_PARTICLES_PER_LANE, MAX_PARTICLES_PER_LANE);
  let bidirectional = flowInputs.z > 0.0;
  let abCount = max(1.0, floor(total * max(select(0.05, 0.1, bidirectional), flowInputs.y)));
  let baCount = select(0.0, max(1.0, floor(total * max(0.1, flowInputs.z))), bidirectional);
  let totalWeight = max(0.0001, flowInputs.y + flowInputs.z);
  let abSpeed = clamp(flowInputs.w * (0.86 + ((flowInputs.y / totalWeight) * 0.24)), 0.02, 0.12);
  let baSpeed = clamp(flowInputs.w * (0.86 + ((flowInputs.z / totalWeight) * 0.24)), 0.02, 0.12);
  varyings.lanes = vec4<f32>(abCount, baCount, abSpeed, baSpeed);
  varyings.shape = shapeInputs;
  varyings.style = attributes.instanceStyle;

  // Pixel scale of the edge: project both ends and compare with the world length.
  let pixelsPerClip = project.viewportSize / (2.0 * project.devicePixelRatio);
  let sourceClip = project_position_to_clipspace(vec3<f32>(sourcePosition, 0.0), vec3<f32>(0.0), vec3<f32>(0.0));
  let targetClip = project_position_to_clipspace(vec3<f32>(targetPosition, 0.0), vec3<f32>(0.0), vec3<f32>(0.0));
  let lengthPixels = length((targetClip.xy / targetClip.w - sourceClip.xy / sourceClip.w) * pixelsPerClip);
  let worldLength = length(targetPosition - sourcePosition);
  let pixelsPerWorld = select(0.0, lengthPixels / worldLength, worldLength > 0.0);
  varyings.lengthPixels = lengthPixels;
  varyings.pixelsPerWorld = pixelsPerWorld;

  // Wide enough for both lanes, their jitter, and the largest dot plus a pixel.
  let laneExtent = shapeInputs.x + (shapeInputs.y * packetFlow.spreadScale);
  let dotRadiusPixels = max(1.0, MAX_PARTICLE_SIZE * attributes.instanceStyle.y) / (2.0 * project.devicePixelRatio);
  let halfWidth = laneExtent + (dotRadiusPixels + 1.0) / max(pixelsPerWorld, 1e-6);

  let direction = (targetPosition - sourcePosition) / max(worldLength, 1e-6);
  let normal = vec2<f32>(-direction.y, direction.x);
  let corner = mix(sourcePosition, targetPosition, attributes.positions.x) + normal * (attributes.positions.y * halfWidth);
  varyings.along = attributes.positions.x;
  varyings.across = attributes.positions.y * halfWidth;

  if (worldLength <= 0.0 || lengthPixels < 1.0) {
    // Nothing to draw along a zero-length or sub-pixel edge.
    varyings.position = vec4<f32>(0.0, 0.0, 0.0, 0.0);
  } else {
    varyings.position = project_position_to_clipspace(vec3<f32>(corner, 0.0), vec3<f32>(0.0), vec3<f32>(0.0));
  }
  return varyings;
}

struct Coverage {
  color: vec3<f32>,
  alpha: f32,
};

// Adds the particles of one lane that can cover this fragment.
fn laneCoverage(
  coverage: Coverage,
  along: f32,
  across: f32,
  count: f32,
  speed: f32,
  laneOffset: f32,
  side: f32,
  laneSalt: f32,
  shape: vec4<f32>,
  style: vec2<f32>,
  lengthPixels: f32,
  pixelsPerWorld: f32,
) -> Coverage {
  var result = coverage;
  if (count < 1.0) {
    return result;
  }
  let jitterScale = shape.y * packetFlow.spreadScale;
  let magentaBias = clamp((shape.z * MAGENTA_BIAS_PER_UTILIZATION) + MAGENTA_BIAS_BASE, MAGENTA_BIAS_MIN, MAGENTA_BIAS_MAX);
  let edgeSeed = shape.w * 997.0;
  let baseAlpha = clamp(style.x, MIN_ALPHA, 1.0) * packetFlow.alphaScale;
  // Slots whose particle can reach this fragment: those within the largest dot radius of it.
  let shift = fract(along - packetFlow.time * speed);
  let reachPixels = max(1.0, MAX_PARTICLE_SIZE * style.y) / (2.0 * project.devicePixelRatio);
  let reach = reachPixels / max(lengthPixels, 1e-3);
  let firstSlot = floor((shift - reach) * count);
  let lastSlot = floor((shift + reach) * count);
  let stride = max(1.0, ceil((lastSlot - firstSlot + 1.0) / MAX_SLOTS_PER_LANE));
  var candidate = ceil(firstSlot / stride) * stride;

  for (var visited = 0; visited < ${MAX_SLOTS_PER_LANE}; visited++) {
    if (candidate > lastSlot) {
      break;
    }
    let slot = ((candidate % count) + count) % count;
    candidate += stride;
    let key = edgeSeed * 1.37 + laneSalt + slot * 0.618;
    let placement = packetFlowHash(key) * 0.8;
    let progress = fract((slot + placement) / count + packetFlow.time * speed);
    let noise = packetFlowHash(key + 17.0);
    let seed = packetFlowHash(key + 31.0);
    let jitter = (packetFlowHash(key + 53.0) - 0.5) * 2.0 * jitterScale;
    let isHead = noise > HEAD_THRESHOLD;
    let sizeDevice = max(1.0, (select(PARTICLE_SIZE, HEAD_SIZE, isHead) + seed * SIZE_RANGE) * style.y);
    let diameter = sizeDevice / project.devicePixelRatio;

    let dx = (along - progress) * lengthPixels;
    let dy = (across - side * (laneOffset + jitter)) * pixelsPerWorld;
    let r = length(vec2<f32>(dx, dy)) / diameter;
    if (r > 0.5) {
      continue;
    }
    let core = 1.0 - smoothstep(0.0, 0.2, r);
    let glow = (1.0 - smoothstep(0.2, 0.5, r)) * 0.6;
    let fade = smoothstep(0.0, 0.18, progress) * (1.0 - smoothstep(0.82, 1.0, progress));
    let alpha = baseAlpha * (core + glow) * fade * stride;
    let tint = select(packetFlow.cyan.rgb, packetFlow.magenta.rgb, noise < magentaBias);
    result.color += tint * alpha;
    result.alpha += alpha;
  }
  return result;
}

@fragment
fn fragmentMain(varyings: Varyings) -> @location(0) vec4<f32> {
  var coverage = Coverage(vec3<f32>(0.0), 0.0);
  let laneOffset = select(0.0, varyings.shape.x, varyings.lanes.y > 0.0);
  // A->B runs source to target on the +normal side; B->A runs back on the other side.
  coverage = laneCoverage(coverage, varyings.along, varyings.across, varyings.lanes.x, varyings.lanes.z, laneOffset, 1.0, 0.0,
    varyings.shape, varyings.style, varyings.lengthPixels, varyings.pixelsPerWorld);
  coverage = laneCoverage(coverage, 1.0 - varyings.along, varyings.across, varyings.lanes.y, varyings.lanes.w, varyings.shape.x, -1.0, 7001.0,
    varyings.shape, varyings.style, varyings.lengthPixels, varyings.pixelsPerWorld);
  if (coverage.alpha <= 0.0) {
    discard;
  }
  // Already premultiplied: each dot added its color times its own alpha.
  return vec4<f32>(min(coverage.color, vec3<f32>(1.0)), min(coverage.alpha, 1.0));
}
`

// The edge tube as a triangle strip: x runs source (0) to target (1), y across it (-1..1).
const TUBE_CORNERS = new Float32Array([0, -1, 0, 1, -1, 0, 0, 1, 0, 1, 1, 0])

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
    return new Model(this.context.device, {
      ...this.getShaders(),
      id: this.props.id,
      bufferLayout: this.getAttributeManager().getBufferLayouts(),
      geometry: new Geometry({
        topology: "triangle-strip",
        attributes: {
          positions: {size: 3, value: TUBE_CORNERS},
        },
      }),
      isInstanced: true,
    })
  }

  draw(opts) {
    const {time, zoomDensity, spreadScale, alphaScale, cyan, magenta} = this.props
    this.state.model?.shaderInputs.setProps({
      packetFlow: {
        cyan: unitColor(cyan, DEFAULT_CYAN),
        magenta: unitColor(magenta, DEFAULT_MAGENTA),
        time: Number(time) || 0,
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
  time: 0,
  zoomDensity: 1,
  spreadScale: 1,
  alphaScale: 1,
  cyan: {type: "array", value: DEFAULT_CYAN, compare: true},
  magenta: {type: "array", value: DEFAULT_MAGENTA, compare: true},
}

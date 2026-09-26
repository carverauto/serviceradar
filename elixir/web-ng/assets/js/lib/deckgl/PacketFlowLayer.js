import {Layer, color, picking, project32} from "@deck.gl/core"
import {Geometry, Model} from "@luma.gl/engine"

// Animated packet particles along topology edges, drawn on WebGPU.
//
// Each particle is an instanced quad (a triangle strip of four corners in [-1, 1]) expanded in
// the vertex shader to `instanceSizes` device pixels -- the diameter the former point sprite
// had, since WebGPU has no point size. The fragment shader cuts the same soft round glow the
// sprite used: a solid core inside 0.2 of the radius and a fading halo out to the edge.

// Bound by name: the uniform variable below is `packetFlow`, matching the module name.
const packetFlowUniforms = {
  name: "packetFlow",
  source: "",
  uniformTypes: {
    time: "f32",
  },
}

export const PACKET_FLOW_WGSL = /* wgsl */ `\
struct PacketFlowUniforms {
  time: f32,
};

@group(0) @binding(0) var<uniform> packetFlow: PacketFlowUniforms;

struct Attributes {
  @builtin(instance_index) instanceIndex: u32,
  @location(0) positions: vec3<f32>,
  @location(1) instanceFrom: vec2<f32>,
  @location(2) instanceTo: vec2<f32>,
  @location(3) instanceSeeds: f32,
  @location(4) instanceSpeeds: f32,
  @location(5) instanceSizes: f32,
  @location(6) instanceJitters: f32,
  @location(7) instanceLaneOffsets: f32,
  @location(8) instanceColors: vec4<f32>,
};

struct Varyings {
  @builtin(position) position: vec4<f32>,
  @location(0) vColor: vec4<f32>,
  @location(1) unitPosition: vec2<f32>,
  @location(2) pickingColor: vec3<f32>,
};

fn packetFlowRand(co: vec2<f32>) -> f32 {
  return fract(sin(dot(co, vec2<f32>(12.9898, 78.233))) * 43758.5453);
}

@vertex
fn vertexMain(attributes: Attributes) -> Varyings {
  var varyings: Varyings;

  let progress = fract(attributes.instanceSeeds + (packetFlow.time * attributes.instanceSpeeds));
  var pos = mix(attributes.instanceFrom, attributes.instanceTo, progress);

  let dir = normalize(attributes.instanceTo - attributes.instanceFrom);
  let normal = vec2<f32>(-dir.y, dir.x);
  pos += normal * attributes.instanceLaneOffsets;

  let jitter = (packetFlowRand(vec2<f32>(attributes.instanceSeeds, attributes.instanceSeeds)) - 0.5) * 2.0;
  pos += normal * jitter * attributes.instanceJitters;

  var fragColor = attributes.instanceColors;
  // Fade particles out near both endpoints so node areas stay visually cleaner.
  let fadeIn = smoothstep(0.0, 0.18, progress);
  let fadeOut = 1.0 - smoothstep(0.82, 1.0, progress);
  fragColor.a *= fadeIn * fadeOut;
  varyings.vColor = fragColor;

  // instanceSizes is a diameter in device pixels; the offset helper takes CSS pixels.
  let radiusPixels = attributes.instanceSizes * 0.5 / project.devicePixelRatio;
  let center = project_position_to_clipspace(vec3<f32>(pos, 0.0), vec3<f32>(0.0), vec3<f32>(0.0));
  let corner = project_pixel_size_to_clipspace(attributes.positions.xy * radiusPixels);
  varyings.position = vec4<f32>(center.xy + corner, center.z, center.w);
  varyings.unitPosition = attributes.positions.xy;
  varyings.pickingColor = picking_getPickingColorFromIndex(attributes.instanceIndex);
  return varyings;
}

@fragment
fn fragmentMain(varyings: Varyings) -> @location(0) vec4<f32> {
  // Distance from the particle centre as a fraction of its diameter, as gl_PointCoord gave it.
  let dist = length(varyings.unitPosition) * 0.5;
  if (dist > 0.5) {
    discard;
  }

  if (picking.isActive > 0.5) {
    if (!picking_isColorValid(varyings.pickingColor)) {
      discard;
    }
    return vec4<f32>(varyings.pickingColor, 1.0);
  }

  let core = 1.0 - smoothstep(0.0, 0.2, dist);
  let glow = (1.0 - smoothstep(0.2, 0.5, dist)) * 0.6;
  let fragColor = vec4<f32>(varyings.vColor.rgb, varyings.vColor.a * (core + glow));
  return deckgl_premultiplied_alpha(fragColor);
}
`

// A unit square covering the particle, drawn as a triangle strip.
const QUAD_CORNERS = new Float32Array([-1, -1, 0, 1, -1, 0, -1, 1, 0, 1, 1, 0])

export default class PacketFlowLayer extends Layer {
  static get layerName() {
    return "PacketFlowLayer"
  }

  static get componentName() {
    return "PacketFlowLayer"
  }

  getShaders() {
    return super.getShaders({source: PACKET_FLOW_WGSL, modules: [project32, color, picking, packetFlowUniforms]})
  }

  initializeState() {
    const attributeManager = this.getAttributeManager()
    attributeManager.addInstanced({
      instanceFrom: {size: 2, accessor: "getFrom"},
      instanceTo: {size: 2, accessor: "getTo"},
      instanceSeeds: {size: 1, accessor: "getSeed"},
      instanceSpeeds: {size: 1, accessor: "getSpeed"},
      instanceSizes: {size: 1, accessor: "getSize"},
      instanceJitters: {size: 1, accessor: "getJitter"},
      instanceLaneOffsets: {size: 1, accessor: "getLaneOffset"},
      instanceColors: {size: 4, type: "unorm8", accessor: "getColor", defaultValue: [62, 207, 135, 80]},
    })
    this.state.model = this._getModel()
    this.getAttributeManager()?.invalidateAll?.()
  }

  updateState({props, oldProps, changeFlags}) {
    super.updateState({props, oldProps, changeFlags})
    if (changeFlags.extensionsChanged || !this.state.model) {
      this.state.model?.destroy()
      this.state.model = this._getModel()
      this.getAttributeManager()?.invalidateAll?.()
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
          positions: {size: 3, value: QUAD_CORNERS},
        },
      }),
      isInstanced: true,
    })
  }

  draw(opts) {
    const model = this.state.model
    if (model) {
      model.shaderInputs.setProps({packetFlow: {time: this.props.time || 0}})
    }
    super.draw(opts)
  }

  getBounds() {
    const data = this.props.data
    if (!Array.isArray(data) || data.length === 0) return null

    let minX = Number.POSITIVE_INFINITY
    let minY = Number.POSITIVE_INFINITY
    let maxX = Number.NEGATIVE_INFINITY
    let maxY = Number.NEGATIVE_INFINITY

    for (let i = 0; i < data.length; i += 1) {
      const from = this.props.getFrom(data[i], {index: i})
      const to = this.props.getTo(data[i], {index: i})
      if (Array.isArray(from)) {
        minX = Math.min(minX, Number(from[0] || 0))
        minY = Math.min(minY, Number(from[1] || 0))
        maxX = Math.max(maxX, Number(from[0] || 0))
        maxY = Math.max(maxY, Number(from[1] || 0))
      }
      if (Array.isArray(to)) {
        minX = Math.min(minX, Number(to[0] || 0))
        minY = Math.min(minY, Number(to[1] || 0))
        maxX = Math.max(maxX, Number(to[0] || 0))
        maxY = Math.max(maxY, Number(to[1] || 0))
      }
    }

    if (!Number.isFinite(minX) || !Number.isFinite(minY) || !Number.isFinite(maxX) || !Number.isFinite(maxY)) {
      return null
    }

    return [minX, minY, maxX, maxY]
  }

  finalizeState() {
    this.state.model?.destroy()
  }
}

PacketFlowLayer.defaultProps = {
  getFrom: {type: "accessor", value: (d) => (Array.isArray(d.from) ? d.from : [0, 0])},
  getTo: {type: "accessor", value: (d) => (Array.isArray(d.to) ? d.to : [0, 0])},
  getSeed: {type: "accessor", value: (d) => d.seed},
  getSpeed: {type: "accessor", value: (d) => d.speed},
  getSize: {type: "accessor", value: (d) => d.size},
  getJitter: {type: "accessor", value: (d) => d.jitter},
  getLaneOffset: {type: "accessor", value: (d) => d.laneOffset},
  getColor: {type: "accessor", value: (d) => (Array.isArray(d.color) ? d.color : [62, 207, 135, 80])},
  getPosition: {
    type: "accessor",
    value: (d) => (Array.isArray(d?.from) ? [d.from[0] || 0, d.from[1] || 0, 0] : [0, 0, 0]),
  },
  time: 0,
}

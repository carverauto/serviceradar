import {Layer, picking, project32} from "@deck.gl/core"
import {Geometry, Model} from "@luma.gl/engine"

const packetFlowVS = `\
#version 300 es
#define SHADER_NAME sr-packet-flow-layer-vs
in vec2 instanceFrom;
in vec2 instanceTo;
in float instanceSeeds;
in float instanceSpeeds;
in float instanceSizes;
in float instanceJitters;
in vec4 instanceColors;

uniform float u_time;

out vec4 vColor;

float rand(vec2 co) {
  return fract(sin(dot(co.xy, vec2(12.9898, 78.233))) * 43758.5453);
}

void main(void) {
  float progress = fract(instanceSeeds + (u_time * instanceSpeeds));
  float eased = pow(progress, 1.18);
  vec2 pos = mix(instanceFrom, instanceTo, eased);

  vec2 dir = normalize(instanceTo - instanceFrom);
  vec2 normal = vec2(-dir.y, dir.x);

  float offset = (rand(vec2(instanceSeeds, instanceSeeds)) - 0.5) * 2.0;
  pos += normal * offset * instanceJitters;

  // Colors are provided as 0-255 channel values from JS.
  float brightnessBoost = 1.0 + (sin(progress * 3.14159265) * 0.5);
  vColor = vec4((instanceColors.rgb / 255.0) * brightnessBoost, instanceColors.a / 255.0);
  float alphaFade = sin(progress * 3.14159265);
  vColor.a = clamp(vColor.a * alphaFade, 0.0, 1.0);
  gl_Position = project_position_to_clipspace(vec3(pos, 0.0), vec3(0.0), vec3(0.0));
  gl_PointSize = instanceSizes;
}
`

const packetFlowFS = `\
#version 300 es
#define SHADER_NAME sr-packet-flow-layer-fs
precision highp float;
in vec4 vColor;
out vec4 fragColor;

void main(void) {
  vec2 coord = gl_PointCoord - vec2(0.5);
  float dist = length(coord);
  if (dist > 0.5) {
    discard;
  }

  float glow = smoothstep(0.5, 0.0, dist);
  float core = smoothstep(0.15, 0.0, dist);
  float finalAlpha = vColor.a * (glow + (core * 2.0));
  fragColor = vec4(vColor.rgb, finalAlpha);
}
`

export default class PacketFlowLayer extends Layer {
  static get layerName() {
    return "PacketFlowLayer"
  }

  static get componentName() {
    return "PacketFlowLayer"
  }

  getShaders() {
    return super.getShaders({vs: packetFlowVS, fs: packetFlowFS, modules: [project32, picking]})
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
      instanceColors: {size: 4, accessor: "getColor"},
    })
    this.state.model = this._getModel()
    this.getAttributeManager()?.invalidateAll?.()
  }

  updateState({props, oldProps, changeFlags}) {
    super.updateState({props, oldProps, changeFlags})
    if (changeFlags.extensionsChanged || !this.state.model) {
      this.state.model?.delete?.()
      this.state.model = this._getModel()
      this.getAttributeManager()?.invalidateAll?.()
    }
  }

  _getModel() {
    return new Model(this.context.device, {
      ...this.getShaders(),
      geometry: new Geometry({
        topology: "point-list",
        attributes: {
          positions: {value: new Float32Array([0, 0, 0]), size: 3},
        },
      }),
      isInstanced: true,
    })
  }

  draw(opts) {
    const model = this.state.model
    if (!model) return
    model.setUniforms({
      u_time: Number(this.props.time || 0),
    })
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
    this.state.model?.delete?.()
  }
}

PacketFlowLayer.defaultProps = {
  getFrom: {type: "accessor", value: (d) => (Array.isArray(d.from) ? d.from : [0, 0])},
  getTo: {type: "accessor", value: (d) => (Array.isArray(d.to) ? d.to : [0, 0])},
  getSeed: {type: "accessor", value: (d) => d.seed},
  getSpeed: {type: "accessor", value: (d) => d.speed},
  getSize: {type: "accessor", value: (d) => d.size},
  getJitter: {type: "accessor", value: (d) => d.jitter},
  getColor: {type: "accessor", value: (d) => (Array.isArray(d.color) ? d.color : [56, 189, 248, 80])},
  getPosition: {
    type: "accessor",
    value: (d) => (Array.isArray(d?.from) ? [d.from[0] || 0, d.from[1] || 0, 0] : [0, 0, 0]),
  },
  time: 0,
}

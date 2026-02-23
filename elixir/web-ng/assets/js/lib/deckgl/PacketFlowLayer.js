import {Layer, picking, project32} from "@deck.gl/core"
import {Geometry, Model} from "@luma.gl/engine"

const packetFlowVS = `\
#define SHADER_NAME sr-packet-flow-layer-vs
attribute vec2 a_from;
attribute vec2 a_to;
attribute float a_seed;
attribute float a_speed;
attribute float a_size;
attribute float a_jitter;
attribute vec4 a_color;

uniform float u_time;

varying vec4 vColor;

float hash(float n) {
  return fract(sin(n) * 43758.5453123);
}

void main(void) {
  float t = fract((u_time * a_speed) + a_seed);
  float eased = pow(t, 1.18);
  vec2 base = mix(a_from, a_to, eased);

  vec2 dir = normalize(max(vec2(0.0001), a_to - a_from));
  vec2 normal = vec2(-dir.y, dir.x);

  float jitterSeed = hash(a_seed * 91.733);
  float spread = (jitterSeed - 0.5) * a_jitter;
  float wobble = sin(u_time * 7.5 + a_seed * 29.0) * (a_jitter * 0.28);

  vec2 pos = base + normal * (spread + wobble);

  vColor = a_color;
  float tailFade = 1.0 - smoothstep(0.82, 1.0, t);
  float headBoost = 0.74 + (1.0 - t) * 0.26;
  vColor.a = clamp(vColor.a * tailFade * headBoost, 0.0, 1.0);
  gl_Position = project_position_to_clipspace(vec3(pos, 0.0), vec3(0.0), vec3(0.0));
  gl_PointSize = a_size;
}
`

const packetFlowFS = `\
#define SHADER_NAME sr-packet-flow-layer-fs
precision highp float;
varying vec4 vColor;

void main(void) {
  vec2 p = gl_PointCoord * 2.0 - 1.0;
  float r = length(p);
  if (r > 1.0) {
    discard;
  }
  float glow = 1.0 - pow(r, 1.2);
  float alpha = glow * vColor.a;
  gl_FragColor = vec4(vColor.rgb, alpha);
}
`

export default class PacketFlowLayer extends Layer {
  getShaders() {
    return {vs: packetFlowVS, fs: packetFlowFS, modules: [project32, picking]}
  }

  initializeState() {
    const attributeManager = this.getAttributeManager()
    attributeManager.addInstanced({
      a_from: {size: 2, accessor: "getFrom"},
      a_to: {size: 2, accessor: "getTo"},
      a_seed: {size: 1, accessor: "getSeed"},
      a_speed: {size: 1, accessor: "getSpeed"},
      a_size: {size: 1, accessor: "getSize"},
      a_jitter: {size: 1, accessor: "getJitter"},
      a_color: {size: 4, type: 5121, normalized: true, accessor: "getColor"},
    })

    this.setState({
      model: this._getModel(),
    })
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

  draw({uniforms}) {
    const model = this.state.model
    if (!model) return
    model.setUniforms({
      ...uniforms,
      u_time: Number(this.props.time || 0),
    })
    model.draw()
  }

  finalizeState() {
    this.state.model?.delete?.()
  }
}

PacketFlowLayer.defaultProps = {
  getFrom: (d) => d.from,
  getTo: (d) => d.to,
  getSeed: (d) => d.seed,
  getSpeed: (d) => d.speed,
  getSize: (d) => d.size,
  getJitter: (d) => d.jitter,
  getColor: (d) => d.color,
  time: 0,
}

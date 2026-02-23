import {Deck, OrthographicView, picking, project32} from '@deck.gl/core';
import {LineLayer, ScatterplotLayer} from '@deck.gl/layers';
import {Geometry, Model} from '@luma.gl/engine';
import {Layer} from '@deck.gl/core';

const packetFlowUniformBlock = `\
uniform packetFlowUniforms {
  float time;
} packetFlow;
`;

const packetFlowUniformsModule = {
  name: "packetFlow",
  vs: packetFlowUniformBlock,
  fs: packetFlowUniformBlock,
  getUniforms: props => props,
  uniformTypes: {
    time: "f32",
  },
};

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

out vec4 vColor;

float rand(vec2 co) {
  return fract(sin(dot(co.xy, vec2(12.9898, 78.233))) * 43758.5453);
}

void main(void) {
  float progress = fract(instanceSeeds + (packetFlow.time * instanceSpeeds));
  float eased = pow(progress, 1.18);
  vec2 pos = mix(instanceFrom, instanceTo, eased);

  vec2 dir = normalize(instanceTo - instanceFrom);
  vec2 normal = vec2(-dir.y, dir.x);

  float offset = (rand(vec2(instanceSeeds, instanceSeeds)) - 0.5) * 2.0;
  pos += normal * offset * instanceJitters;

  float brightnessBoost = 1.0 + (sin(progress * 3.14159265) * 0.5);
  vColor = vec4((instanceColors.rgb / 255.0) * brightnessBoost, instanceColors.a / 255.0);
  float alphaFade = sin(progress * 3.14159265);
  vColor.a = clamp(vColor.a * alphaFade, 0.0, 1.0);
  gl_Position = project_position_to_clipspace(vec3(pos, 0.0), vec3(0.0), vec3(0.0));
  gl_PointSize = instanceSizes;
}
`;

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
`;

class PacketFlowLayer extends Layer {
  static get layerName() {
    return "PacketFlowLayer";
  }

  static get componentName() {
    return "PacketFlowLayer";
  }

  getShaders() {
    return super.getShaders({vs: packetFlowVS, fs: packetFlowFS, modules: [project32, picking, packetFlowUniformsModule]});
  }

  initializeState() {
    const attributeManager = this.getAttributeManager();
    attributeManager.addInstanced({
      instanceFrom: {size: 2, accessor: "getFrom"},
      instanceTo: {size: 2, accessor: "getTo"},
      instanceSeeds: {size: 1, accessor: "getSeed"},
      instanceSpeeds: {size: 1, accessor: "getSpeed"},
      instanceSizes: {size: 1, accessor: "getSize"},
      instanceJitters: {size: 1, accessor: "getJitter"},
      instanceColors: {size: 4, accessor: "getColor"},
    });
    this.state.model = this._getModel();
    this.getAttributeManager()?.invalidateAll?.();
  }

  updateState({props, oldProps, changeFlags}) {
    super.updateState({props, oldProps, changeFlags});
    if (changeFlags.extensionsChanged || !this.state.model) {
      this.state.model?.delete?.();
      this.state.model = this._getModel();
      this.getAttributeManager()?.invalidateAll?.();
    }
  }

  _getModel() {
    return new Model(this.context.device, {
      ...this.getShaders(),
      id: this.props.id,
      bufferLayout: this.getAttributeManager().getBufferLayouts(),
      geometry: new Geometry({
        topology: "point-list",
        attributes: {
          positions: {value: new Float32Array([0, 0, 0]), size: 3},
        },
      }),
      isInstanced: true,
    });
  }

  draw(opts) {
    if (this.state.model) {
      this.state.model.shaderInputs.setProps({
        packetFlow: {time: this.props.time || 0}
      });
    }
    super.draw(opts);
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
};

// --- DATA MOCK ---

const nodeData = [
  {id: 'node1', position: [100, 150]},
  {id: 'node2', position: [600, 250]}
];

const edgeData = [
  {sourceId: 'node1', targetId: 'node2', sourcePosition: [100, 150], targetPosition: [600, 250]}
];

// Generate 100 particles for the edge
const packetFlowData = Array.from({length: 100}).map((_, i) => ({
  from: [100, 150],
  to: [600, 250],
  seed: Math.random(),
  speed: 0.2 + Math.random() * 0.3,
  jitter: 20,
  size: 14 + Math.random() * 20,
  color: Math.random() > 0.5 ? [56, 248, 153, 255] : [56, 189, 248, 255] // Bright Green or Cyan
}));

// --- DECK.GL SETUP ---

// Need to create canvas in the body first.
document.querySelector('#app').innerHTML = `
  <canvas id="deck-canvas" style="width: 100vw; height: 100vh; position: absolute; top: 0; left: 0; background-color: #0f172a;"></canvas>
`;

const INITIAL_VIEW_STATE = {
  target: [350, 200, 0],
  zoom: 1,
  minZoom: -2,
  maxZoom: 5,
};

let time = 0;

const deck = new Deck({
  canvas: 'deck-canvas',
  initialViewState: INITIAL_VIEW_STATE,
  views: new OrthographicView({id: "god-view-ortho"}),
  controller: true,
  parameters: {
    clearColor: [20/255, 28/255, 42/255, 1.0], // bg color
    blend: true,
    blendFunc: [770, 771],
    depthTest: false,
    depthWrite: false,
  },
  layers: []
});

function render() {
  const nodes = new ScatterplotLayer({
    id: 'nodes',
    data: nodeData,
    getPosition: d => d.position,
    getFillColor: [248, 113, 113, 255],
    getRadius: 15,
    radiusUnits: 'pixels',
    pickable: true
  });

  const edges = new LineLayer({
    id: 'edges',
    data: edgeData,
    getSourcePosition: d => d.sourcePosition,
    getTargetPosition: d => d.targetPosition,
    getColor: [148, 163, 184, 180],
    getWidth: 12,
    widthUnits: 'pixels',
    pickable: true
  });

  const flow = new PacketFlowLayer({
    id: 'flow',
    data: packetFlowData,
    getFrom: d => d.from,
    getTo: d => d.to,
    getColor: d => d.color,
    getSize: d => d.size,
    getSpeed: d => d.speed,
    getSeed: d => d.seed,
    getJitter: d => d.jitter,
    time: time,
    parameters: {
      blend: true,
      blendFunc: [770, 1, 1, 1], // additive blending for glow
      depthTest: false,
      depthWrite: false,
    },
    updateTriggers: {
      // time is passed via shaderInputs, we don't need it here
    }
  });

  deck.setProps({
    layers: [edges, nodes, flow]
  });
}

function animate() {
  time += 0.01;
  render();
  requestAnimationFrame(animate);
}

animate();
import { Layer, project32, picking } from '@deck.gl/core';
import { Model, Geometry } from '@luma.gl/engine';

const splashUniformBlock = `
uniform splashUniforms {
  float time;
  vec2 resolution;
  float opacity;
} splash;
`;

const splashUniformsModule = {
  name: "splash",
  vs: splashUniformBlock,
  fs: splashUniformBlock,
  getUniforms: props => props,
  uniformTypes: {
    time: "f32",
    resolution: "vec2<f32>",
    opacity: "f32"
  },
};

const VS = `#version 300 es
in vec3 positions;
out vec2 v_pos;
void main(void) {
  v_pos = positions.xy;
  gl_Position = vec4(positions, 1.0);
}
`;

const FS = `#version 300 es
precision highp float;
in vec2 v_pos;
out vec4 fragColor;

float hash21(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

void main(void) {
  vec2 p = v_pos;
  p.x *= (splash.resolution.x / splash.resolution.y);
  float radius = length(p);
  float angle = atan(p.y, p.x);

  // High-contrast Neon Green
  vec3 brandColor = vec3(0.0, 1.0, 0.5);

  // Radar Sweep
  float sweep = fract((angle / 6.2831853) - splash.time * 0.5);
  float radarGlow = pow(sweep, 6.0) * smoothstep(1.5, 0.0, radius);
  float leadingEdge = smoothstep(0.97, 1.0, sweep) * 3.0;

  // Grid Nodes
  vec2 gridID = floor(p * 10.0);
  vec2 gridUV = fract(p * 10.0) - 0.5;
  float nodeHash = hash21(gridID);
  float nodeGlow = 0.0;
  if (nodeHash > 0.6) {
    float pulse = pow(sweep, 4.0) * 5.0 + 0.2;
    nodeGlow = smoothstep(0.15, 0.05, length(gridUV)) * pulse;
  }

  vec3 scan = brandColor * (radarGlow + nodeGlow + leadingEdge + 0.2);
  
  // Background
  vec3 bgColor = vec3(0.04, 0.06, 0.08);
  fragColor = vec4(mix(bgColor, scan + bgColor, 1.0), splash.opacity);
}
`;

export class RadarSplashLayer extends Layer {
  static get layerName() { return "RadarSplashLayer"; }

  getShaders() {
    return super.getShaders({
      vs: VS, 
      fs: FS, 
      modules: [project32, picking, splashUniformsModule]
    });
  }

  initializeState() {
    this.getAttributeManager().addInstanced({
      dummy: {size: 1, accessor: "getDummy"}
    });
    this.state.model = this._getModel();
  }

  _getModel() {
    return new Model(this.context.device, {
      ...this.getShaders(),
      id: this.props.id,
      geometry: new Geometry({
        topology: "triangle-strip",
        attributes: {
          positions: {value: new Float32Array([-1, -1, 0, 1, -1, 0, -1, 1, 0, 1, 1, 0]), size: 3}
        },
      }),
      vertexCount: 4
    });
  }

  draw(opts) {
    if (this.state.model) {
      const { viewport } = this.context;
      this.state.model.shaderInputs.setProps({
        splash: {
          time: this.props.time || 0,
          resolution: [viewport.width, viewport.height],
          opacity: this.props.opacity ?? 1.0
        }
      });
    }
    super.draw(opts);
  }
}

RadarSplashLayer.defaultProps = {
  time: 0,
  opacity: 1.0,
  getDummy: {type: 'accessor', value: 0}
};

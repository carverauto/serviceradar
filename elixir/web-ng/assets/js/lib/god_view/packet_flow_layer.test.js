import {AttributeManager, getShaderAssembler} from "@deck.gl/core"
import {describe, expect, it, vi} from "vitest"
import {WgslReflect} from "wgsl_reflect"

const engine = vi.hoisted(() => ({models: [], geometries: []}))
vi.mock("@luma.gl/engine", () => ({
  Model: class MockModel {
    constructor(device, props) {
      this.device = device
      this.props = props
      this.shaderInputs = {setProps: vi.fn()}
      engine.models.push(this)
    }
  },
  Geometry: class MockGeometry {
    constructor(props) {
      this.props = props
      engine.geometries.push(this)
    }
  },
}))

import PacketFlowLayer, {PACKET_FLOW_WGSL, packetFlowParticleBound} from "../deckgl/PacketFlowLayer"

// No GPU is available under vitest: these tests assemble and parse the layer's WGSL and inspect
// what it asks luma and deck for. They cannot show that it renders; the WebGPU acceptance run
// (SwiftShader) is what compiles and draws it.
function layerOnWebGPU(device = {type: "webgpu"}) {
  const layer = new PacketFlowLayer({id: "packets", data: {length: 0, attributes: {}}})
  layer.context = {defaultShaderModules: [], device}
  return layer
}

function assembledWGSL(layer) {
  // The assembler deck.gl itself hands luma for WGSL pipelines.
  return getShaderAssembler("wgsl").assembleWGSLShader({
    platformInfo: {type: "webgpu", shaderLanguage: "wgsl", shaderLanguageVersion: 100, gpu: "test", features: new Set()},
    ...layer.getShaders(),
  })
}

function initializedLayer() {
  const device = {type: "webgpu", createBuffer: vi.fn(() => ({destroy: vi.fn(), write: vi.fn()}))}
  const layer = layerOnWebGPU(device)
  layer.internalState = {attributeManager: new AttributeManager(device, {id: "packets"})}
  layer.state = {}
  engine.models.length = 0
  layer.initializeState()
  return {layer, model: engine.models[0]}
}

describe("PacketFlowLayer on WebGPU", () => {
  it("assembles WGSL that parses, with one instance per edge and no per-particle inputs", () => {
    const layer = layerOnWebGPU()
    const shaders = layer.getShaders()
    expect(shaders.vs).toBeUndefined()
    expect(shaders.fs).toBeUndefined()

    const assembled = assembledWGSL(layer)
    const reflected = new WgslReflect(assembled.source)

    expect(reflected.entry.vertex.map((entry) => entry.name)).toEqual(["vertexMain"])
    expect(reflected.entry.fragment.map((entry) => entry.name)).toEqual(["fragmentMain"])
    expect(assembled.shaderLayout.attributes.map((attribute) => attribute.name)).toEqual([
      "instanceEndpoints",
      "instanceFlow",
      "instanceShape",
      "instanceStyle",
    ])
    const uniforms = Object.fromEntries(reflected.uniforms.map((uniform) => [uniform.name, uniform.binding]))
    expect(Object.keys(uniforms).sort()).toEqual(["packetFlow", "project"])
  })

  it("needs at most 5 of the 8 vertex buffers every WebGPU device guarantees", () => {
    // A device only has to support 8 vertex buffers. The per-particle version of this layer
    // asked for 9 and every frame on a real GPU was rejected.
    const {layer, model} = initializedLayer()

    expect(model.props.geometry).toBeUndefined()
    expect(model.props.bufferLayout.length).toBeLessThanOrEqual(5)

    // Every attribute the shader reads is fed by exactly one of those buffers.
    const shaderInputs = assembledWGSL(layer).shaderLayout.attributes.map((attribute) => attribute.name)
    const fed = model.props.bufferLayout.flatMap((layout) => (layout.attributes || [layout]).map((entry) => entry.attribute || entry.name))
    expect(fed.sort()).toEqual([...shaderInputs].sort())
  })

  it("draws each edge as one instance of six numbered vertices per particle", () => {
    const {model} = initializedLayer()

    expect(model.props.isInstanced).toBe(true)
    expect(model.props.topology).toBe("triangle-list")
    expect(PACKET_FLOW_WGSL).toContain("@builtin(vertex_index) vertexIndex: u32")
  })

  it("issues enough particles per edge for the busiest edge at the current zoom", () => {
    const layer = layerOnWebGPU()
    layer.props = {...layer.props, data: {length: 3, attributes: {}, maxParticleBase: 900}, zoomDensity: 0.55}
    // floor(900 * 0.55) = 495 before the lane split; both lanes together stay under 1.1x that.
    expect(layer.vertexCount()).toBe(6 * packetFlowParticleBound(900, 0.55))
    expect(packetFlowParticleBound(900, 0.55)).toBeGreaterThanOrEqual(Math.ceil(495 * 1.1))
    // Clamped to the per-lane range like the shader.
    expect(packetFlowParticleBound(0, 1)).toBe(Math.ceil(18 * 1.1) + 2)
    expect(packetFlowParticleBound(1e9, 1)).toBe(Math.ceil(1400 * 1.1) + 2)
  })

  it("passes the clock and camera scales to the shader as uniforms", () => {
    const layer = layerOnWebGPU()
    const setProps = vi.fn()
    const draw = vi.fn()
    layer.props = {
      ...layer.props,
      time: 4.5,
      zoomDensity: 0.8,
      spreadScale: 1.2,
      alphaScale: 0.5,
      cyan: [255, 0, 0, 255],
      magenta: [0, 0, 255, 255],
    }
    const setVertexCount = vi.fn()
    layer.state = {model: {shaderInputs: {setProps}, draw, setVertexCount}}

    layer.draw({renderPass: "pass"})

    expect(setProps).toHaveBeenCalledWith({
      packetFlow: {
        cyan: [1, 0, 0, 1],
        magenta: [0, 0, 1, 1],
        time: 4.5,
        zoomDensity: 0.8,
        spreadScale: 1.2,
        alphaScale: 0.5,
      },
    })
    expect(draw).toHaveBeenCalledWith("pass")
    expect(setVertexCount).toHaveBeenCalledWith(layer.vertexCount())
  })
})

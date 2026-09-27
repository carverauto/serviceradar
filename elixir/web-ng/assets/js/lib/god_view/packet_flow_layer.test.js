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

import PacketFlowLayer from "../deckgl/PacketFlowLayer"

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
      "positions",
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

    const geometryBuffers = Object.keys(model.props.geometry.props.attributes).length
    const vertexBuffers = model.props.bufferLayout.length + geometryBuffers
    expect(vertexBuffers).toBeLessThanOrEqual(5)

    // Every attribute the shader reads is fed by exactly one of those buffers.
    const shaderInputs = assembledWGSL(layer).shaderLayout.attributes.map((attribute) => attribute.name)
    const fed = [
      ...Object.keys(model.props.geometry.props.attributes),
      ...model.props.bufferLayout.flatMap((layout) => (layout.attributes || [layout]).map((entry) => entry.attribute || entry.name)),
    ]
    expect(fed.sort()).toEqual([...shaderInputs].sort())
  })

  it("draws each edge as one instanced tube quad", () => {
    const {model} = initializedLayer()
    const geometry = model.props.geometry.props

    expect(model.props.isInstanced).toBe(true)
    expect(geometry.topology).toBe("triangle-strip")
    expect(Array.from(geometry.attributes.positions.value)).toEqual([0, -1, 0, 1, -1, 0, 0, 1, 0, 1, 1, 0])
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
    layer.state = {model: {shaderInputs: {setProps}, draw}}

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
  })
})

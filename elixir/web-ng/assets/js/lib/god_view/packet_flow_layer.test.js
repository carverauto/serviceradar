import {WGSLShaderAssembler} from "@luma.gl/shadertools"
import {describe, expect, it, vi} from "vitest"
import {WgslReflect} from "wgsl_reflect"

const engine = vi.hoisted(() => ({models: [], geometries: []}))
vi.mock("@luma.gl/engine", () => ({
  Model: class MockModel {
    constructor(device, props) {
      this.device = device
      this.props = props
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
// the model it asks luma for. They cannot show that it renders.
function layerOnWebGPU() {
  const layer = new PacketFlowLayer({id: "packets", data: []})
  layer.context = {defaultShaderModules: [], device: {type: "webgpu"}}
  return layer
}

function assembledWGSL(layer) {
  return new WGSLShaderAssembler().assembleWGSLShader({
    platformInfo: {type: "webgpu", shaderLanguage: "wgsl", shaderLanguageVersion: 100, gpu: "test", features: new Set()},
    ...layer.getShaders(),
  })
}

describe("PacketFlowLayer on WebGPU", () => {
  it("assembles WGSL that parses, with both entry points and every instance attribute", () => {
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
      "instanceFrom",
      "instanceTo",
      "instanceSeeds",
      "instanceSpeeds",
      "instanceSizes",
      "instanceJitters",
      "instanceLaneOffsets",
      "instanceColors",
    ])
    const uniforms = Object.fromEntries(reflected.uniforms.map((uniform) => [uniform.name, uniform.binding]))
    expect(Object.keys(uniforms).sort()).toEqual(["packetFlow", "picking", "project"])
    expect(new Set(Object.values(uniforms)).size).toBe(3)
  })

  it("draws each particle as an instanced four-corner triangle strip", () => {
    const layer = layerOnWebGPU()
    layer.internalState = {attributeManager: {getBufferLayouts: () => []}}

    const model = layer._getModel()
    const geometry = model.props.geometry.props

    expect(model.props.isInstanced).toBe(true)
    expect(geometry.topology).toBe("triangle-strip")
    expect(geometry.attributes.positions.size).toBe(3)
    expect(Array.from(geometry.attributes.positions.value)).toEqual([-1, -1, 0, 1, -1, 0, -1, 1, 0, 1, 1, 0])
    expect(model.props.source).toBe(layer.getShaders().source)
  })

  it("advances the animation clock through the packetFlow uniform", () => {
    const layer = layerOnWebGPU()
    const setProps = vi.fn()
    const draw = vi.fn()
    layer.props = {...layer.props, time: 4.5}
    layer.state = {model: {shaderInputs: {setProps}, draw}}

    layer.draw({renderPass: "pass"})

    expect(setProps).toHaveBeenCalledWith({packetFlow: {time: 4.5}})
    expect(draw).toHaveBeenCalledWith("pass")
  })
})

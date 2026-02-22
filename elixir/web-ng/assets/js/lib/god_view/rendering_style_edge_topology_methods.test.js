import {describe, expect, it} from "vitest"

import {godViewRenderingStyleEdgeTopologyMethods} from "./rendering_style_edge_topology_methods"

describe("rendering_style_edge_topology_methods", () => {
  it("edgeTopologyClassFromLabel maps inferred and endpoints labels", () => {
    expect(godViewRenderingStyleEdgeTopologyMethods.edgeTopologyClassFromLabel("LINK INFERRED path")).toEqual("inferred")
    expect(godViewRenderingStyleEdgeTopologyMethods.edgeTopologyClassFromLabel("LINK ENDPOINT attachment")).toEqual("endpoints")
    expect(godViewRenderingStyleEdgeTopologyMethods.edgeTopologyClassFromLabel("BACKBONE")).toEqual("backbone")
  })

  it("edgeTopologyClass honors explicit class before label fallback", () => {
    const methods = {...godViewRenderingStyleEdgeTopologyMethods}

    expect(methods.edgeTopologyClass({topologyClass: "inferred", label: "BACKBONE"})).toEqual("inferred")
    expect(methods.edgeTopologyClass({topologyClass: "", label: "LINK ENDPOINT attachment"})).toEqual("endpoints")
  })

  it("edgeEnabledByTopologyLayer uses class count map when present", () => {
    const methods = {
      ...godViewRenderingStyleEdgeTopologyMethods,
      topologyLayers: {backbone: false, inferred: true, endpoints: false},
    }

    const edge = {topologyClassCounts: {backbone: 2, inferred: 1, endpoints: 0}}
    expect(methods.edgeEnabledByTopologyLayer(edge)).toEqual(true)

    methods.topologyLayers = {backbone: false, inferred: false, endpoints: false}
    expect(methods.edgeEnabledByTopologyLayer(edge)).toEqual(false)
  })

  it("edgeEnabledByTopologyLayer falls back to inferred/endpoints/backbone classes", () => {
    const methods = {
      ...godViewRenderingStyleEdgeTopologyMethods,
      topologyLayers: {backbone: true, inferred: false, endpoints: false},
    }

    expect(methods.edgeEnabledByTopologyLayer({label: "LINK INFERRED path"})).toEqual(false)
    expect(methods.edgeEnabledByTopologyLayer({label: "LINK ENDPOINT attach"})).toEqual(false)
    expect(methods.edgeEnabledByTopologyLayer({label: "BACKBONE"})).toEqual(true)
  })
})

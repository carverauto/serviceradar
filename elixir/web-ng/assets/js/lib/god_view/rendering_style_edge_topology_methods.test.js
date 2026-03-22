import {describe, expect, it} from "vitest"

import {bindApi, createStateBackedContext} from "./api_helpers"
import {godViewRenderingStyleEdgeTopologyMethods} from "./rendering_style_edge_topology_methods"

describe("rendering_style_edge_topology_methods", () => {
  it("edgeTopologyClass honors explicit class and does not infer from label", () => {
    const state = {}
    const methods = createStateBackedContext(state, {})
    Object.assign(methods, bindApi(methods, godViewRenderingStyleEdgeTopologyMethods))

    expect(methods.edgeTopologyClass({topologyClass: "inferred", label: "BACKBONE"})).toEqual("inferred")
    expect(methods.edgeTopologyClass({topologyClass: "endpoint"})).toEqual("endpoints")
    expect(methods.edgeTopologyClass({topologyClass: "", label: "LINK ENDPOINT attachment"})).toEqual("unknown")
  })

  it("edgeEnabledByTopologyLayer uses class count map when present", () => {
    const state = {topologyLayers: {backbone: false, inferred: true, endpoints: false}}
    const methods = createStateBackedContext(state, {})
    Object.assign(methods, bindApi(methods, godViewRenderingStyleEdgeTopologyMethods))

    const edge = {topologyClassCounts: {backbone: 2, inferred: 1, endpoints: 0, unknown: 1}}
    expect(methods.edgeEnabledByTopologyLayer(edge)).toEqual(true)

    methods.state.topologyLayers = {backbone: false, inferred: false, endpoints: false}
    expect(methods.edgeEnabledByTopologyLayer(edge)).toEqual(false)
  })

  it("edgeEnabledByTopologyLayer uses explicit class only when class counts absent", () => {
    const state = {topologyLayers: {backbone: true, inferred: false, endpoints: false}}
    const methods = createStateBackedContext(state, {})
    Object.assign(methods, bindApi(methods, godViewRenderingStyleEdgeTopologyMethods))

    expect(methods.edgeEnabledByTopologyLayer({topologyClass: "inferred"})).toEqual(false)
    expect(methods.edgeEnabledByTopologyLayer({topologyClass: "endpoints"})).toEqual(false)
    expect(methods.edgeEnabledByTopologyLayer({topologyClass: "backbone"})).toEqual(true)
    expect(methods.edgeEnabledByTopologyLayer({label: "LINK INFERRED path"})).toEqual(true)

    methods.state.topologyLayers.backbone = false
    expect(methods.edgeEnabledByTopologyLayer({label: "unclassified"})).toEqual(false)
  })

  it("edgeTopologyClass falls back to dominant class counts when explicit class is unknown", () => {
    const state = {}
    const methods = createStateBackedContext(state, {})
    Object.assign(methods, bindApi(methods, godViewRenderingStyleEdgeTopologyMethods))

    expect(
      methods.edgeTopologyClass({
        topologyClass: "unknown",
        topologyClassCounts: {backbone: 0, inferred: 0, endpoints: 3, unknown: 1},
      }),
    ).toEqual("endpoints")
  })

  it("edgeTopologyVisualStyle softens endpoint attachments relative to backbone", () => {
    const state = {}
    const methods = createStateBackedContext(state, {})
    Object.assign(methods, bindApi(methods, godViewRenderingStyleEdgeTopologyMethods))

    const backbone = methods.edgeTopologyVisualStyle({topologyClass: "backbone"})
    const endpoints = methods.edgeTopologyVisualStyle({topologyClass: "endpoints"})

    expect(endpoints.mantleWidthScale).toBeLessThan(backbone.mantleWidthScale)
    expect(endpoints.crustAlphaScale).toBeLessThan(backbone.crustAlphaScale)
    expect(endpoints.particleDensityScale).toBeLessThan(backbone.particleDensityScale)
  })
})

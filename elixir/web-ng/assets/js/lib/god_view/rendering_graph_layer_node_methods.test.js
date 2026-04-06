import {describe, expect, it} from "vitest"

import {bindApi, createStateBackedContext} from "./api_helpers"
import {godViewRenderingGraphLayerNodeMethods} from "./rendering_graph_layer_node_methods"

describe("rendering_graph_layer_node_methods", () => {
  it("buildNodeAndLabelLayers makes node labels pickable", () => {
    const state = {
      animationPhase: 0,
      layers: {mantle: true, crust: true, atmosphere: true, security: true},
      visual: {label: [255, 255, 255, 255], edgeLabel: [200, 200, 200, 255]},
    }

    const ctx = createStateBackedContext(state, {})
    Object.assign(ctx, bindApi(ctx, godViewRenderingGraphLayerNodeMethods), {
      nodeColor: () => [255, 0, 0, 255],
      nodeNeutralColor: () => [128, 128, 128, 255],
      connectionKindFromLabel: () => "LINK",
    })

    const layers = ctx.buildNodeAndLabelLayers(
      {shape: "local"},
      [{index: 0, id: "sr:test", label: "test", position: [0, 0, 0], state: 2, operUp: 1, clusterCount: 1}],
      [],
    )

    const labelLayer = layers.find((layer) => layer.id === "god-view-node-labels")
    expect(labelLayer).toBeTruthy()
    expect(labelLayer.props.pickable).toEqual(true)
  })

  it("selectNodeLabels suppresses endpoint-member and topology-sighting labels under budget pressure", () => {
    const state = {
      animationPhase: 0,
      layers: {mantle: true, crust: true, atmosphere: true, security: true},
      visual: {label: [255, 255, 255, 255], edgeLabel: [200, 200, 200, 255]},
    }

    const ctx = createStateBackedContext(state, {})
    Object.assign(ctx, bindApi(ctx, godViewRenderingGraphLayerNodeMethods))

    const labels = ctx.selectNodeLabels([
      {id: "summary", label: "20 endpoints", clusterCount: 20, pps: 10, state: 3, selected: false, details: {cluster_kind: "endpoint-summary"}},
      {id: "switch", label: "Switch", clusterCount: 1, pps: 1000, state: 2, selected: false, details: {}},
      {id: "endpoint-1", label: "192.0.2.10", clusterCount: 1, pps: 0, state: 2, selected: false, details: {cluster_kind: "endpoint-member"}},
      {id: "ghost", label: "192.0.2.11", clusterCount: 1, pps: 0, state: 3, selected: false, details: {identity_source: "mapper_topology_sighting"}},
      {id: "selected-endpoint", label: "Laptop", clusterCount: 1, pps: 0, state: 2, selected: true, details: {cluster_kind: "endpoint-member"}},
    ], "local")

    expect(labels.map((node) => node.id)).toEqual(["selected-endpoint", "summary", "switch"])
  })

  it("selectNodeLabels enforces a per-shape budget", () => {
    const state = {
      animationPhase: 0,
      layers: {mantle: true, crust: true, atmosphere: true, security: true},
      visual: {label: [255, 255, 255, 255], edgeLabel: [200, 200, 200, 255]},
    }

    const ctx = createStateBackedContext(state, {})
    Object.assign(ctx, bindApi(ctx, godViewRenderingGraphLayerNodeMethods))

    const labels = ctx.selectNodeLabels(
      Array.from({length: 24}, (_, index) => ({
        id: `node-${index}`,
        label: `Node ${index}`,
        clusterCount: 1,
        pps: 24 - index,
        state: 2,
        selected: false,
        details: {},
      })),
      "global",
    )

    expect(labels).toHaveLength(10)
    expect(labels[0].id).toEqual("node-0")
  })
})

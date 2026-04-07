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
      {id: "summary-2", label: "16 endpoints", clusterCount: 16, pps: 9, state: 3, selected: false, details: {cluster_kind: "endpoint-summary"}},
      {id: "summary-3", label: "8 endpoints", clusterCount: 8, pps: 8, state: 3, selected: false, details: {cluster_kind: "endpoint-summary"}},
      {id: "switch", label: "Switch", clusterCount: 1, pps: 1000, state: 2, selected: false, details: {}},
      {id: "endpoint-1", label: "192.0.2.10", clusterCount: 1, pps: 0, state: 2, selected: false, details: {cluster_kind: "endpoint-member"}},
      {id: "ghost", label: "192.0.2.11", clusterCount: 1, pps: 0, state: 3, selected: false, details: {identity_source: "mapper_topology_sighting"}},
      {id: "sr:a0", label: "sr:a0", clusterCount: 1, pps: 100, state: 2, selected: false, details: {}},
      {id: "selected-endpoint", label: "Laptop", clusterCount: 1, pps: 0, state: 2, selected: true, details: {cluster_kind: "endpoint-member"}},
    ], "local")

    expect(labels.map((node) => node.id)).toEqual(["selected-endpoint", "switch", "summary", "summary-2", "summary-3"])
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

    expect(labels).toHaveLength(8)
    expect(labels[0].id).toEqual("node-0")
  })

  it("selectNodeLabels still preserves explicitly selected opaque identities", () => {
    const state = {
      animationPhase: 0,
      layers: {mantle: true, crust: true, atmosphere: true, security: true},
      visual: {label: [255, 255, 255, 255], edgeLabel: [200, 200, 200, 255]},
    }

    const ctx = createStateBackedContext(state, {})
    Object.assign(ctx, bindApi(ctx, godViewRenderingGraphLayerNodeMethods))

    const labels = ctx.selectNodeLabels([
      {id: "sr:hidden", label: "sr:hidden", clusterCount: 1, pps: 0, state: 3, selected: false, details: {}},
      {id: "sr:selected", label: "sr:selected", clusterCount: 1, pps: 0, state: 3, selected: true, details: {}},
      {id: "router", label: "Router", clusterCount: 1, pps: 100, state: 2, selected: false, details: {}},
    ], "local")

    expect(labels.map((node) => node.id)).toEqual(["sr:selected", "router"])
  })

  it("selectNodeLabels reserves budget for backbone labels before endpoint summaries", () => {
    const state = {
      animationPhase: 0,
      layers: {mantle: true, crust: true, atmosphere: true, security: true},
      visual: {label: [255, 255, 255, 255], edgeLabel: [200, 200, 200, 255]},
    }

    const ctx = createStateBackedContext(state, {})
    Object.assign(ctx, bindApi(ctx, godViewRenderingGraphLayerNodeMethods))

    const labels = ctx.selectNodeLabels([
      {id: "summary", label: "20 endpoints", clusterCount: 20, pps: 10, state: 3, selected: false, details: {cluster_kind: "endpoint-summary"}},
      {id: "summary-2", label: "10 endpoints", clusterCount: 10, pps: 9, state: 3, selected: false, details: {cluster_kind: "endpoint-summary"}},
      {id: "router-a", label: "Router A", clusterCount: 1, pps: 200, state: 2, selected: false, details: {}},
      {id: "switch-b", label: "Switch B", clusterCount: 1, pps: 180, state: 2, selected: false, details: {}},
      {id: "ap-c", label: "AP C", clusterCount: 1, pps: 160, state: 2, selected: false, details: {cluster_kind: "endpoint-anchor"}},
    ], "local")

    expect(labels.map((node) => node.id).slice(0, 3).sort()).toEqual(["ap-c", "router-a", "switch-b"])
  })

  it("selectNodeLabels includes expanded endpoint-member labels with a bounded budget", () => {
    const state = {
      animationPhase: 0,
      layers: {mantle: true, crust: true, atmosphere: true, security: true},
      visual: {label: [255, 255, 255, 255], edgeLabel: [200, 200, 200, 255]},
    }

    const ctx = createStateBackedContext(state, {})
    Object.assign(ctx, bindApi(ctx, godViewRenderingGraphLayerNodeMethods))

    const labels = ctx.selectNodeLabels([
      {id: "router-a", label: "Router A", clusterCount: 1, pps: 200, state: 2, selected: false, details: {}},
      ...Array.from({length: 8}, (_, index) => ({
        id: `endpoint-${index + 1}`,
        label: `192.0.2.${index + 1}`,
        clusterCount: 1,
        pps: 20 - index,
        state: 2,
        selected: false,
        details: {
          cluster_kind: "endpoint-member",
          cluster_expanded: true,
          identity_source: "mapper_topology_sighting",
        },
      })),
    ], "local")

    expect(labels.map((node) => node.id)).toEqual([
      "router-a",
      "endpoint-1",
      "endpoint-2",
      "endpoint-3",
      "endpoint-4",
      "endpoint-5",
      "endpoint-6",
      "endpoint-7",
      "endpoint-8",
    ])
  })
})

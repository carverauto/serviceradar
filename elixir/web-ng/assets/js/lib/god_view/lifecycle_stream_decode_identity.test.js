import ELK from "elkjs/lib/elk.bundled.js"
import {tableFromArrays, tableToIPC} from "apache-arrow"
import {describe, expect, it, vi} from "vitest"

import {bindApi, createStateBackedContext} from "./api_helpers"
import {godViewLayoutTopologyStateMethods} from "./layout_topology_state_methods"
import {godViewLifecycleStreamDecodeMethods} from "./lifecycle_stream_decode_methods"
import {godViewRenderingGraphDataMethods} from "./rendering_graph_data_methods"
import {godViewRenderingStyleEdgeTopologyMethods} from "./rendering_style_edge_topology_methods"
import {prepareTopologySceneInput} from "./topology_scene_graph"

const RELATIONS = [
  {
    source: 0,
    target: 1,
    flowPps: 100,
    topologyClass: "backbone",
    protocol: "snmp",
    evidenceClass: "direct",
    label: "uplink",
    sourceIfIndex: 10,
    sourceInterface: "xe-0/0/0",
    targetIfIndex: 20,
    targetInterface: "xe-0/0/1",
  },
  {
    source: 1,
    target: 0,
    flowPps: 50,
    topologyClass: "backbone",
    protocol: "snmp",
    evidenceClass: "direct",
    label: "uplink",
    sourceIfIndex: 20,
    sourceInterface: "xe-0/0/1",
    targetIfIndex: 10,
    targetInterface: "xe-0/0/0",
  },
  {
    source: 0,
    target: 1,
    flowPps: 7,
    topologyClass: "inferred",
    protocol: "snmp",
    evidenceClass: "inferred",
    label: "uplink",
    sourceIfIndex: 11,
    sourceInterface: "xe-0/0/2",
    targetIfIndex: 21,
    targetInterface: "xe-0/0/3",
  },
  {
    source: 0,
    target: 1,
    flowPps: 30,
    topologyClass: "backbone",
    protocol: "snmp",
    evidenceClass: "direct",
    label: "uplink",
    sourceIfIndex: 10,
    sourceInterface: "xe-0/0/0",
    targetIfIndex: 20,
    targetInterface: "xe-0/0/1",
  },
]

const DUPLICATE_RELATIONS = [
  {
    source: 0,
    target: 1,
    flowPps: 100,
    flowBps: 1_000_000,
    capacityBps: 1_000_000_000,
    topologyClass: "backbone",
    protocol: "snmp",
    evidenceClass: "direct",
    label: "SNMP BACKBONE 100pps / 1G",
    sourceIfIndex: 10,
    sourceInterface: "xe-0/0/0",
    targetIfIndex: 20,
    targetInterface: "xe-0/0/1",
    details: {
      telemetry_source: "interface-old",
      telemetry_observed_at: "2026-08-24T01:00:00Z",
      tie_breaker: "old",
      interface_sparkline_label: "Older interface history",
      interface_sparkline: [{bucket: "00:55", value: 10}, {bucket: "01:00", value: 20}],
    },
  },
  {
    source: 0,
    target: 1,
    flowPps: 200,
    flowBps: 2_000_000,
    capacityBps: 2_000_000_000,
    topologyClass: "backbone",
    protocol: "snmp",
    evidenceClass: "direct",
    label: "SNMP BACKBONE 200pps / 2G",
    sourceIfIndex: 10,
    sourceInterface: "xe-0/0/0",
    targetIfIndex: 20,
    targetInterface: "xe-0/0/1",
    details: {
      telemetry_source: "interface-b",
      telemetry_observed_at: "2026-08-24T02:00:00Z",
      tie_breaker: "sparkline-source",
      interface_sparkline_label: "Current interface history",
      interface_sparkline: [{bucket: "01:55", value: 30}, {bucket: "02:00", value: 40}],
    },
  },
  {
    source: 0,
    target: 1,
    flowPps: 300,
    flowBps: 3_000_000,
    capacityBps: 3_000_000_000,
    topologyClass: "backbone",
    protocol: "snmp",
    evidenceClass: "direct",
    label: "SNMP BACKBONE 300pps / 3G",
    sourceIfIndex: 10,
    sourceInterface: "xe-0/0/0",
    targetIfIndex: 20,
    targetInterface: "xe-0/0/1",
    details: {
      telemetry_source: "interface-a",
      telemetry_observed_at: "2026-08-24T02:00:00Z",
      tie_breaker: "z",
    },
  },
  {
    source: 0,
    target: 1,
    flowPps: 400,
    flowBps: 4_000_000,
    capacityBps: 4_000_000_000,
    topologyClass: "backbone",
    protocol: "snmp",
    evidenceClass: "direct",
    label: "SNMP BACKBONE 400pps / 4G",
    sourceIfIndex: 10,
    sourceInterface: "xe-0/0/0",
    targetIfIndex: 20,
    targetInterface: "xe-0/0/1",
    details: {
      telemetry_source: "interface-a",
      telemetry_observed_at: "2026-08-24T02:00:00Z",
      tie_breaker: "a",
    },
  },
]

function arrowBytes(edgeOrder, sourceRelations = RELATIONS) {
  const relations = edgeOrder.map((index) => sourceRelations[index])
  const nodeRows = [
    {id: "a", label: "A"},
    {id: "b", label: "B"},
  ]
  const totalRows = nodeRows.length + relations.length
  const nodeValues = (field) => [nodeRows[0][field], nodeRows[1][field], ...relations.map(() => null)]
  const edgeValues = (field) => [null, null, ...relations.map((relation) => relation[field])]
  const details = relations.map((relation) => JSON.stringify({
    source_id: nodeRows[relation.source].id,
    target_id: nodeRows[relation.target].id,
    source_if_index: relation.sourceIfIndex,
    source_interface: relation.sourceInterface,
    target_if_index: relation.targetIfIndex,
    target_interface: relation.targetInterface,
    ...(relation.details || {}),
    metadata: {relation_type: "CONNECTED_TO", topology_plane: "physical"},
  }))

  const table = tableFromArrays({
    row_type: Int8Array.from([0, 0, ...relations.map(() => 1)]),
    node_x: Float64Array.from([0, 100, ...relations.map(() => 0)]),
    node_y: Float64Array.from({length: totalRows}, () => 0),
    node_state: Int8Array.from([1, 1, ...relations.map(() => 0)]),
    node_label: nodeValues("label"),
    node_pps: Float64Array.from({length: totalRows}, () => 0),
    node_oper_up: Int8Array.from([1, 1, ...relations.map(() => 0)]),
    node_details: [JSON.stringify({id: "a", type: "Router"}), JSON.stringify({id: "b", type: "Switch"}), ...relations.map(() => null)],
    edge_source: edgeValues("source"),
    edge_target: edgeValues("target"),
    edge_pps: edgeValues("flowPps"),
    edge_flow_bps: edgeValues("flowBps"),
    edge_capacity_bps: edgeValues("capacityBps"),
    edge_telemetry_eligible: edgeValues("source").map((value) => value == null ? null : 1),
    edge_label: edgeValues("label"),
    edge_topology_class: edgeValues("topologyClass"),
    edge_protocol: edgeValues("protocol"),
    edge_evidence_class: edgeValues("evidenceClass"),
    edge_details: [null, null, ...details],
  })
  return tableToIPC(table, "stream")
}

function decode(bytes) {
  const state = {}
  const deps = {
    normalizeDisplayLabel: (value, fallback) =>
      typeof value === "string" && value.trim() !== "" ? value : fallback,
  }
  const runtime = createStateBackedContext(state, deps)
  Object.assign(runtime, bindApi(runtime, godViewLifecycleStreamDecodeMethods))
  return runtime.decodeArrowGraph(bytes)
}

function dedupe(graph) {
  return godViewLayoutTopologyStateMethods.dedupeGraphById.call({state: {}}, graph)
}

function layoutContext() {
  const engine = new ELK()
  return {
    state: {
      layoutMode: "auto",
      layoutRevision: null,
      layoutCache: new Map(),
      lastLayoutKey: null,
      layoutEngine: {layout: vi.fn((graph) => engine.layout(graph))},
      lastGraph: null,
      viewportWidth: 1920,
      viewportHeight: 1080,
      viewportSafeInsets: {top: 0, right: 0, bottom: 0, left: 0},
    },
    ...godViewLayoutTopologyStateMethods,
  }
}

function renderingContext(topologyLayers) {
  const runtime = createStateBackedContext({
    selectedNodeIndex: null,
    hoveredEdgeKey: null,
    selectedEdgeKey: null,
    topologyLayers,
  }, {})
  Object.assign(runtime, bindApi(runtime, godViewRenderingGraphDataMethods))
  Object.assign(runtime, godViewRenderingStyleEdgeTopologyMethods, {
    visibilityMask: (states) => new Uint8Array(states.length).fill(1),
    selectEdgeLabels: () => [],
    connectionKindFromLabel: () => "LINK",
    normalizeDisplayLabel: (value, fallback) => String(value || "").trim() || fallback,
    nodeMetricText: () => "",
    nodeStatusIcon: () => "",
    stateReasonForNode: () => "",
  })
  return runtime
}

function effectiveGraph(graph, sceneInput) {
  const relation = sceneInput.renderedRelations[0]
  return {
    ...graph,
    shape: "local",
    _layoutMode: "elk-scene",
    _topologyScene: {
      routes: [{...relation, points: [{x: 0, y: 0}, {x: 100, y: 0}], metadata: {flowPps: 999_999}}],
    },
  }
}

describe("Arrow relation identity integration", () => {
  it("reuses structural geometry when only the server-formatted rate label changes", async () => {
    const snapshots = [
      {
        source: 0,
        target: 1,
        flowPps: 100,
        flowBps: 1_000_000,
        capacityBps: 1_000_000_000,
        topologyClass: "backbone",
        protocol: "snmp",
        evidenceClass: "direct",
        label: "SNMP BACKBONE 100pps / 1G",
        sourceIfIndex: 10,
        sourceInterface: "xe-0/0/0",
        targetIfIndex: 20,
        targetInterface: "xe-0/0/1",
        details: {telemetry_source: "interface", telemetry_observed_at: "2026-08-24T01:00:00Z"},
      },
      {
        source: 0,
        target: 1,
        flowPps: 1_200,
        flowBps: 8_000_000,
        capacityBps: 10_000_000_000,
        topologyClass: "backbone",
        protocol: "snmp",
        evidenceClass: "direct",
        label: "SNMP BACKBONE 1.2Kpps / 10G",
        sourceIfIndex: 10,
        sourceInterface: "xe-0/0/0",
        targetIfIndex: 20,
        targetInterface: "xe-0/0/1",
        details: {telemetry_source: "interface", telemetry_observed_at: "2026-08-24T01:01:00Z"},
      },
    ]
    const firstGraph = decode(arrowBytes([0], [snapshots[0]]))
    const currentGraph = decode(arrowBytes([0], [snapshots[1]]))
    const firstInput = prepareTopologySceneInput(dedupe(firstGraph))
    const currentInput = prepareTopologySceneInput(dedupe(currentGraph))
    const context = layoutContext()

    expect(currentGraph.edges[0].id).toEqual(firstGraph.edges[0].id)
    expect(currentInput.graphKey).toEqual(firstInput.graphKey)

    const first = await context.prepareGraphLayout(firstGraph, 1, "rate:100")
    const current = await context.prepareGraphLayout(currentGraph, 2, "rate:1200")
    const rendered = renderingContext({backbone: true, inferred: false, endpoints: false})
      .buildVisibleGraphData({shape: "local", ...current})

    expect(context.state.layoutEngine.layout).toHaveBeenCalledTimes(1)
    expect(current._layoutCacheKey).toEqual(first._layoutCacheKey)
    expect(current._topologyScene).not.toBe(first._topologyScene)
    expect(current.edges[0]).toMatchObject({
      label: "SNMP BACKBONE 1.2Kpps / 10G",
      flowPps: 1_200,
      flowBps: 8_000_000,
      capacityBps: 10_000_000_000,
      details: expect.objectContaining({telemetry_observed_at: "2026-08-24T01:01:00Z"}),
    })
    expect(rendered.edgeData[0]).toMatchObject({
      label: "SNMP BACKBONE 1.2Kpps / 10G",
      flowPps: 1_200,
      flowBps: 8_000_000,
      capacityBps: 10_000_000_000,
      details: expect.objectContaining({telemetry_observed_at: "2026-08-24T01:01:00Z"}),
    })
  })

  it("preserves parallel and reverse identities and aggregates every exact duplicate deterministically", () => {
    const decodedForward = decode(arrowBytes([0, 1, 2, 3]))
    const decodedShuffled = decode(arrowBytes([3, 2, 1, 0]))
    expect(decodedForward.edges.every((edge) => typeof edge.id === "string" && edge.id.startsWith("semantic:"))).toEqual(true)
    expect(new Set(decodedForward.edges.map((edge) => edge.id)).size).toEqual(3)

    const forward = dedupe(decodedForward)
    const shuffled = dedupe(decodedShuffled)
    const forwardScene = prepareTopologySceneInput(forward)
    const shuffledScene = prepareTopologySceneInput(shuffled)

    expect(forward.edges).toHaveLength(4)
    expect(new Set(forward.edges.map((edge) => edge.id)).size).toEqual(3)
    expect(forwardScene.manifest).toMatchObject({semanticEdges: 4, renderedRoutes: 1})
    expect(forwardScene.renderedRelations[0].relationIds).toHaveLength(3)
    expect(shuffledScene).toEqual(forwardScene)

    const allLayers = renderingContext({backbone: true, inferred: true, endpoints: false})
    const all = allLayers.buildVisibleGraphData(effectiveGraph(forward, forwardScene))
    expect(all.edgeData).toHaveLength(1)
    expect(all.edgeData[0]).toMatchObject({
      flowPps: 187,
      edgeCount: 4,
      topologyClassCounts: expect.objectContaining({backbone: 3, inferred: 1}),
    })

    const backboneOnly = renderingContext({backbone: true, inferred: false, endpoints: false})
    expect(backboneOnly.buildVisibleGraphData(effectiveGraph(forward, forwardScene)).edgeData[0]).toMatchObject({
      flowPps: 180,
      edgeCount: 3,
      topologyClass: "backbone",
      topologyClassCounts: expect.objectContaining({backbone: 3, inferred: 0}),
    })

    const inferredOnly = renderingContext({backbone: false, inferred: true, endpoints: false})
    expect(inferredOnly.buildVisibleGraphData(effectiveGraph(forward, forwardScene)).edgeData[0]).toMatchObject({
      flowPps: 7,
      edgeCount: 1,
      topologyClass: "inferred",
      topologyClassCounts: expect.objectContaining({backbone: 0, inferred: 1}),
    })

    const shuffledAll = renderingContext({backbone: true, inferred: true, endpoints: false})
    expect(shuffledAll.buildVisibleGraphData(effectiveGraph(shuffled, shuffledScene)).edgeData[0].flowPps).toEqual(187)
  })

  it("selects one coherent duplicate presentation record across Arrow row order", () => {
    const forward = dedupe(decode(arrowBytes([0, 1, 2, 3], DUPLICATE_RELATIONS)))
    const shuffled = dedupe(decode(arrowBytes([3, 0, 2, 1], DUPLICATE_RELATIONS)))
    const forwardScene = prepareTopologySceneInput(forward)
    const shuffledScene = prepareTopologySceneInput(shuffled)

    expect(new Set(forward.edges.map((edge) => edge.id)).size).toEqual(1)
    expect(shuffledScene).toEqual(forwardScene)

    const forwardEdge = renderingContext({backbone: true, inferred: false, endpoints: false})
      .buildVisibleGraphData(effectiveGraph(forward, forwardScene)).edgeData[0]
    const shuffledEdge = renderingContext({backbone: true, inferred: false, endpoints: false})
      .buildVisibleGraphData(effectiveGraph(shuffled, shuffledScene)).edgeData[0]

    expect(shuffledEdge).toEqual(forwardEdge)
    expect(forwardEdge).toMatchObject({
      label: "SNMP BACKBONE 200pps / 2G",
      flowPps: 1_000,
      flowBps: 10_000_000,
      capacityBps: 4_000_000_000,
      edgeCount: 4,
      details: {
        source_id: "a",
        target_id: "b",
        source_if_index: 10,
        source_interface: "xe-0/0/0",
        target_if_index: 20,
        target_interface: "xe-0/0/1",
        telemetry_source: "interface-b",
        telemetry_observed_at: "2026-08-24T02:00:00Z",
        tie_breaker: "sparkline-source",
        interface_sparkline_label: "Current interface history",
        interface_sparkline: [{bucket: "01:55", value: 30}, {bucket: "02:00", value: 40}],
        metadata: {relation_type: "CONNECTED_TO", topology_plane: "physical"},
      },
    })
  })
})

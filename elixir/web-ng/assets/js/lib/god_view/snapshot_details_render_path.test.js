import {OrthographicView} from "@deck.gl/core"
import ELK from "elkjs/lib/elk.bundled.js"
import {describe, expect, it, vi} from "vitest"

vi.mock("phoenix", () => ({
  Socket: class MockSocket {},
}))

vi.mock("../../wasm/god_view_exec_runtime", () => ({
  GodViewWasmEngine: class MockGodViewWasmEngine {
    static async init() {
      return null
    }
  },
}))

import GodViewRenderer from "../GodViewRenderer"
import {snapshotIpcBytes} from "./fixtures/snapshot_ipc"

// A synthetic estate: a backbone ring of switches, one anchor per switch carrying a collapsed
// endpoint summary, and every row with details JSON the render path would once have parsed.
function syntheticEstate(switchCount = 6) {
  const nodes = []
  const edges = []
  for (let i = 0; i < switchCount; i += 1) {
    nodes.push({
      id: `sw-${i}`,
      label: `switch ${i}`,
      state: i % 4,
      operUp: 1,
      details: {
        id: `sw-${i}`,
        ip: `192.0.2.${i + 1}`,
        hostname: `sw-${i}.example.com`,
        type: "switch",
        identity_source: "mapper",
        topology_plane: "backbone",
        topology_unplaced: false,
      },
    })
  }
  for (let i = 0; i < switchCount; i += 1) {
    nodes.push({
      id: `summary-${i}`,
      label: `${i + 3} endpoints`,
      state: 2,
      details: {
        id: `summary-${i}`,
        type: "endpoint",
        cluster_kind: "endpoint-summary",
        cluster_id: `cluster-${i}`,
        cluster_anchor_id: `sw-${i}`,
        cluster_expanded: false,
        cluster_member_count: i + 3,
        identity_source: "backend_endpoint_cluster",
      },
    })
  }
  const relation = (source, target, topologyClass, relationType, plane) => ({
    source,
    target,
    flowPps: 10 + source,
    topologyClass,
    evidenceClass: topologyClass === "endpoints" ? "endpoint-attachment" : "direct",
    protocol: "snmp",
    details: {
      source_id: nodes[source].id,
      target_id: nodes[target].id,
      source_interface: "ge-0/0/1",
      target_interface: "ge-0/0/2",
      source_if_index: 1,
      target_if_index: 2,
      telemetry_source: "interface",
      telemetry_observed_at: "2026-01-01T00:00:00Z",
      interface_sparkline: [{bucket: "00:00", value: source}],
      metadata: {relation_type: relationType, topology_plane: plane},
    },
  })
  for (let i = 0; i < switchCount; i += 1) {
    edges.push(relation(i, (i + 1) % switchCount, "backbone", "CONNECTS_TO", "physical"))
    edges.push(relation(i, switchCount + i, "endpoints", "ATTACHED_TO", "attachment"))
  }
  return {nodes, edges}
}

function viewportFor(state) {
  return new OrthographicView({id: "god-view-ortho"}).makeViewport({
    width: 1280,
    height: 720,
    viewState: {target: [0, 0, 0], zoom: 0, ...state.viewState},
  })
}

function element() {
  return {
    style: {},
    textContent: "",
    innerHTML: "",
    classList: {add: vi.fn(), remove: vi.fn(), toggle: vi.fn(), contains: () => false},
    setAttribute: vi.fn(),
    querySelector: () => null,
    querySelectorAll: () => [],
  }
}

function renderer() {
  const instance = new GodViewRenderer({clientWidth: 1280, clientHeight: 720}, vi.fn(), vi.fn(), {csrfToken: "t"})
  const {context} = instance
  context.lifecycle.initLifecycleState()
  const engine = new ELK()
  Object.assign(context.state, {
    layoutEngine: {layout: (graph) => engine.layout(graph)},
    deck: {setProps: vi.fn(), getViewports: () => [viewportFor(context.state)], redraw: vi.fn()},
    summary: element(),
    details: element(),
    canvas: {style: {}, getBoundingClientRect: () => ({width: 1280, height: 720})},
    animationTimer: 1,
    topologyLabelMeasureText: (text) => ({width: String(text).length * 6}),
  })
  return context
}

async function laidOut(context, semanticLevel) {
  const {lifecycle, layout} = context
  const decoded = lifecycle.decodeArrowGraph(snapshotIpcBytes(syntheticEstate()))
  if (semanticLevel === "detail") decoded._topologySemanticLevel = "detail"
  const graph = await layout.prepareGraphLayout(decoded, 1, layout.graphTopologyStamp(decoded))
  expect(graph._layoutError).toBeUndefined()
  return {graph, counts: () => decoded.columns.parsedDetailCounts()}
}

describe("snapshot details on the render path", () => {
  it("loads, lays out, renders, filters, hovers and pans without parsing details, then parses the picked node", async () => {
    const context = renderer()
    const {state, rendering} = context
    const {graph, counts} = await laidOut(context, "overview")
    expect(graph._layoutMode).toBe("elk-radial-overview")
    state.lastGraph = graph

    rendering.renderGraph(graph)
    expect(state.lastGraphLayerFrame.nodeData.length).toBeGreaterThan(0)
    expect(state.lastGraphLayerFrame.edgeData.length).toBeGreaterThan(0)
    expect(counts()).toEqual({nodes: 0, edges: 0})

    // Filter change.
    state.filters = {...state.filters, healthy: false}
    rendering.renderGraph(graph)
    // Hover change: reuses the render's node records and edge data rather than rebuilding them.
    const {nodeData: filteredNodes, edgeData: filteredEdges} = state.lastGraphLayerFrame
    const hovered = state.lastGraphLayerFrame.nodeData[0]
    rendering.handleHover({layer: {id: "god-view-nodes"}, object: hovered, index: 0})
    expect(state.lastGraphLayerFrame.nodeData).toBe(filteredNodes)
    expect(state.lastGraphLayerFrame.edgeData).toBe(filteredEdges)
    // Camera change.
    rendering.refreshGraphLayersForViewState()
    expect(counts()).toEqual({nodes: 0, edges: 0})

    // Selecting a node opens its details card: that node, and only it, is parsed. The
    // selection, too, reuses the frame instead of rendering the graph again.
    rendering.handlePick({picked: true, layer: {id: "god-view-nodes"}, object: hovered, index: 0})
    expect(state.selectedNodeIndex).toBe(hovered.index)
    expect(state.lastGraphLayerFrame.edgeData).toBe(filteredEdges)
    expect(state.details.innerHTML).toContain(graph.nodes[hovered.index].details.ip)
    expect(counts()).toEqual({nodes: 1, edges: 0})
  }, 60_000)

  it("builds the bounded-detail scene and its render data without parsing details", async () => {
    const context = renderer()
    const {state, rendering} = context
    const {graph, counts} = await laidOut(context, "detail")
    expect(graph._layoutMode).toBe("elk-scene-detail")

    const effective = {...graph, shape: "local"}
    const first = rendering.buildVisibleGraphData(effective)
    state.filters = {...state.filters, healthy: false}
    const filtered = rendering.buildVisibleGraphData(effective)

    expect(first.edgeData.length).toBeGreaterThan(0)
    expect(filtered.nodeData.length).toBeLessThan(first.nodeData.length)
    expect(counts()).toEqual({nodes: 0, edges: 0})
  }, 60_000)
})

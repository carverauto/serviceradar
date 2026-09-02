import GodViewRenderer from "./js/lib/GodViewRenderer"
import {installGodViewAcceptanceGeometryObserver} from "./god_view_acceptance_geometry_observer"
import {
  collapsedFarm01Graph,
  expandedFarm01Graph,
} from "./js/lib/god_view/fixtures/farm01_topology_regression"

const FIRST_CLUSTER = "cluster:endpoints:farm01:gateway-01"
const SECOND_CLUSTER = "cluster:endpoints:farm01:gateway-02"

function expandClusters(ordinals) {
  const graph = collapsedFarm01Graph()
  const expanded = new Set(ordinals)
  const nodes = graph.nodes.map((node) => {
    const ordinal = Number(String(node.id).match(/endpoint-summary-(\d+)$/)?.[1])
    return expanded.has(ordinal)
      ? {...node, details: {...node.details, cluster_expanded: true}}
      : node
  })
  const edges = [...graph.edges]

  for (const ordinal of [...expanded].sort((a, b) => a - b)) {
    const suffix = String(ordinal).padStart(2, "0")
    const anchorId = `farm01:gateway-${suffix}`
    const clusterId = `cluster:endpoints:${anchorId}`
    // Attach to the summary, mirroring the server -- see the fixture module for why.
    const summaryIndex = nodes.findIndex((node) => node.id === `farm01:endpoint-summary-${suffix}`)
    const offset = nodes.length
    for (let memberOrdinal = 1; memberOrdinal <= 24; memberOrdinal += 1) {
      const memberSuffix = String(memberOrdinal).padStart(2, "0")
      nodes.push({
        id: `farm01:endpoint-member-${suffix}-${memberSuffix}`,
        label: `Farm01 gateway ${ordinal} endpoint ${memberOrdinal}`,
        state: 1,
        operUp: 1,
        details: {
          cluster_id: clusterId,
          cluster_kind: "endpoint-member",
          cluster_anchor_id: anchorId,
          cluster_expanded: true,
        },
      })
      edges.push({
        id: `farm01:attachment:member-${suffix}-${memberSuffix}`,
        source: summaryIndex,
        target: offset + memberOrdinal - 1,
        topologyClass: "endpoints",
        evidenceClass: "endpoint-attachment",
      })
    }
  }

  return {nodes, edges}
}

const fixtures = {
  collapsed: collapsedFarm01Graph,
  expanded: expandedFarm01Graph,
  second: () => expandClusters([2]),
  concurrent: () => expandClusters([1, 2]),
}

function settle() {
  return new Promise((resolveFrame) => requestAnimationFrame(() => requestAnimationFrame(resolveFrame)))
}

async function start() {
  window.__SR_GOD_VIEW_ACCEPTANCE__ = true
  await document.fonts.ready
  const root = document.querySelector("#god-view-fixture")
  const renderer = new GodViewRenderer(root, () => {}, () => {})
  installGodViewAcceptanceGeometryObserver(renderer.context)
  const {state, layout, rendering, lifecycle} = renderer.context
  lifecycle.initLifecycleState()
  lifecycle.bindLifecycleMethods()
  state.packetFlowEnabled = false
  state.packetFlowShaderEnabled = false
  state.layers.atmosphere = false
  state.topologyLayers.endpoints = true
  lifecycle.ensureDOM()
  lifecycle.resizeCanvas()
  lifecycle.syncReducedMotionPreference()
  lifecycle.ensureDeck()

  let revision = 100
  let currentFixture = ""

  async function renderFixture(name) {
    const fixture = fixtures[name]
    if (!fixture) throw new Error(`unknown fixture: ${name}`)
    const startedAt = performance.now()
    const laidOut = await layout.prepareGraphLayout(fixture(), revision++, `acceptance:${name}`)
    state.lastGraph = laidOut
    state.lastRevision = revision
    state.lastTopologyStamp = `acceptance:${name}`
    state.hasAutoFit = false
    state.userCameraLocked = false
    try {
      rendering.renderGraph(laidOut)
    } catch (error) {
      throw new Error(`${String(error)}; viewport=${state.viewportWidth}x${state.viewportHeight}; safe=${JSON.stringify(state.topologyLabelSafeRect)}`)
    }
    state.deck.redraw(true)
    await settle()
    currentFixture = name
    return {elapsedMs: performance.now() - startedAt, snapshot: window.__SR_GOD_VIEW_GEOMETRY__()}
  }

  async function fit() {
    rendering.autoFitViewState(state.lastGraph, {force: true})
    rendering.refreshGraphLayersForViewState()
    state.deck.redraw(true)
    await settle()
    return window.__SR_GOD_VIEW_GEOMETRY__()
  }

  async function focus(clusterId = FIRST_CLUSTER) {
    if (!rendering.focusClusterNeighborhood(state.lastGraph, clusterId)) {
      throw new Error(`unable to focus ${clusterId}`)
    }
    rendering.refreshGraphLayersForViewState()
    state.deck.redraw(true)
    await settle()
    return window.__SR_GOD_VIEW_GEOMETRY__()
  }

  async function profile(width, height) {
    root.style.width = `${width}px`
    root.style.height = `${height}px`
    lifecycle.resizeCanvas()
    const result = await renderFixture(currentFixture)
    return result.snapshot
  }

  window.__SR_GOD_VIEW_HARNESS__ = Object.freeze({
    renderFixture,
    fit,
    focus,
    profile,
    firstCluster: FIRST_CLUSTER,
    secondCluster: SECOND_CLUSTER,
  })
}

void start()

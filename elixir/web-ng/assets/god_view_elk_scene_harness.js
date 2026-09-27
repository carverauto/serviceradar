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

// God View renders on WebGPU only. Wait for deck's device so a browser without WebGPU fails
// here, naming the cause, instead of as a null deck several calls later.
// A WebGPU validation error arrives asynchronously and ends in the renderer's error state, so
// every step checks for it after its frames have been submitted.
function assertRendererHealthy(state) {
  if (state.rendererMode !== "webgpu") {
    throw new Error(`God View renderer is ${state.rendererMode}: ${state.rendererError || "no WebGPU device"}`)
  }
}

async function settleFrames(count) {
  for (let frame = 0; frame < count; frame += 1) await settle()
}

// Topology fixtures carry no telemetry; give every edge traffic so packet flow has particles.
function withTraffic(graph) {
  return {
    ...graph,
    edges: graph.edges.map((edge, index) => ({
      ...edge,
      flowPps: 400 + index * 25,
      flowPpsAb: 250 + index * 10,
      flowPpsBa: 150 + index * 15,
      flowBps: 8_000_000,
      capacityBps: 1_000_000_000,
      telemetryEligible: true,
    })),
  }
}

async function rendererReady(state, timeoutMs = 30_000) {
  const deadline = performance.now() + timeoutMs
  while (state.rendererMode === "initializing" && performance.now() < deadline) await settle()
  if (state.rendererMode !== "webgpu") {
    const context = `navigator.gpu=${Boolean(navigator.gpu)} secureContext=${globalThis.isSecureContext}`
    throw new Error(`God View renderer is ${state.rendererMode}: ${state.rendererError || "no WebGPU device"} (${context})`)
  }
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
  state.layers.atmosphere = false
  state.topologyLayers.endpoints = true
  lifecycle.ensureDOM()
  lifecycle.resizeCanvas()
  lifecycle.syncReducedMotionPreference()
  lifecycle.ensureDeck()
  await rendererReady(state)

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
    assertRendererHealthy(state)
    state.deck.redraw(true)
    await settle()
    assertRendererHealthy(state)
    currentFixture = name
    return {elapsedMs: performance.now() - startedAt, snapshot: window.__SR_GOD_VIEW_GEOMETRY__()}
  }

  // Draws packet flow (the one custom-shader layer) over a fixture for a few animated frames.
  // Its pipeline is only created, and so only validated by the device, once it has particles.
  async function renderPacketFlow(name = "collapsed") {
    const fixture = fixtures[name]
    if (!fixture) throw new Error(`unknown fixture: ${name}`)
    state.layers.atmosphere = true
    state.packetFlowEnabled = true
    try {
      const laidOut = await layout.prepareGraphLayout(withTraffic(fixture()), revision++, `acceptance:packets:${name}`)
      state.lastGraph = laidOut
      state.hasAutoFit = false
      state.userCameraLocked = false
      rendering.renderGraph(laidOut)
      // Animate the way the live loop does: advance the clock, not the graph.
      for (let frame = 0; frame < 6; frame += 1) {
        state.animationPhase = frame / 10
        rendering.advanceAnimation()
        assertRendererHealthy(state)
        state.deck.redraw(true)
        await settle()
      }
      await settleFrames(4)
      assertRendererHealthy(state)
      const particles = (state.deck.props.layers || []).find((layer) => layer.id === "god-view-atmosphere-particles")
      return {flowEdges: particles?.props?.data?.length || 0, rendererMode: state.rendererMode}
    } finally {
      state.layers.atmosphere = false
      state.packetFlowEnabled = false
        }
  }

  // Runs the product's own animation loop (requestAnimationFrame -> advanceAnimation) over a
  // fixture with packet flow on, the way a live page does. The caller probes responsiveness from
  // outside the page while it runs, then stops it and reads the frame statistics.
  let liveAnimation = null

  async function startLiveAnimation(name = "collapsed", {width = 960, height = 540} = {}) {
    const fixture = fixtures[name]
    if (!fixture) throw new Error(`unknown fixture: ${name}`)
    if (liveAnimation) throw new Error("live animation already running")
    root.style.width = `${width}px`
    root.style.height = `${height}px`
    lifecycle.resizeCanvas()
    state.layers.atmosphere = true
    state.packetFlowEnabled = true
    const laidOut = await layout.prepareGraphLayout(withTraffic(fixture()), revision++, `acceptance:live:${name}`)
    state.lastGraph = laidOut
    state.hasAutoFit = false
    state.userCameraLocked = false
    rendering.renderGraph(laidOut)
    assertRendererHealthy(state)
    const packetFlow = () => (state.deck.props.layers || []).find((layer) => layer.id === "god-view-atmosphere-particles")
    const flowEdges = packetFlow()?.props?.data?.length || 0

    // Count graph renders from here on: the loop must advance the clock, never re-render.
    const renderGraph = rendering.renderGraph
    let renderGraphCalls = 0
    rendering.renderGraph = (...args) => {
      renderGraphCalls += 1
      return renderGraph(...args)
    }
    // An independent frame clock, so the frame rate is measured by the browser rather than
    // by the loop under test.
    const gaps = []
    let lastFrameAt = performance.now()
    let frameClock = 0
    const onFrame = (now) => {
      gaps.push(now - lastFrameAt)
      lastFrameAt = now
      frameClock = requestAnimationFrame(onFrame)
    }
    frameClock = requestAnimationFrame(onFrame)

    lifecycle.startAnimationLoop()
    // The first frames compile pipelines and upload buffers. Measure the steady state after them.
    const warmupStartedAt = performance.now()
    while (gaps.length < 12 && performance.now() - warmupStartedAt < 20_000) await settle()
    const warmupMs = performance.now() - warmupStartedAt
    gaps.length = 0
    lastFrameAt = performance.now()

    const startedAt = performance.now()
    const startTime = packetFlow()?.props?.time
    const startFrames = state.animationFrames || 0
    let slowestTickMs = 0
    const tickWatch = setInterval(() => {
      slowestTickMs = Math.max(slowestTickMs, Number(state.lastAnimationFrameMs || 0))
    }, 50)

    liveAnimation = {
      async stop() {
        lifecycle.stopAnimationLoop()
        cancelAnimationFrame(frameClock)
        clearInterval(tickWatch)
        rendering.renderGraph = renderGraph
        const elapsedMs = performance.now() - startedAt
        const frames = (state.animationFrames || 0) - startFrames
        const endTime = packetFlow()?.props?.time
        state.layers.atmosphere = false
        state.packetFlowEnabled = false
        liveAnimation = null
        return {
          rendererMode: state.rendererMode,
          rendererError: state.rendererError ? String(state.rendererError.message || state.rendererError) : null,
          flowEdges,
          warmupMs,
          elapsedMs,
          animationFrames: frames,
          animationFps: (frames * 1000) / elapsedMs,
          browserFps: gaps.length > 0 ? (gaps.length * 1000) / gaps.reduce((sum, gap) => sum + gap, 0) : 0,
          longestFrameGapMs: gaps.length > 0 ? Math.max(...gaps) : null,
          slowestTickMs,
          renderGraphCalls,
          timeAdvanced: Number.isFinite(startTime) && Number.isFinite(endTime) && endTime !== startTime,
        }
      },
    }
    return {flowEdges, rendererMode: state.rendererMode}
  }

  async function stopLiveAnimation() {
    if (!liveAnimation) throw new Error("live animation is not running")
    return liveAnimation.stop()
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
    renderPacketFlow,
    startLiveAnimation,
    stopLiveAnimation,
    fit,
    focus,
    profile,
    firstCluster: FIRST_CLUSTER,
    secondCluster: SECOND_CLUSTER,
  })
}

start().catch((error) => {
  window.__SR_GOD_VIEW_HARNESS_ERROR__ = String(error?.stack || error)
})

import {afterEach, describe, expect, it, vi} from "vitest"

import {godViewRenderingGraphCoreMethods} from "./rendering_graph_core_methods"

function renderContext() {
  const scene = {
    profileKey: "landscape",
    manifest: {
      nodes: 2,
      semanticEdges: 1,
      attachmentEdges: 0,
      renderedRoutes: 1,
      renderedGlyphs: 2,
    },
    bounds: {minX: 10, minY: 20, maxX: 110, maxY: 80},
    nodes: [
      {id: "router-a", kind: "node", groupId: null, center: {x: 20, y: 40}, width: 40, height: 32},
      {id: "router-b", kind: "node", groupId: null, center: {x: 100, y: 60}, width: 40, height: 32},
    ],
    groups: [],
    routes: [{
      id: "rendered:router-a|router-b",
      sourceId: "router-a",
      targetId: "router-b",
      relationIds: ["edge-a-b"],
      points: [{x: 20, y: 40}, {x: 60, y: 40}, {x: 60, y: 60}, {x: 100, y: 60}],
    }],
  }
  const effective = {
    shape: "local",
    _layoutMode: "elk-scene",
    _layoutCacheKey: "7:fixture:landscape:scene-key",
    _topologyScene: scene,
  }
  const nodeData = scene.nodes.map((node, index) => ({
    id: node.id,
    index,
    position: [node.center.x, node.center.y, 0],
    details: {},
    pps: 999_999,
  }))
  const labelData = [{
    ...nodeData[0],
    labelAdmission: {
      box: {left: 121, top: 201, right: 177, bottom: 217},
      pixelOffset: [14, 0],
      textAnchor: "start",
      alignmentBaseline: "center",
    },
  }]
  const viewport = {
    width: 1920,
    height: 1080,
    project: ([x, y]) => [x + 100, y + 200],
  }
  const state = {
    deck: {
      getViewports: () => [viewport],
      setProps: vi.fn(),
    },
    layers: {atmosphere: true},
    lastGraphLayerFrame: null,
    topologyLabelSafeRect: {left: 80, top: 48, right: 1870, bottom: 1012},
    viewState: {target: [60, 50, 0], zoom: 1.25, minZoom: -3, maxZoom: 5},
    csrfToken: "must-never-leak",
    bearerToken: "also-must-never-leak",
  }
  const context = {
    state,
    deps: {
      ensureDeck: vi.fn(),
      reshapeGraph: () => effective,
    },
    autoFitViewState: vi.fn(),
    buildVisibleGraphData: () => ({
      edgeData: [{
        sourceId: "router-a",
        targetId: "router-b",
        flowPps: 42_000,
        protocol: "credential-looking-telemetry",
      }],
      edgeLabelData: [],
      nodeData,
      rootPulseNodes: [],
      selectedVisibleNode: null,
    }),
    renderSelectionDetails: vi.fn(),
    nodeHaloRadiusPixels: () => 20,
    topologyRouteStrokeWidth: () => 38,
    buildGraphLayers: () => [{
      id: "god-view-edges-mantle",
      props: {
        data: [{
          interactionKey: "local:rendered:router-a|router-b",
          sourceId: "router-a",
          targetId: "router-b",
          flowPps: 42_000,
        }],
        getWidth: () => 38,
        widthMinPixels: 6,
        widthUnits: "pixels",
      },
    }, {id: "god-view-node-labels", props: {data: labelData}}],
  }

  return {context, effective}
}

function assertDeeplyFrozenPlainData(value) {
  if (value === null || typeof value !== "object") return
  expect(Object.getPrototypeOf(value)).toBe(value instanceof Array ? Array.prototype : Object.prototype)
  expect(Object.isFrozen(value)).toBe(true)
  for (const child of Object.values(value)) assertDeeplyFrozenPlainData(child)
}

afterEach(() => {
  delete globalThis.window
})

describe("God-View acceptance geometry hook", () => {
  it("does not expose a geometry hook during default production rendering", () => {
    globalThis.window = {}
    const {context, effective} = renderContext()

    godViewRenderingGraphCoreMethods.renderGraph.call(context, effective)

    expect(globalThis.window.__SR_GOD_VIEW_GEOMETRY__).toBeUndefined()
  })

  it("exposes immutable plain semantic and geometry data only in acceptance mode", () => {
    globalThis.window = {__SR_GOD_VIEW_ACCEPTANCE__: true}
    const {context, effective} = renderContext()

    godViewRenderingGraphCoreMethods.renderGraph.call(context, effective)

    expect(globalThis.window.__SR_GOD_VIEW_GEOMETRY__).toEqual(expect.any(Function))
    const snapshot = globalThis.window.__SR_GOD_VIEW_GEOMETRY__()
    expect(snapshot).toMatchObject({
      sceneKey: "7:fixture:landscape:scene-key",
      profileKey: "landscape",
      counts: {
        semanticNodes: 2,
        semanticEdges: 1,
        attachmentEdges: 0,
        renderedRoutes: 1,
        renderedGlyphs: 2,
        admittedLabels: 1,
      },
      safeRect: {left: 80, top: 48, right: 1870, bottom: 1012},
      viewState: {target: [60, 50, 0], zoom: 1.25, minZoom: -3, maxZoom: 5},
    })
    expect(snapshot.nodes).toHaveLength(2)
    expect(snapshot.routes).toEqual([{
      sourceId: "router-a",
      targetId: "router-b",
      strokeWidth: 38,
      points: [{x: 20, y: 40}, {x: 60, y: 40}, {x: 60, y: 60}, {x: 100, y: 60}],
      projectedPoints: [{x: 120, y: 240}, {x: 160, y: 240}, {x: 160, y: 260}, {x: 200, y: 260}],
    }])
    expect(Object.keys(snapshot.routes[0]).sort()).toEqual([
      "points", "projectedPoints", "sourceId", "strokeWidth", "targetId",
    ])
    expect(snapshot.glyphs).toEqual([
      {nodeId: "router-a", left: 100, top: 220, right: 140, bottom: 260},
      {nodeId: "router-b", left: 180, top: 240, right: 220, bottom: 280},
    ])
    expect(snapshot.labels).toEqual([{
      nodeId: "router-a",
      box: {left: 121, top: 201, right: 177, bottom: 217},
    }])
    assertDeeplyFrozenPlainData(snapshot)
  })

  it("never leaks runtime telemetry or credentials through the acceptance snapshot", () => {
    globalThis.window = {__SR_GOD_VIEW_ACCEPTANCE__: true}
    const {context, effective} = renderContext()

    godViewRenderingGraphCoreMethods.renderGraph.call(context, effective)

    const serialized = JSON.stringify(globalThis.window.__SR_GOD_VIEW_GEOMETRY__())
    expect(serialized).not.toMatch(/pps|flow|protocol|credential|csrf|bearer|token|42_000|42000|999999/i)
  })

  it("refreshes through the view-state path and deletes a stale hook after acceptance is disabled", () => {
    globalThis.window = {__SR_GOD_VIEW_ACCEPTANCE__: true}
    const {context, effective} = renderContext()

    godViewRenderingGraphCoreMethods.renderGraph.call(context, effective)
    const firstSnapshot = globalThis.window.__SR_GOD_VIEW_GEOMETRY__()
    context.state.viewState = {target: [72, 64, 0], zoom: 2, minZoom: -3, maxZoom: 5}

    expect(godViewRenderingGraphCoreMethods.refreshGraphLayersForViewState.call(context)).toBe(true)

    const secondSnapshot = globalThis.window.__SR_GOD_VIEW_GEOMETRY__()
    expect(secondSnapshot).not.toBe(firstSnapshot)
    expect(secondSnapshot.viewState).toEqual({target: [72, 64, 0], zoom: 2, minZoom: -3, maxZoom: 5})

    globalThis.window.__SR_GOD_VIEW_ACCEPTANCE__ = false
    expect(godViewRenderingGraphCoreMethods.refreshGraphLayersForViewState.call(context)).toBe(true)

    expect(globalThis.window.__SR_GOD_VIEW_GEOMETRY__).toBeUndefined()
  })

  it.each([
    ["has no matching rendered layer", () => []],
    ["has a NaN width", () => [{
      id: "god-view-edges-mantle",
      props: {data: [{sourceId: "router-a", targetId: "router-b"}], getWidth: () => Number.NaN},
    }]],
    ["has a zero width", () => [{
      id: "god-view-edges-mantle",
      props: {data: [{sourceId: "router-a", targetId: "router-b"}], getWidth: () => 0},
    }]],
  ])("fails loudly when an acceptance route %s", (_description, buildLayers) => {
    globalThis.window = {__SR_GOD_VIEW_ACCEPTANCE__: true}
    const {context, effective} = renderContext()
    context.buildGraphLayers = buildLayers

    expect(() => godViewRenderingGraphCoreMethods.renderGraph.call(context, effective))
      .toThrow(/route router-a -> router-b.*finite positive rendered stroke width/i)
    expect(globalThis.window.__SR_GOD_VIEW_GEOMETRY__).toBeUndefined()
  })
})

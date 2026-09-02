import {describe, expect, it, vi} from "vitest"

import {installGodViewAcceptanceGeometryObserver} from "./god_view_acceptance_geometry_observer"
import {godViewRenderingGraphCoreMethods} from "./js/lib/god_view/rendering_graph_core_methods"

const ACCEPTANCE_FLAG = "__SR_GOD_VIEW_ACCEPTANCE__"
const GEOMETRY_HOOK = "__SR_GOD_VIEW_GEOMETRY__"

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
    _layoutMode: "elk-scene-detail",
    _topologySemanticLevel: "detail",
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
  const labelData = [
    {
      ...nodeData[0],
      labelAdmission: {
        box: {left: 121, top: 201, right: 177, bottom: 217},
        pixelOffset: [14, 0],
        textAnchor: "start",
        alignmentBaseline: "center",
      },
    },
    {
      ...nodeData[1],
      labelAdmission: {
        box: {left: 181, top: 221, right: 237, bottom: 237},
        pixelOffset: [14, 0],
        textAnchor: "start",
        alignmentBaseline: "center",
      },
    },
  ]
  const viewport = {
    width: 1920,
    height: 1080,
    project: ([x, y]) => [x + 100, y + 200],
  }
  const state = {
    deck: {getViewports: () => [viewport], setProps: vi.fn()},
    layers: {atmosphere: true},
    lastGraphLayerFrame: null,
    topologyLabelSafeRect: {left: 80, top: 48, right: 1870, bottom: 1012},
    viewState: {target: [60, 50, 0], zoom: 1.25, minZoom: -3, maxZoom: 5},
    csrfToken: "must-never-leak",
    bearerToken: "also-must-never-leak",
  }
  const context = {
    state,
    deps: {ensureDeck: vi.fn(), reshapeGraph: () => effective},
    autoFitViewState: vi.fn(),
    buildVisibleGraphData: () => ({
      edgeData: [{
        routeId: "rendered:router-a|router-b",
        sourceId: "router-a",
        targetId: "router-b",
        path: [[20, 40, 0], [60, 40, 0], [60, 60, 0], [100, 60, 0]],
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
    buildGraphLayers: () => [{
      id: "god-view-edges-mantle",
      props: {
        data: [{
          routeId: "rendered:router-a|router-b",
          interactionKey: "local:rendered:router-a|router-b",
          sourceId: "router-a",
          targetId: "router-b",
          path: [[20, 40, 0], [60, 40, 0], [60, 60, 0], [100, 60, 0]],
          flowPps: 42_000,
        }],
        getPath: (edge) => edge.path,
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

describe("God-View acceptance-only geometry observer", () => {
  it("keeps the geometry hook absent unless the acceptance flag is explicitly enabled", () => {
    const target = {}
    const {context, effective} = renderContext()
    installGodViewAcceptanceGeometryObserver(context, target)

    godViewRenderingGraphCoreMethods.renderGraph.call(context, effective)

    expect(target[GEOMETRY_HOOK]).toBeUndefined()
  })

  it("publishes deeply frozen sanitized semantic and geometry data", () => {
    const target = {[ACCEPTANCE_FLAG]: true}
    const {context, effective} = renderContext()
    installGodViewAcceptanceGeometryObserver(context, target)

    godViewRenderingGraphCoreMethods.renderGraph.call(context, effective)

    expect(target[GEOMETRY_HOOK]).toEqual(expect.any(Function))
    const snapshot = target[GEOMETRY_HOOK]()
    expect(snapshot).toMatchObject({
      sceneKey: "7:fixture:landscape:scene-key",
      profileKey: "landscape",
      counts: {
        semanticNodes: 2,
        semanticEdges: 1,
        attachmentEdges: 0,
        renderedRoutes: 1,
        physicalRoutes: 1,
        renderedPhysicalRoutes: 1,
        manifolds: 0,
        renderedGlyphs: 2,
        admittedLabels: 2,
      },
      safeRect: {left: 80, top: 48, right: 1870, bottom: 1012},
      viewState: {target: [60, 50, 0], zoom: 1.25, minZoom: -3, maxZoom: 5},
      semanticLevel: "detail",
      glyphIds: ["router-a", "router-b"],
      labelIds: ["router-a", "router-b"],
      unlabeledGlyphIds: [],
    })
    expect(snapshot.routes).toEqual([{
      id: "rendered:router-a|router-b",
      auxiliary: false,
      sourceId: "router-a",
      targetId: "router-b",
      sourceContactId: "router-a",
      targetContactId: "router-b",
      semanticRouteIds: [],
      junctions: [],
      strokeWidth: 38,
      scenePoints: [{x: 20, y: 40}, {x: 60, y: 40}, {x: 60, y: 60}, {x: 100, y: 60}],
      layerPaths: [{
        layerId: "god-view-edges-mantle",
        points: [{x: 20, y: 40}, {x: 60, y: 40}, {x: 60, y: 60}, {x: 100, y: 60}],
      }],
      points: [{x: 20, y: 40}, {x: 60, y: 40}, {x: 60, y: 60}, {x: 100, y: 60}],
      projectedPoints: [{x: 120, y: 240}, {x: 160, y: 240}, {x: 160, y: 260}, {x: 200, y: 260}],
    }])
    expect(Object.keys(snapshot.routes[0]).sort()).toEqual([
      "auxiliary", "id", "junctions", "layerPaths", "points", "projectedPoints", "scenePoints",
      "semanticRouteIds", "sourceContactId", "sourceId", "strokeWidth", "targetContactId", "targetId",
    ])
    expect(snapshot.glyphs).toEqual([
      {nodeId: "router-a", left: 100, top: 220, right: 140, bottom: 260},
      {nodeId: "router-b", left: 180, top: 240, right: 220, bottom: 280},
    ])
    expect(snapshot.labels).toEqual([
      {
        nodeId: "router-a",
        box: {left: 121, top: 201, right: 177, bottom: 217},
      },
      {
        nodeId: "router-b",
        box: {left: 181, top: 221, right: 237, bottom: 237},
      },
    ])
    expect(JSON.stringify(snapshot)).not.toMatch(/pps|flow|protocol|credential|csrf|bearer|token|42_000|42000|999999/i)
    assertDeeplyFrozenPlainData(snapshot)
  })

  it("publishes the renderer's actual outer visible glyph extent", () => {
    const target = {[ACCEPTANCE_FLAG]: true}
    const {context, effective} = renderContext()
    context.state.managedTopologyVisualDensity = "overview"
    context.nodeVisibleOuterRadiusPixels = vi.fn(() => 10)
    installGodViewAcceptanceGeometryObserver(context, target)

    godViewRenderingGraphCoreMethods.renderGraph.call(context, effective)

    expect(target[GEOMETRY_HOOK]().glyphs).toEqual([
      {nodeId: "router-a", left: 110, top: 230, right: 130, bottom: 250},
      {nodeId: "router-b", left: 190, top: 250, right: 210, bottom: 270},
    ])
    expect(context.nodeVisibleOuterRadiusPixels).toHaveBeenCalledWith(
      expect.any(Object),
      {managedVisualDensity: "overview"},
    )
  })

  it("refreshes through the real view-state path and deletes the stale hook after disable", () => {
    const target = {[ACCEPTANCE_FLAG]: true}
    const {context, effective} = renderContext()
    installGodViewAcceptanceGeometryObserver(context, target)

    godViewRenderingGraphCoreMethods.renderGraph.call(context, effective)
    const firstSnapshot = target[GEOMETRY_HOOK]()
    context.state.viewState = {target: [72, 64, 0], zoom: 2, minZoom: -3, maxZoom: 5}

    expect(godViewRenderingGraphCoreMethods.refreshGraphLayersForViewState.call(context)).toBe(true)
    const secondSnapshot = target[GEOMETRY_HOOK]()
    expect(secondSnapshot).not.toBe(firstSnapshot)
    expect(secondSnapshot.viewState).toEqual({target: [72, 64, 0], zoom: 2, minZoom: -3, maxZoom: 5})

    target[ACCEPTANCE_FLAG] = false
    expect(godViewRenderingGraphCoreMethods.refreshGraphLayersForViewState.call(context)).toBe(true)
    expect(target[GEOMETRY_HOOK]).toBeUndefined()
  })

  it.each([
    ["has a NaN width", () => [{
      id: "god-view-edges-mantle",
      props: {data: [{routeId: "rendered:router-a|router-b"}], getWidth: () => Number.NaN},
    }]],
    ["has a zero width", () => [{
      id: "god-view-edges-mantle",
      props: {data: [{routeId: "rendered:router-a|router-b"}], getWidth: () => 0},
    }]],
  ])("fails loudly when an acceptance route %s", (_description, buildLayers) => {
    const target = {[ACCEPTANCE_FLAG]: true}
    const {context, effective} = renderContext()
    context.buildGraphLayers = buildLayers
    installGodViewAcceptanceGeometryObserver(context, target)

    expect(() => godViewRenderingGraphCoreMethods.renderGraph.call(context, effective))
      .toThrow(/route router-a -> router-b.*finite positive rendered stroke width/i)
    expect(target[GEOMETRY_HOOK]).toBeUndefined()
  })

  it("reports a missing exact physical route instead of borrowing a same-endpoint auxiliary path", () => {
    const target = {[ACCEPTANCE_FLAG]: true}
    const {context, effective} = renderContext()
    effective._topologyScene.physicalRoutes = [
      {...effective._topologyScene.routes[0], id: "auxiliary:one", auxiliary: true},
      {...effective._topologyScene.routes[0], id: "auxiliary:two", auxiliary: true},
    ]
    context.buildVisibleGraphData = () => ({
      edgeData: [], edgeLabelData: [], nodeData: [], rootPulseNodes: [], selectedVisibleNode: null,
    })
    context.buildGraphLayers = () => [{
      id: "god-view-edges-mantle-auxiliary",
      props: {
        data: [{
          routeId: "auxiliary:one",
          sourceId: "router-a",
          targetId: "router-b",
          path: [[20, 40, 0], [100, 60, 0]],
        }],
        getPath: (edge) => edge.path,
        getWidth: () => 10,
      },
    }]
    installGodViewAcceptanceGeometryObserver(context, target)

    godViewRenderingGraphCoreMethods.renderGraph.call(context, effective)
    const snapshot = target[GEOMETRY_HOOK]()

    expect(snapshot.counts).toMatchObject({physicalRoutes: 2, renderedPhysicalRoutes: 1})
    expect(snapshot.routes.map((route) => route.id)).toEqual(["auxiliary:one"])
  })

  it("publishes the exact PathLayer path separately from the decoded scene path", () => {
    const target = {[ACCEPTANCE_FLAG]: true}
    const {context, effective} = renderContext()
    context.buildGraphLayers = () => [{
      id: "god-view-edges-mantle",
      props: {
        data: [{
          routeId: "rendered:router-a|router-b",
          sourceId: "router-a",
          targetId: "router-b",
          path: [[20, 40, 0], [100, 60, 0]],
        }],
        getPath: (edge) => edge.path,
        getWidth: () => 10,
      },
    }]
    installGodViewAcceptanceGeometryObserver(context, target)

    godViewRenderingGraphCoreMethods.renderGraph.call(context, effective)
    const [route] = target[GEOMETRY_HOOK]().routes

    expect(route.points).toEqual([{x: 20, y: 40}, {x: 100, y: 60}])
    expect(route.scenePoints).toEqual(effective._topologyScene.routes[0].points)
    expect(route.points).not.toEqual(route.scenePoints)
  })

  it("preserves duplicate and missing route IDs independently for every transport layer", () => {
    const target = {[ACCEPTANCE_FLAG]: true}
    const {context, effective} = renderContext()
    const routeId = "rendered:router-a|router-b"
    const renderedEdge = {
      routeId,
      sourceId: "router-a",
      targetId: "router-b",
      path: [[20, 40, 0], [60, 40, 0], [60, 60, 0], [100, 60, 0]],
    }
    const layerProps = (data) => ({
      data,
      getPath: (edge) => edge.path,
      getWidth: () => 10,
    })
    context.buildGraphLayers = () => [
      {
        id: "god-view-edges-mantle",
        props: layerProps([renderedEdge, {...renderedEdge}]),
      },
      {
        id: "god-view-edges-crust",
        props: layerProps([]),
      },
    ]
    installGodViewAcceptanceGeometryObserver(context, target)

    godViewRenderingGraphCoreMethods.renderGraph.call(context, effective)
    const snapshot = target[GEOMETRY_HOOK]()

    expect(snapshot.scenePhysicalRouteIds).toEqual([routeId])
    expect(snapshot.renderedPhysicalRouteLayers).toEqual([
      {layerId: "god-view-edges-mantle", routeCount: 2, routeIds: [routeId, routeId]},
      {layerId: "god-view-edges-crust", routeCount: 0, routeIds: []},
    ])
  })
})

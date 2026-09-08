import {describe, expect, it, vi} from "vitest"

import {
  fitTopologyScene,
  focusTopologyGroup,
  measureGodViewSafeRect,
  normalizeGodViewSafeRect,
  topologyGroupFocusScene,
} from "./rendering_scene_view"
import {admitTopologyLabels} from "./rendering_label_collision"

function expandedScene() {
  return {
    bounds: {minX: 0, minY: 0, maxX: 1000, maxY: 520},
    nodes: [
      {id: "anchor", center: {x: 80, y: 250}, width: 112, height: 112},
      {id: "gateway", center: {x: 760, y: 250}, width: 112, height: 112, groupId: "group-a"},
      {id: "member-top", center: {x: 920, y: 120}, width: 96, height: 96, groupId: "group-a"},
      {id: "member-bottom", center: {x: 920, y: 400}, width: 96, height: 96, groupId: "group-a"},
    ],
    groups: [{
      id: "group-a",
      bounds: {minX: 680, minY: 20, maxX: 1000, maxY: 500},
      anchorId: "anchor",
      gatewayId: "gateway",
      memberIds: ["member-top", "member-bottom"],
    }],
    routes: [{
      id: "trunk",
      sourceId: "anchor",
      targetId: "gateway",
      points: [{x: 136, y: 250}, {x: 520, y: 250}, {x: 704, y: 250}],
    }],
  }
}

function project(point, viewState, viewport) {
  const scale = 2 ** viewState.zoom
  return [
    (viewport.width / 2) + ((point.x - viewState.target[0]) * scale),
    (viewport.height / 2) + ((point.y - viewState.target[1]) * scale),
  ]
}

function projectedSceneBounds(scene, viewState, viewport, glyphBoxes) {
  const topLeft = project({x: scene.bounds.minX, y: scene.bounds.minY}, viewState, viewport)
  const bottomRight = project({x: scene.bounds.maxX, y: scene.bounds.maxY}, viewState, viewport)
  const nodeById = new Map(scene.nodes.map((node) => [node.id, node]))
  const boxes = [{left: topLeft[0], top: topLeft[1], right: bottomRight[0], bottom: bottomRight[1]}]
  for (const glyph of glyphBoxes) {
    const center = project(nodeById.get(glyph.nodeId).center, viewState, viewport)
    boxes.push({
      left: center[0] - (glyph.width / 2),
      right: center[0] + (glyph.width / 2),
      top: center[1] - (glyph.height / 2),
      bottom: center[1] + (glyph.height / 2),
    })
  }
  return {
    left: Math.min(...boxes.map((box) => box.left)),
    top: Math.min(...boxes.map((box) => box.top)),
    right: Math.max(...boxes.map((box) => box.right)),
    bottom: Math.max(...boxes.map((box) => box.bottom)),
    glyphs: boxes.slice(1),
  }
}

function intersectByMoreThanOnePixel(left, right) {
  return (
    Math.min(left.right, right.right) - Math.max(left.left, right.left) > 1 &&
    Math.min(left.bottom, right.bottom) - Math.max(left.top, right.top) > 1
  )
}

describe("rendering_scene_view", () => {
  it("measures a deterministic canvas-local safe rectangle from actual status and control bounds", () => {
    const status = {getBoundingClientRect: () => ({left: 112, top: 650, right: 380, bottom: 688, width: 268, height: 38})}
    const controls = {getBoundingClientRect: () => ({left: 720, top: 642, right: 1088, bottom: 688, width: 368, height: 46})}
    const el = {
      getBoundingClientRect: () => ({left: 100, top: 40, right: 1100, bottom: 700, width: 1000, height: 660}),
      querySelectorAll: vi.fn(() => [status, controls]),
    }

    expect(measureGodViewSafeRect(el)).toEqual({left: 0, top: 0, right: 1000, bottom: 594})
    expect(el.querySelectorAll).toHaveBeenCalledTimes(1)
  })

  it("measures the production sibling control panel from the marked safe-area root", () => {
    const controls = {
      getAttribute: vi.fn(() => "right"),
      getBoundingClientRect: () => ({left: 860, top: 52, right: 1088, bottom: 300, width: 228, height: 248}),
    }
    const safeRoot = {
      querySelectorAll: vi.fn(() => [controls]),
    }
    const el = {
      clientWidth: 1000,
      clientHeight: 660,
      getBoundingClientRect: () => ({left: 100, top: 40, right: 1100, bottom: 700, width: 1000, height: 660}),
      closest: vi.fn(() => safeRoot),
      querySelectorAll: vi.fn(() => []),
    }

    expect(measureGodViewSafeRect(el)).toEqual({left: 0, top: 0, right: 752, bottom: 660})
    expect(el.closest).toHaveBeenCalledWith("[data-god-view-safe-root]")
    expect(safeRoot.querySelectorAll).toHaveBeenCalledWith(
      "[data-god-view-safe-area], .sr-god-view-map-controls",
    )
  })

  it("reserves declared top warning and left details chrome for scene fitting", () => {
    const warning = {
      getAttribute: vi.fn(() => "top"),
      getBoundingClientRect: () => ({left: 300, top: 52, right: 650, bottom: 100, width: 350, height: 48}),
    }
    const details = {
      getAttribute: vi.fn(() => "left"),
      getBoundingClientRect: () => ({left: 112, top: 130, right: 412, bottom: 400, width: 300, height: 270}),
    }
    const safeRoot = {querySelectorAll: vi.fn(() => [warning, details])}
    const el = {
      getBoundingClientRect: () => ({left: 100, top: 40, right: 1100, bottom: 700, width: 1000, height: 660}),
      closest: vi.fn(() => safeRoot),
    }

    expect(measureGodViewSafeRect(el)).toEqual({left: 320, top: 68, right: 1000, bottom: 660})
  })

  it("falls back to nonzero client dimensions when the DOM rect is collapsed", () => {
    const el = {
      clientWidth: 640,
      clientHeight: 480,
      getBoundingClientRect: () => ({left: 20, top: 30, right: 20, bottom: 30, width: 0, height: 0}),
      querySelectorAll: () => [],
    }

    expect(measureGodViewSafeRect(el)).toEqual({left: 0, top: 0, right: 640, bottom: 480})
  })

  it("normalizes collapsed and out-of-range safe bounds within the viewport", () => {
    expect(normalizeGodViewSafeRect(
      {left: 999, top: 999, right: -10, bottom: -5},
      {width: 320, height: 260},
    )).toEqual({left: 0, top: 0, right: 320, bottom: 260})
  })

  it("fits complete expanded scene visuals with real two-pass label admission", () => {
    const scene = expandedScene()
    const viewport = {width: 1000, height: 700, minZoom: -3, maxZoom: 5}
    const safeRect = {left: 40, top: 30, right: 820, bottom: 610}
    const glyphBoxes = scene.nodes.map((node) => ({nodeId: node.id, width: 52, height: 52}))
    let admissionPasses = 0
    const admitLabels = ({safeRect: admissionRect, projectedGlyphBoxes}) => {
      admissionPasses += 1
      const glyph = projectedGlyphBoxes.find((item) => item.nodeId === "member-top")
      return admitTopologyLabels({
        candidates: [{
          nodeId: "member-top",
          text: "Member Top With A Long Label",
          point: [(glyph.left + glyph.right) / 2, (glyph.top + glyph.bottom) / 2],
          role: "member",
        }],
        glyphBoxes: projectedGlyphBoxes,
        routeCorridors: [],
        safeRect: admissionRect,
        measureText: () => ({width: 168, height: 16}),
      })
    }
    const input = {scene, viewport, safeRect, glyphBoxes, admitLabels}

    const first = fitTopologyScene(input)
    const second = fitTopologyScene({...input, previous: first})
    const projected = projectedSceneBounds(scene, first.viewState, viewport, glyphBoxes)

    expect(second).toEqual(first)
    expect(admissionPasses).toBe(4)
    expect(first.ok).toBe(true)
    expect(first.fitZoom).toBe(first.viewState.zoom)
    expect(first.missingRequiredLabelIds).toEqual([])
    expect(projected.left).toBeGreaterThanOrEqual(safeRect.left - 1)
    expect(projected.top).toBeGreaterThanOrEqual(safeRect.top - 1)
    expect(projected.right).toBeLessThanOrEqual(safeRect.right + 1)
    expect(projected.bottom).toBeLessThanOrEqual(safeRect.bottom + 1)
    expect(first.admittedLabels).toHaveLength(1)
    expect(first.admittedLabels[0].box.right).toBeLessThanOrEqual(safeRect.right + 1)

    for (let leftIndex = 0; leftIndex < projected.glyphs.length; leftIndex += 1) {
      for (let rightIndex = leftIndex + 1; rightIndex < projected.glyphs.length; rightIndex += 1) {
        expect(intersectByMoreThanOnePixel(projected.glyphs[leftIndex], projected.glyphs[rightIndex])).toBe(false)
      }
    }
  })

  it("fits asymmetric role-specific glyph extents when containment and separation are feasible", () => {
    const scene = {
      bounds: {minX: 0, minY: 0, maxX: 1000, maxY: 100},
      nodes: [
        {id: "summary", center: {x: 100, y: 50}, width: 1, height: 1},
        {id: "member", center: {x: 900, y: 50}, width: 1, height: 1},
      ],
      groups: [],
      routes: [],
    }
    const viewport = {width: 300, height: 180, minZoom: -8, maxZoom: 5}
    const safeRect = {left: 20, top: 20, right: 280, bottom: 160}
    const glyphBoxes = [
      {nodeId: "summary", width: 130, height: 90},
      {nodeId: "member", width: 40, height: 40},
    ]

    const {viewState} = fitTopologyScene({scene, viewport, safeRect, glyphBoxes})
    const projected = projectedSceneBounds(scene, viewState, viewport, glyphBoxes)

    expect(projected.left).toBeGreaterThanOrEqual(safeRect.left - 1)
    expect(projected.right).toBeLessThanOrEqual(safeRect.right + 1)
    expect(intersectByMoreThanOnePixel(projected.glyphs[0], projected.glyphs[1])).toBe(false)
  })

  it("fits the live containment scale without promoting the glyph-separation scale to a camera floor", () => {
    const containmentScale = 0.019548
    const glyphWidth = 20
    const worldSpan = (1000 - glyphWidth) / containmentScale
    const nodes = Array.from({length: 100}, (_unused, index) => ({
      id: `dense-${index}`,
      center: {x: (worldSpan * index) / 99, y: 50},
      width: 0,
      height: 0,
    }))
    const scene = {
      bounds: {minX: 0, minY: 0, maxX: worldSpan, maxY: 100},
      nodes,
      groups: [],
      routes: [],
    }

    const result = fitTopologyScene({
      scene,
      viewport: {width: 1000, height: 300, minZoom: -12, maxZoom: 5},
      safeRect: {left: 0, top: 0, right: 1000, bottom: 300},
      glyphBoxes: nodes.map((node) => ({nodeId: node.id, width: glyphWidth, height: glyphWidth})),
      minimumScale: 0.089285,
    })

    expect(result.ok).toBe(true)
    expect(2 ** result.fitZoom).toBeCloseTo(containmentScale, 6)
    expect(result.viewState.minZoom).toBeLessThanOrEqual(result.fitZoom)
  })

  it.each([
    {name: "landscape", viewport: {width: 1200, height: 600}, bounds: {maxX: 12_000, maxY: 2_000}},
    {name: "portrait", viewport: {width: 600, height: 1200}, bounds: {maxX: 2_000, maxY: 12_000}},
  ])("contains every node, route, and label-safe envelope after idempotent $name Fit", ({viewport, bounds}) => {
    const safeRect = {left: 40, top: 50, right: viewport.width - 80, bottom: viewport.height - 90}
    const scene = {
      bounds: {minX: 0, minY: 0, ...bounds},
      nodes: [
        {id: "alpha", center: {x: 0, y: 0}, width: 0, height: 0},
        {id: "omega", center: {x: bounds.maxX, y: bounds.maxY}, width: 0, height: 0},
      ],
      groups: [],
      routes: [{
        id: "alpha-omega",
        strokeWidth: 12,
        points: [{x: 0, y: 0}, {x: bounds.maxX / 2, y: bounds.maxY / 2}, {x: bounds.maxX, y: bounds.maxY}],
      }],
    }
    const glyphBoxes = scene.nodes.map((node) => ({nodeId: node.id, width: 40, height: 40}))
    const admitLabels = ({projectedGlyphBoxes, safeRect: admissionRect}) => admitTopologyLabels({
      candidates: projectedGlyphBoxes.map((glyph) => ({
        nodeId: glyph.nodeId,
        text: glyph.nodeId,
        point: [(glyph.left + glyph.right) / 2, (glyph.top + glyph.bottom) / 2],
      })),
      glyphBoxes: projectedGlyphBoxes,
      safeRect: admissionRect,
      requiredLabelIds: ["omega", "alpha"],
      measureText: () => ({width: 56, height: 14}),
    })
    const input = {
      scene,
      viewport: {...viewport, minZoom: -3, maxZoom: 5},
      safeRect,
      glyphBoxes,
      routeStrokeWidth: 12,
      admitLabels,
    }

    const first = fitTopologyScene(input)
    const second = fitTopologyScene(input)

    expect(first.ok).toBe(true)
    expect(second.ok).toBe(true)
    expect(second.fitZoom).toBeCloseTo(first.fitZoom, 12)
    expect(second.viewState.target[0]).toBeCloseTo(first.viewState.target[0], 12)
    expect(second.viewState.target[1]).toBeCloseTo(first.viewState.target[1], 12)
    expect(first.viewState.minZoom).toBeLessThanOrEqual(first.fitZoom)
    expect(first.admittedLabels.map((label) => label.nodeId).sort()).toEqual(["alpha", "omega"])
    expect(first.missingRequiredLabelIds).toEqual([])

    for (const [node, glyph] of scene.nodes.map((node, index) => [node, glyphBoxes[index]])) {
      const [x, y] = project(node.center, first.viewState, viewport)
      expect(x - (glyph.width / 2)).toBeGreaterThanOrEqual(safeRect.left - 1)
      expect(y - (glyph.height / 2)).toBeGreaterThanOrEqual(safeRect.top - 1)
      expect(x + (glyph.width / 2)).toBeLessThanOrEqual(safeRect.right + 1)
      expect(y + (glyph.height / 2)).toBeLessThanOrEqual(safeRect.bottom + 1)
    }
    for (const point of scene.routes[0].points) {
      const [x, y] = project(point, first.viewState, viewport)
      expect(x - 6).toBeGreaterThanOrEqual(safeRect.left - 1)
      expect(y - 6).toBeGreaterThanOrEqual(safeRect.top - 1)
      expect(x + 6).toBeLessThanOrEqual(safeRect.right + 1)
      expect(y + 6).toBeLessThanOrEqual(safeRect.bottom + 1)
    }
    for (const label of first.admittedLabels) {
      expect(label.box.left).toBeGreaterThanOrEqual(safeRect.left - 1)
      expect(label.box.top).toBeGreaterThanOrEqual(safeRect.top - 1)
      expect(label.box.right).toBeLessThanOrEqual(safeRect.right + 1)
      expect(label.box.bottom).toBeLessThanOrEqual(safeRect.bottom + 1)
    }
  })

  it("returns deterministic missing required label IDs as semantic infeasibility", () => {
    const result = fitTopologyScene({
      scene: {
        bounds: {minX: 0, minY: 0, maxX: 100, maxY: 100},
        nodes: [{id: "alpha", center: {x: 50, y: 50}, width: 0, height: 0}],
        groups: [],
        routes: [],
      },
      viewport: {width: 100, height: 100, minZoom: -8, maxZoom: 5},
      safeRect: {left: 0, top: 0, right: 100, bottom: 100},
      glyphBoxes: [{nodeId: "alpha", width: 20, height: 20}],
      admitLabels: () => ({admitted: [], missingRequiredLabelIds: ["zeta", "alpha"]}),
    })

    expect(result.ok).toBe(false)
    expect(result.admittedLabels).toEqual([])
    expect(result.missingRequiredLabelIds).toEqual(["alpha", "zeta"])
  })

  it("keeps fixed-pixel routed stroke extents inside the safe rectangle", () => {
    const scene = {
      bounds: {minX: 0, minY: 0, maxX: 1000, maxY: 500},
      nodes: [],
      groups: [],
      routes: [{
        id: "boundary-route",
        sourceId: "left",
        targetId: "right",
        strokeWidth: 40,
        points: [{x: 0, y: 0}, {x: 1000, y: 0}, {x: 1000, y: 500}],
      }],
    }
    const viewport = {width: 1000, height: 700, minZoom: -3, maxZoom: 5}
    const safeRect = {left: 40, top: 30, right: 820, bottom: 610}

    const {viewState} = fitTopologyScene({scene, viewport, safeRect})
    const first = project(scene.routes[0].points[0], viewState, viewport)
    const last = project(scene.routes[0].points.at(-1), viewState, viewport)

    expect(first[0] - 20).toBeGreaterThanOrEqual(safeRect.left - 1)
    expect(first[1] - 20).toBeGreaterThanOrEqual(safeRect.top - 1)
    expect(last[0] + 20).toBeLessThanOrEqual(safeRect.right + 1)
    expect(last[1] + 20).toBeLessThanOrEqual(safeRect.bottom + 1)
  })

  it("fits against the renderer-declared managed route width", () => {
    const scene = {
      bounds: {minX: 0, minY: 0, maxX: 1000, maxY: 100},
      nodes: [],
      groups: [],
      routes: [{sourceId: "left", targetId: "right", points: [{x: 0, y: 50}, {x: 1000, y: 50}]}],
    }
    const viewport = {width: 120, height: 200, minZoom: -8, maxZoom: 5}
    const safeRect = {left: 0, top: 0, right: 120, bottom: 200}

    const overview = fitTopologyScene({scene, viewport, safeRect, routeStrokeWidth: 10})
    const legacy = fitTopologyScene({scene, viewport, safeRect})

    expect(2 ** overview.viewState.zoom).toBeCloseTo(0.11, 6)
    expect(overview.viewState.zoom).toBeGreaterThan(legacy.viewState.zoom)
  })

  it("lowers the effective Deck camera bound to fit a 10,000-unit accepted route", () => {
    const scene = {
      bounds: {minX: 0, minY: 0, maxX: 10_000, maxY: 500},
      nodes: [],
      groups: [],
      routes: [{
        id: "long-route",
        strokeWidth: 40,
        points: [{x: 0, y: 0}, {x: 10_000, y: 500}],
      }],
    }
    const viewport = {width: 1000, height: 700, minZoom: -3, maxZoom: 5}
    const safeRect = {left: 40, top: 30, right: 820, bottom: 610}

    const {viewState} = fitTopologyScene({scene, viewport, safeRect})
    const first = project(scene.routes[0].points[0], viewState, viewport)
    const last = project(scene.routes[0].points.at(-1), viewState, viewport)

    expect(viewState.zoom).toBeLessThan(-3)
    expect(viewState.minZoom).toBeLessThanOrEqual(viewState.zoom)
    expect(first[0] - 20).toBeGreaterThanOrEqual(safeRect.left - 1)
    expect(first[1] - 20).toBeGreaterThanOrEqual(safeRect.top - 1)
    expect(last[0] + 20).toBeLessThanOrEqual(safeRect.right + 1)
    expect(last[1] + 20).toBeLessThanOrEqual(safeRect.bottom + 1)
  })

  it("reports a fit as infeasible when fixed-pixel visuals exceed the safe rectangle", () => {
    const scene = {
      bounds: {minX: 0, minY: 0, maxX: 1, maxY: 1},
      nodes: [{id: "oversized", center: {x: 0.5, y: 0.5}, width: 1, height: 1}],
      groups: [],
      routes: [],
    }

    expect(() => fitTopologyScene({
      scene,
      viewport: {width: 320, height: 260, minZoom: -3, maxZoom: 5},
      safeRect: {left: 20, top: 20, right: 120, bottom: 120},
      glyphBoxes: [{nodeId: "oversized", width: 140, height: 40}],
    })).toThrow(/cannot fit/i)
  })

  it("focuses only a selected group, its anchor, and its trunk route", () => {
    const scene = expandedScene()
    scene.nodes.push({id: "unrelated", center: {x: 4200, y: 1800}, width: 112, height: 112})
    scene.bounds = {minX: 0, minY: 0, maxX: 4256, maxY: 1856}
    const viewport = {width: 1000, height: 700, minZoom: -3, maxZoom: 5}
    const safeRect = {left: 40, top: 30, right: 820, bottom: 610}

    const {viewState} = focusTopologyGroup({
      scene,
      groupId: "group-a",
      viewport,
      safeRect,
      glyphBoxForNode: (node) => ({nodeId: node.id, width: 52, height: 52}),
    })
    const group = scene.groups[0]
    const groupTopLeft = project({x: group.bounds.minX, y: group.bounds.minY}, viewState, viewport)
    const groupBottomRight = project({x: group.bounds.maxX, y: group.bounds.maxY}, viewState, viewport)
    const anchor = project(scene.nodes[0].center, viewState, viewport)
    const unrelated = project(scene.nodes.at(-1).center, viewState, viewport)

    expect(groupTopLeft[0]).toBeGreaterThanOrEqual(safeRect.left - 1)
    expect(groupTopLeft[1]).toBeGreaterThanOrEqual(safeRect.top - 1)
    expect(groupBottomRight[0]).toBeLessThanOrEqual(safeRect.right + 1)
    expect(groupBottomRight[1]).toBeLessThanOrEqual(safeRect.bottom + 1)
    expect(anchor[0]).toBeGreaterThanOrEqual(safeRect.left - 1)
    expect(anchor[1]).toBeGreaterThanOrEqual(safeRect.top - 1)
    expect(unrelated[0]).toBeGreaterThan(safeRect.right + 1000)
  })

  it("returns a structured successful focus result", () => {
    const result = focusTopologyGroup({
      scene: expandedScene(),
      groupId: "group-a",
      viewport: {width: 1000, height: 700, minZoom: -3, maxZoom: 5},
      safeRect: {left: 40, top: 30, right: 820, bottom: 610},
      glyphBoxForNode: (node) => ({nodeId: node.id, width: 52, height: 52}),
    })

    expect(result).toMatchObject({
      ok: true,
      fitZoom: expect.any(Number),
      admittedLabels: [],
      missingRequiredLabelIds: [],
      viewState: {target: expect.any(Array), zoom: expect.any(Number)},
    })
  })

  it("degrades focus for an unbounded expanded neighborhood instead of failing closed", () => {
    // Focusing an expanded cluster frames a set whose size the operator chose by expanding
    // it -- a 24-member cluster cannot label every member at any viewport. The caller marks
    // that case so focus still returns a usable camera, with the ids it could not place left
    // observable, rather than refusing to render the neighborhood at all.
    const result = focusTopologyGroup({
      scene: expandedScene(),
      groupId: "group-a",
      viewport: {width: 1000, height: 700, minZoom: -3, maxZoom: 5},
      safeRect: {left: 40, top: 30, right: 820, bottom: 610},
      glyphBoxForNode: (node) => ({nodeId: node.id, width: 52, height: 52}),
      admitLabels: () => ({
        admitted: [],
        missingRequiredLabelIds: ["zeta", "alpha", "zeta"],
      }),
      degradeUnplaceableLabels: true,
    })

    expect(result).toMatchObject({
      ok: false,
      missingRequiredLabelIds: ["alpha", "zeta"],
      viewState: {target: expect.any(Array), zoom: expect.any(Number)},
    })
  })

  it("fails focus closed with deterministic missing required label IDs", () => {
    expect(() => focusTopologyGroup({
      scene: expandedScene(),
      groupId: "group-a",
      viewport: {width: 1000, height: 700, minZoom: -3, maxZoom: 5},
      safeRect: {left: 40, top: 30, right: 820, bottom: 610},
      glyphBoxForNode: (node) => ({nodeId: node.id, width: 52, height: 52}),
      admitLabels: () => ({
        admitted: [],
        missingRequiredLabelIds: ["zeta", "alpha", "zeta"],
      }),
    })).toThrow(/topology focus.*missing required labels.*alpha, zeta/i)
  })

  it("includes every selected-member branch and its associated manifold paths in focus geometry", () => {
    const scene = expandedScene()
    const memberRoute = {
      id: "member-link",
      sourceId: "member-top",
      targetId: "member-bottom",
      sourceManifoldId: "manifold:member-top:source",
      points: [{x: 920, y: 144}, {x: 920, y: 376}],
    }
    const manifoldRail = {
      id: "manifold:member-top:source:rail",
      sourceId: "member-top",
      targetId: "member-top",
      auxiliary: true,
      semanticRouteIds: ["member-link"],
      points: [{x: 880, y: 120}, {x: 960, y: 120}],
    }
    scene.routes.push(memberRoute)
    scene.physicalRoutes = [...scene.routes, manifoldRail]
    scene.manifolds = [{id: "manifold:member-top:source", semanticRouteIds: ["member-link"]}]

    const focused = topologyGroupFocusScene(scene, "group-a")

    expect(focused.routes.map((route) => route.id).sort()).toEqual(["member-link", "trunk"])
    expect(focused.physicalRoutes.map((route) => route.id).sort()).toEqual([
      "manifold:member-top:source:rail",
      "member-link",
      "trunk",
    ])
    expect(focused.manifolds.map((manifold) => manifold.id)).toEqual([
      "manifold:member-top:source",
    ])
  })

  it("fits every anchor-incident external glyph, physical path, and admitted label in the focused neighborhood", () => {
    const scene = expandedScene()
    const external = {id: "external-gateway", center: {x: 4000, y: 250}, width: 112, height: 112}
    const externalRoute = {
      id: "anchor-external",
      sourceId: "anchor",
      targetId: external.id,
      points: [{x: 136, y: 250}, {x: 3944, y: 250}],
    }
    const externalRail = {
      id: "manifold:external-gateway:target:rail",
      sourceId: external.id,
      targetId: external.id,
      auxiliary: true,
      semanticRouteIds: [externalRoute.id],
      points: [{x: 3944, y: 100}, {x: 3944, y: 400}],
    }
    scene.nodes.push(external)
    scene.routes.push(externalRoute)
    scene.physicalRoutes = [...scene.routes, externalRail]
    scene.manifolds = [{id: "manifold:external-gateway:target", semanticRouteIds: [externalRoute.id]}]

    const focused = topologyGroupFocusScene(scene, "group-a")

    expect(focused.nodes.map((node) => node.id)).toContain(external.id)
    expect(focused.routes.map((route) => route.id)).toContain(externalRoute.id)
    expect(focused.physicalRoutes.map((route) => route.id)).toContain(externalRail.id)
    expect(focused.manifolds.map((manifold) => manifold.id)).toContain(
      "manifold:external-gateway:target",
    )

    const viewport = {width: 1800, height: 700, minZoom: -8, maxZoom: 5}
    const safeRect = {left: 40, top: 30, right: 1700, bottom: 610}
    let admittedLabel = null
    const {viewState} = focusTopologyGroup({
      scene,
      groupId: "group-a",
      viewport,
      safeRect,
      glyphBoxForNode: (node) => ({nodeId: node.id, width: 52, height: 52}),
      routeStrokeWidth: 10,
      admitLabels: ({scene: neighborhood, viewState: candidate}) => {
        if (!neighborhood.nodes.some((node) => node.id === external.id)) return []
        const [x, y] = project(external.center, candidate, viewport)
        admittedLabel = {nodeId: external.id, box: {left: x + 30, top: y - 9, right: x + 190, bottom: y + 9}}
        return [admittedLabel]
      },
    })

    for (const node of focused.nodes.filter((candidate) => candidate.render !== false)) {
      const [x, y] = project(node.center, viewState, viewport)
      expect(x - 26).toBeGreaterThanOrEqual(safeRect.left - 1)
      expect(y - 26).toBeGreaterThanOrEqual(safeRect.top - 1)
      expect(x + 26).toBeLessThanOrEqual(safeRect.right + 1)
      expect(y + 26).toBeLessThanOrEqual(safeRect.bottom + 1)
    }
    for (const route of focused.physicalRoutes) {
      for (const point of route.points) {
        const [x, y] = project(point, viewState, viewport)
        expect(x - 5).toBeGreaterThanOrEqual(safeRect.left - 1)
        expect(y - 5).toBeGreaterThanOrEqual(safeRect.top - 1)
        expect(x + 5).toBeLessThanOrEqual(safeRect.right + 1)
        expect(y + 5).toBeLessThanOrEqual(safeRect.bottom + 1)
      }
    }
    expect(admittedLabel).toBeTruthy()
    expect(admittedLabel.box.left).toBeGreaterThanOrEqual(safeRect.left - 1)
    expect(admittedLabel.box.top).toBeGreaterThanOrEqual(safeRect.top - 1)
    expect(admittedLabel.box.right).toBeLessThanOrEqual(safeRect.right + 1)
    expect(admittedLabel.box.bottom).toBeLessThanOrEqual(safeRect.bottom + 1)
  })

  it("excludes a non-rendered neighborhood node from focus glyph feasibility", () => {
    const scene = expandedScene()
    scene.nodes.push({
      id: "hidden-summary",
      center: {...scene.nodes[1].center},
      width: 1,
      height: 1,
      groupId: "group-a",
      render: false,
    })
    scene.groups[0].memberIds.push("hidden-summary")

    expect(() => focusTopologyGroup({
      scene,
      groupId: "group-a",
      viewport: {width: 1000, height: 700, minZoom: -3, maxZoom: 5},
      safeRect: {left: 40, top: 30, right: 820, bottom: 610},
      glyphBoxForNode: (node) => ({
        nodeId: node.id,
        width: node.id === "hidden-summary" ? 160 : 52,
        height: node.id === "hidden-summary" ? 160 : 52,
      }),
    })).not.toThrow()
  })

  it("requires focus callers to supply renderer-derived glyph extents", () => {
    expect(() => focusTopologyGroup({
      scene: expandedScene(),
      groupId: "group-a",
      viewport: {width: 1000, height: 700, minZoom: -3, maxZoom: 5},
      safeRect: {left: 40, top: 30, right: 820, bottom: 610},
    })).toThrow(/renderer-derived glyph box/i)
  })

  it("keeps focus containment-first when fixed-pixel glyph separation would conflict", () => {
    const scene = {
      bounds: {minX: 0, minY: 0, maxX: 10_000, maxY: 100},
      nodes: [
        {id: "anchor", center: {x: 0, y: 50}, width: 1, height: 1},
        {id: "gateway", center: {x: 208, y: 50}, width: 1, height: 1, groupId: "dense-group"},
        {id: "far-member", center: {x: 10_000, y: 50}, width: 1, height: 1, groupId: "dense-group"},
      ],
      groups: [{
        id: "dense-group",
        bounds: {minX: 208, minY: 0, maxX: 10_000, maxY: 100},
        anchorId: "anchor",
        gatewayId: "gateway",
        memberIds: ["far-member"],
      }],
      routes: [{
        id: "trunk",
        sourceId: "anchor",
        targetId: "gateway",
        points: [{x: 0, y: 50}, {x: 208, y: 50}],
      }],
    }

    const {viewState} = focusTopologyGroup({
      scene,
      groupId: "dense-group",
      viewport: {width: 1000, height: 300, minZoom: -12, maxZoom: 5},
      safeRect: {left: 0, top: 0, right: 1000, bottom: 300},
      glyphBoxForNode: (node) => ({nodeId: node.id, width: 52, height: 52}),
    })

    expect(viewState.minZoom).toBeLessThanOrEqual(viewState.zoom)
    expect(2 ** viewState.zoom).toBeLessThan(52 / 208)
  })

  it("keeps every focused member, anchor, gateway, and trunk halo inside at low scale", () => {
    const scene = {
      bounds: {minX: 0, minY: 0, maxX: 40_000, maxY: 8_000},
      nodes: [
        {id: "anchor", center: {x: 0, y: 1000}, width: 112, height: 112},
        {id: "gateway", center: {x: 2000, y: 1000}, width: 112, height: 112, groupId: "group-a"},
        {id: "member-edge", center: {x: 10_000, y: 2000}, width: 96, height: 96, groupId: "group-a"},
        {id: "unrelated", center: {x: 40_000, y: 8_000}, width: 112, height: 112},
      ],
      groups: [{
        id: "group-a",
        bounds: {minX: 2000, minY: 0, maxX: 10_000, maxY: 2000},
        anchorId: "anchor",
        gatewayId: "gateway",
        memberIds: ["member-edge"],
      }],
      routes: [{
        id: "trunk",
        sourceId: "anchor",
        targetId: "gateway",
        strokeWidth: 38,
        points: [{x: 0, y: 1000}, {x: 1000, y: 1000}, {x: 2000, y: 1000}],
      }],
    }
    const viewport = {width: 1000, height: 700, minZoom: -3, maxZoom: 5}
    const safeRect = {left: 40, top: 30, right: 820, bottom: 610}

    const {viewState} = focusTopologyGroup({
      scene,
      groupId: "group-a",
      viewport,
      safeRect,
      glyphBoxForNode: (node) => ({nodeId: node.id, width: 52, height: 52}),
    })

    expect(viewState.zoom).toBeLessThan(-3)
    for (const nodeId of ["anchor", "gateway", "member-edge"]) {
      const node = scene.nodes.find((candidate) => candidate.id === nodeId)
      const center = project(node.center, viewState, viewport)
      expect(center[0] - 26).toBeGreaterThanOrEqual(safeRect.left - 1)
      expect(center[1] - 26).toBeGreaterThanOrEqual(safeRect.top - 1)
      expect(center[0] + 26).toBeLessThanOrEqual(safeRect.right + 1)
      expect(center[1] + 26).toBeLessThanOrEqual(safeRect.bottom + 1)
    }
    for (const point of scene.routes[0].points) {
      const screen = project(point, viewState, viewport)
      expect(screen[0] - 19).toBeGreaterThanOrEqual(safeRect.left - 1)
      expect(screen[1] - 19).toBeGreaterThanOrEqual(safeRect.top - 1)
      expect(screen[0] + 19).toBeLessThanOrEqual(safeRect.right + 1)
      expect(screen[1] + 19).toBeLessThanOrEqual(safeRect.bottom + 1)
    }
  })
})

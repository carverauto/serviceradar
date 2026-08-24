import {describe, expect, it, vi} from "vitest"

import {
  fitTopologyScene,
  focusTopologyGroup,
  measureGodViewSafeRect,
  normalizeGodViewSafeRect,
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

  it("rejects the dense long-span scene when containment requires overlapping fixed-pixel glyphs", () => {
    const nodes = Array.from({length: 100}, (_unused, index) => ({
      id: `dense-${index}`,
      center: {x: index * 208, y: 50},
      width: 1,
      height: 1,
    }))
    const scene = {
      bounds: {minX: 0, minY: 0, maxX: 99 * 208, maxY: 100},
      nodes,
      groups: [],
      routes: [],
    }

    expect(() => fitTopologyScene({
      scene,
      viewport: {width: 1000, height: 300, minZoom: -12, maxZoom: 5},
      safeRect: {left: 0, top: 0, right: 1000, bottom: 300},
      glyphBoxes: nodes.map((node) => ({nodeId: node.id, width: 52, height: 52})),
    })).toThrow(/glyph separation.*dense-0.*dense-1.*axis=x.*requires scale=.*available containment scale=/i)
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

    const viewState = focusTopologyGroup({
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

  it("rejects focus when complete group containment would overlap rendered glyphs", () => {
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

    expect(() => focusTopologyGroup({
      scene,
      groupId: "dense-group",
      viewport: {width: 1000, height: 300, minZoom: -12, maxZoom: 5},
      safeRect: {left: 0, top: 0, right: 1000, bottom: 300},
      glyphBoxForNode: (node) => ({nodeId: node.id, width: 52, height: 52}),
    })).toThrow(/glyph separation.*anchor.*gateway.*requires scale=.*available containment scale=/i)
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

    const viewState = focusTopologyGroup({
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

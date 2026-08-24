import {describe, expect, it, vi} from "vitest"

import {
  fitTopologyScene,
  focusTopologyGroup,
  measureGodViewSafeRect,
} from "./rendering_scene_view"

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

  it("fits complete expanded scene visuals and admitted labels in at most two idempotent passes", () => {
    const scene = expandedScene()
    const viewport = {width: 1000, height: 700, minZoom: -3, maxZoom: 5}
    const safeRect = {left: 40, top: 30, right: 820, bottom: 610}
    const glyphBoxes = scene.nodes.map((node) => ({nodeId: node.id, width: 52, height: 52}))
    const admitLabels = vi.fn(({viewState, projectedGlyphBoxes}) => {
      const glyph = projectedGlyphBoxes.find((item) => item.nodeId === "member-top")
      return {
        admitted: [{
          nodeId: "member-top",
          anchor: "right",
          box: {left: glyph.right + 4, top: glyph.top, right: glyph.right + 124, bottom: glyph.top + 24},
          pixelOffset: [30, 0],
          textAnchor: "start",
          alignmentBaseline: "center",
        }],
        viewState,
      }
    })
    const input = {scene, viewport, safeRect, glyphBoxes, admitLabels}

    const first = fitTopologyScene(input)
    const second = fitTopologyScene({...input, previous: first})
    const projected = projectedSceneBounds(scene, first.viewState, viewport, glyphBoxes)

    expect(second).toEqual(first)
    expect(admitLabels).toHaveBeenCalledTimes(4)
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

  it("focuses only a selected group, its anchor, and its trunk route", () => {
    const scene = expandedScene()
    scene.nodes.push({id: "unrelated", center: {x: 4200, y: 1800}, width: 112, height: 112})
    scene.bounds = {minX: 0, minY: 0, maxX: 4256, maxY: 1856}
    const viewport = {width: 1000, height: 700, minZoom: -3, maxZoom: 5}
    const safeRect = {left: 40, top: 30, right: 820, bottom: 610}

    const viewState = focusTopologyGroup({scene, groupId: "group-a", viewport, safeRect})
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
})

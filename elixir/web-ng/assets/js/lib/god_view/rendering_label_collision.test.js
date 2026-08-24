import {describe, expect, it} from "vitest"

import {admitTopologyLabels} from "./rendering_label_collision"

function intersects(left, right) {
  return left.left < right.right && left.right > right.left && left.top < right.bottom && left.bottom > right.top
}

function pairwiseIntersections(items) {
  const intersections = []
  for (let leftIndex = 0; leftIndex < items.length; leftIndex += 1) {
    for (let rightIndex = leftIndex + 1; rightIndex < items.length; rightIndex += 1) {
      if (intersects(items[leftIndex].box, items[rightIndex].box)) {
        intersections.push([items[leftIndex].nodeId, items[rightIndex].nodeId])
      }
    }
  }
  return intersections
}

function distanceToSegment(point, start, end) {
  const dx = end[0] - start[0]
  const dy = end[1] - start[1]
  const lengthSquared = (dx * dx) + (dy * dy)
  const projection = lengthSquared === 0
    ? 0
    : Math.max(0, Math.min(1, (((point[0] - start[0]) * dx) + ((point[1] - start[1]) * dy)) / lengthSquared))
  return Math.hypot(point[0] - (start[0] + (projection * dx)), point[1] - (start[1] + (projection * dy)))
}

function boxIntersectsCorridor(box, corridor) {
  const points = corridor.points
  const radius = corridor.strokeWidth / 2
  for (let index = 1; index < points.length; index += 1) {
    const start = points[index - 1]
    const end = points[index]
    const samples = [
      [box.left, box.top],
      [box.right, box.top],
      [box.left, box.bottom],
      [box.right, box.bottom],
      [Math.max(box.left, Math.min(box.right, start[0])), Math.max(box.top, Math.min(box.bottom, start[1]))],
      [Math.max(box.left, Math.min(box.right, end[0])), Math.max(box.top, Math.min(box.bottom, end[1]))],
    ]
    if (samples.some((point) => distanceToSegment(point, start, end) < radius)) return true
    if (
      Math.min(start[0], end[0]) < box.right && Math.max(start[0], end[0]) > box.left &&
      Math.min(start[1], end[1]) < box.bottom && Math.max(start[1], end[1]) > box.top
    ) return true
  }
  return false
}

function denseExpandedLabelCase() {
  const candidates = Array.from({length: 24}, (_, index) => {
    const column = index % 6
    const row = Math.floor(index / 6)
    return {
      nodeId: `member-${String(index).padStart(2, "0")}`,
      text: `host-${String(index).padStart(2, "0")}`,
      point: [80 + (column * 80), 70 + (row * 70)],
      role: "member",
      operationalRelevance: 24 - index,
      fontSize: 12,
    }
  })
  const glyphBoxes = candidates.map((candidate) => ({
    nodeId: candidate.nodeId,
    left: candidate.point[0] - 10,
    right: candidate.point[0] + 10,
    top: candidate.point[1] - 10,
    bottom: candidate.point[1] + 10,
  }))
  const routeCorridors = [120, 190, 260].map((y) => ({
    points: [[32, y], [528, y]],
    strokeWidth: 6,
  }))

  return {
    candidates,
    glyphBoxes,
    routeCorridors,
    safeRect: {left: 20, top: 20, right: 540, bottom: 330},
    measureText: () => ({width: 44, height: 12}),
  }
}

describe("admitTopologyLabels", () => {
  it("admits the 24-member fixture deterministically without label, glyph, route, or chrome collisions", () => {
    const input = denseExpandedLabelCase()
    const first = admitTopologyLabels(input)
    const reordered = admitTopologyLabels({
      ...input,
      candidates: [...input.candidates].reverse(),
      glyphBoxes: [...input.glyphBoxes].reverse(),
      routeCorridors: [...input.routeCorridors].reverse(),
    })

    expect(first.admitted).toHaveLength(24)
    expect(pairwiseIntersections(first.admitted)).toEqual([])
    expect(first.admitted.every((item) => input.safeRect.left <= item.box.left && item.box.right <= input.safeRect.right)).toBe(true)
    expect(first.admitted.every((item) => input.safeRect.top <= item.box.top && item.box.bottom <= input.safeRect.bottom)).toBe(true)
    expect(first.admitted.every((item) => input.glyphBoxes
      .filter((glyph) => glyph.nodeId !== item.nodeId)
      .every((glyph) => !intersects(item.box, glyph)))).toBe(true)
    expect(first.admitted.every((item) => input.routeCorridors.every((route) => !boxIntersectsCorridor(item.box, route)))).toBe(true)
    expect(first.admitted.map((item) => item.nodeId)).toEqual(
      Array.from({length: 24}, (_, index) => `member-${String(index).padStart(2, "0")}`),
    )
    expect(reordered).toEqual(first)
  })

  it("tries top, right, bottom, and left anchors with exactly four pixels of label padding", () => {
    const result = admitTopologyLabels({
      candidates: [{nodeId: "router", text: "Router", point: [100, 100], role: "infrastructure", fontSize: 12}],
      glyphBoxes: [{nodeId: "router", left: 90, top: 90, right: 110, bottom: 110}],
      routeCorridors: [{points: [[70, 80], [130, 80]], strokeWidth: 2}],
      safeRect: {left: 0, top: 0, right: 220, bottom: 220},
      measureText: () => ({width: 40, height: 12}),
    })

    expect(result.admitted).toEqual([{
      nodeId: "router",
      anchor: "right",
      box: {left: 110, top: 90, right: 158, bottom: 110},
      pixelOffset: [14, 0],
      textAnchor: "start",
      alignmentBaseline: "center",
    }])
  })

  it("gives selected labels priority over lower-priority collisions", () => {
    const result = admitTopologyLabels({
      candidates: [
        {nodeId: "ordinary", text: "ordinary", point: [80, 60], role: "infrastructure"},
        {nodeId: "selected", text: "selected", point: [80, 60], role: "member", selected: true},
      ],
      glyphBoxes: [
        {nodeId: "selected", left: 72, top: 52, right: 88, bottom: 68},
      ],
      routeCorridors: [
        {points: [[20, 85], [140, 85]], strokeWidth: 8},
      ],
      safeRect: {left: 10, top: 10, right: 150, bottom: 110},
      measureText: () => ({width: 48, height: 12}),
    })

    expect(result.admitted.map((item) => item.nodeId)).toEqual(["selected"])
    expect(result.detailsFallbackIds).toEqual([])
  })

  it("keeps selected identity in details when every canvas candidate is blocked", () => {
    const result = admitTopologyLabels({
      candidates: [{nodeId: "selected", text: "Selected device", point: [25, 25], selected: true}],
      glyphBoxes: [{nodeId: "selected", left: 5, top: 5, right: 45, bottom: 45}],
      routeCorridors: [],
      safeRect: {left: 0, top: 0, right: 50, bottom: 50},
      measureText: () => ({width: 40, height: 12}),
    })

    expect(result.admitted.some((item) => item.nodeId === "selected")).toBe(false)
    expect(result.detailsFallbackIds).toEqual(["selected"])
  })
})

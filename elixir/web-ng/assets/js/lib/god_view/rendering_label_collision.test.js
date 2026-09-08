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
    expect(first.missingRequiredLabelIds).toEqual([])
    expect(reordered).toEqual(first)
  })

  it("reports every missing required label ID in deterministic order", () => {
    const input = {
      candidates: [
        {nodeId: "ordinary", text: "Ordinary", point: [80, 60], role: "infrastructure"},
        {nodeId: "selected", text: "Selected", point: [80, 60], role: "member", selected: true},
      ],
      glyphBoxes: [
        {nodeId: "selected", left: 72, top: 52, right: 88, bottom: 68},
      ],
      routeCorridors: [
        {points: [[20, 85], [140, 85]], strokeWidth: 8},
      ],
      safeRect: {left: 10, top: 10, right: 150, bottom: 110},
      requiredLabelIds: ["z-missing-candidate", "selected", "ordinary"],
      measureText: () => ({width: 48, height: 12}),
    }

    const first = admitTopologyLabels(input)
    const reordered = admitTopologyLabels({
      ...input,
      candidates: [...input.candidates].reverse(),
      requiredLabelIds: [...input.requiredLabelIds].reverse(),
    })

    expect(first.admitted.map((item) => item.nodeId)).toEqual(["selected"])
    expect(first.missingRequiredLabelIds).toEqual(["ordinary", "z-missing-candidate"])
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

  it("uses a route-clear diagonal for a four-way incident fanout", () => {
    const result = admitTopologyLabels({
      candidates: [{nodeId: "router", text: "Router", point: [100, 100], role: "infrastructure", fontSize: 12}],
      glyphBoxes: [{nodeId: "router", left: 90, top: 90, right: 110, bottom: 110}],
      routeCorridors: [
        {sourceId: "router", targetId: "north", points: [[100, 100], [100, 50]], strokeWidth: 6},
        {sourceId: "router", targetId: "east", points: [[100, 100], [170, 100]], strokeWidth: 6},
        {sourceId: "router", targetId: "south", points: [[100, 100], [100, 150]], strokeWidth: 6},
        {sourceId: "router", targetId: "west", points: [[100, 100], [30, 100]], strokeWidth: 6},
      ],
      safeRect: {left: 0, top: 0, right: 220, bottom: 220},
      requiredLabelIds: ["router"],
      measureText: () => ({width: 40, height: 12}),
    })

    expect(result.missingRequiredLabelIds).toEqual([])
    expect(result.admitted).toMatchObject([{nodeId: "router", anchor: "top-right"}])
    expect(result.admitted.every((item) => result.admitted.length === 1 && [
      {points: [[100, 100], [100, 50]], strokeWidth: 6},
      {points: [[100, 100], [170, 100]], strokeWidth: 6},
      {points: [[100, 100], [100, 150]], strokeWidth: 6},
      {points: [[100, 100], [30, 100]], strokeWidth: 6},
    ].every((route) => !boxIntersectsCorridor(item.box, route)))).toBe(true)
  })

  it("does not exempt an incident route after it leaves and re-enters the owner approach", () => {
    const result = admitTopologyLabels({
      candidates: [{nodeId: "router", text: "Router", point: [100, 100], role: "infrastructure", fontSize: 12}],
      glyphBoxes: [{nodeId: "router", left: 90, top: 90, right: 110, bottom: 110}],
      routeCorridors: [{
        sourceId: "router",
        targetId: "north",
        points: [[100, 100], [100, 40], [150, 40], [150, 80], [100, 80]],
        strokeWidth: 6,
      }],
      // Only the top anchor fits. The route's final segment crosses that label
      // after travelling well beyond the bounded owner approach.
      safeRect: {left: 76, top: 0, right: 124, bottom: 110},
      requiredLabelIds: ["router"],
      measureText: () => ({width: 40, height: 12}),
    })

    expect(result.admitted).toEqual([])
    expect(result.missingRequiredLabelIds).toEqual(["router"])
  })

  it("places a four-way fanout label deterministically when one incident route re-enters", () => {
    const routeCorridors = [
      {
        sourceId: "router",
        targetId: "north",
        points: [[100, 100], [100, 40], [150, 40], [150, 80], [100, 80]],
        strokeWidth: 6,
      },
      {sourceId: "router", targetId: "east", points: [[100, 100], [170, 100]], strokeWidth: 6},
      {sourceId: "router", targetId: "south", points: [[100, 100], [100, 170]], strokeWidth: 6},
      {sourceId: "router", targetId: "west", points: [[100, 100], [30, 100]], strokeWidth: 6},
    ]
    const input = {
      candidates: [{nodeId: "router", text: "Router", point: [100, 100], role: "infrastructure", fontSize: 12}],
      glyphBoxes: [{nodeId: "router", left: 90, top: 90, right: 110, bottom: 110}],
      routeCorridors,
      safeRect: {left: 0, top: 0, right: 220, bottom: 220},
      requiredLabelIds: ["router"],
      measureText: () => ({width: 40, height: 12}),
    }

    const first = admitTopologyLabels(input)
    const reordered = admitTopologyLabels({...input, routeCorridors: [...routeCorridors].reverse()})

    expect(first.missingRequiredLabelIds).toEqual([])
    expect(first.admitted).toMatchObject([{nodeId: "router", anchor: "bottom-right"}])
    expect(first.admitted.every((item) => routeCorridors.every((route) => !boxIntersectsCorridor(item.box, route)))).toBe(true)
    expect(reordered).toEqual(first)
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

  it("backfills blocked priority candidates without exceeding the caller's label budget", () => {
    const candidates = [
      ...Array.from({length: 8}, (_, index) => ({
        nodeId: `blocked-${index}`,
        text: `Blocked ${index}`,
        point: [500, 300],
        role: "infrastructure",
        operationalRelevance: 20 - index,
        fontSize: 10,
      })),
      ...Array.from({length: 12}, (_, index) => ({
        nodeId: `fallback-${index}`,
        text: `Fallback ${index}`,
        point: [60 + ((index % 6) * 170), 60 + (Math.floor(index / 6) * 480)],
        role: "infrastructure",
        operationalRelevance: 10 - index,
        fontSize: 10,
      })),
    ]
    const glyphBoxes = candidates.map((candidate) => ({
      nodeId: candidate.nodeId,
      left: candidate.point[0] - 10,
      top: candidate.point[1] - 10,
      right: candidate.point[0] + 10,
      bottom: candidate.point[1] + 10,
    }))
    const input = {
      candidates,
      glyphBoxes,
      routeCorridors: [
        {points: [[510, 300], [510, 350]], strokeWidth: 10},
        {points: [[450, 310], [550, 310]], strokeWidth: 10},
        {points: [[490, 300], [490, 350]], strokeWidth: 10},
      ],
      safeRect: {left: 0, top: 0, right: 1000, bottom: 600},
      maximumCount: 8,
      measureText: () => ({width: 48, height: 12}),
    }

    const first = admitTopologyLabels(input)
    const reordered = admitTopologyLabels({...input, candidates: [...candidates].reverse()})

    expect(first.admitted).toHaveLength(8)
    expect(first.admitted.map((item) => item.nodeId)).toEqual([
      "blocked-0",
      "fallback-0",
      "fallback-1",
      "fallback-2",
      "fallback-3",
      "fallback-4",
      "fallback-5",
      "fallback-6",
    ])
    expect(pairwiseIntersections(first.admitted)).toEqual([])
    expect(first.admitted.every((item) => input.routeCorridors.every((route) => !boxIntersectsCorridor(item.box, route)))).toBe(true)
    expect(reordered).toEqual(first)
  })

  it("uses a fallback wide enough to prevent full-width Unicode labels from overlapping", () => {
    const result = admitTopologyLabels({
      candidates: [
        {nodeId: "wide-a", text: "Ｗ漢Ｗ漢", point: [100, 100], fontSize: 12},
        {nodeId: "wide-b", text: "Ｗ漢Ｗ漢", point: [148, 100], fontSize: 12},
      ],
      glyphBoxes: [
        {nodeId: "wide-a", left: 90, top: 90, right: 110, bottom: 110},
        {nodeId: "wide-b", left: 138, top: 90, right: 158, bottom: 110},
      ],
      routeCorridors: [],
      safeRect: {left: 0, top: 0, right: 300, bottom: 220},
    })

    expect(result.admitted).toHaveLength(2)
    expect(result.admitted[0].box.right - result.admitted[0].box.left).toBeGreaterThanOrEqual(56)
    expect(pairwiseIntersections(result.admitted)).toEqual([])
    expect(result.admitted.map((item) => item.anchor)).toEqual(["top", "right"])
  })
})

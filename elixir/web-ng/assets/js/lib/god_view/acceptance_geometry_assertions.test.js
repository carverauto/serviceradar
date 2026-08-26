import {describe, expect, it} from "vitest"

import {
  groupGeometryViolations,
  routeInsideSafeRect,
  routeInteriorsIntersect,
  routeStrokeHitsBox,
  routeStrokesOverlap,
  segmentAabbDistance,
  transportLayerRouteIdViolations,
} from "./acceptance_geometry_assertions"

function route({
  sourceId = "a",
  targetId = "b",
  sourceContactId,
  targetContactId,
  junctions = [],
  points = [{x: 0, y: 0}, {x: 10, y: 0}],
  strokeWidth = 38,
} = {}) {
  return {
    sourceId,
    targetId,
    sourceContactId,
    targetContactId,
    junctions,
    points,
    projectedPoints: points,
    strokeWidth,
  }
}

describe("God-View browser geometry assertions", () => {
  const exactTransportSnapshot = () => ({
    scenePhysicalRouteIds: ["rendered:a", "manifold:a:trunk"],
    enabledTransportRouteFamilies: ["mantle", "crust"],
    renderedPhysicalRouteLayers: [
      {layerId: "god-view-edges-mantle", routeCount: 1, routeIds: ["rendered:a"]},
      {layerId: "god-view-edges-mantle-auxiliary", routeCount: 1, routeIds: ["manifold:a:trunk"]},
      {layerId: "god-view-edges-crust", routeCount: 1, routeIds: ["rendered:a"]},
      {layerId: "god-view-edges-crust-auxiliary", routeCount: 1, routeIds: ["manifold:a:trunk"]},
    ],
  })

  it("accepts exactly one rendering of every physical route in mantle and crust", () => {
    expect(transportLayerRouteIdViolations(exactTransportSnapshot())).toEqual([])
  })

  it("rejects a duplicate physical route in the mantle layers", () => {
    const snapshot = exactTransportSnapshot()
    snapshot.renderedPhysicalRouteLayers[0].routeIds.push("rendered:a")
    snapshot.renderedPhysicalRouteLayers[0].routeCount += 1

    expect(transportLayerRouteIdViolations(snapshot)).toEqual([
      "mantle route rendered:a is rendered 2 times; expected 1",
      "mantle and crust route ID multisets differ",
    ])
  })

  it("rejects a physical route omitted from the crust layers", () => {
    const snapshot = exactTransportSnapshot()
    snapshot.renderedPhysicalRouteLayers[2].routeIds = []
    snapshot.renderedPhysicalRouteLayers[2].routeCount = 0

    expect(transportLayerRouteIdViolations(snapshot)).toEqual([
      "crust route rendered:a is rendered 0 times; expected 1",
      "mantle and crust route ID multisets differ",
    ])
  })

  it("measures segment clearance from an AABB instead of only centerline crossing", () => {
    const box = {left: 2, top: 19, right: 8, bottom: 29}

    expect(segmentAabbDistance({x: 0, y: 0}, {x: 10, y: 0}, box)).toBe(19)
    expect(routeStrokeHitsBox(route(), box)).toBe(true)
    expect(routeStrokeHitsBox(route(), {...box, top: 19.1, bottom: 29.1})).toBe(false)
  })

  it("rejects a 38px route whose visible stroke clips the safe rectangle", () => {
    const safeRect = {left: 0, top: 0, right: 100, bottom: 100}

    expect(routeInsideSafeRect(route({points: [{x: 18, y: 40}, {x: 80, y: 40}]}), safeRect)).toBe(false)
    expect(routeInsideSafeRect(route({points: [{x: 19, y: 40}, {x: 80, y: 40}]}), safeRect)).toBe(true)
  })

  it.each([undefined, Number.NaN, 0, -1])("rejects invalid route stroke width %s", (strokeWidth) => {
    const invalidRoute = {...route(), strokeWidth}

    expect(() => routeStrokeHitsBox(invalidRoute, {left: 2, top: 2, right: 8, bottom: 8}))
      .toThrow(/finite positive strokeWidth/)
    expect(() => routeInsideSafeRect({...invalidRoute, projectedPoints: []}, {left: 0, top: 0, right: 100, bottom: 100}))
      .toThrow(/finite positive strokeWidth/)
  })

  it("detects an unrelated route endpoint touching another route interior", () => {
    const horizontal = route({sourceId: "left", targetId: "right"})
    const tee = route({sourceId: "top", targetId: "tee", points: [{x: 5, y: -5}, {x: 5, y: 0}]})

    expect(routeInteriorsIntersect(horizontal, tee)).toBe(true)
  })

  it("allows a manifold branch to meet its rail only at their declared shared junction", () => {
    const rail = route({
      sourceId: "hub",
      targetId: "hub",
      sourceContactId: "rail:start",
      targetContactId: "rail:end",
      junctions: [{id: "rail:branch:one", point: {x: 5, y: 0}}],
    })
    const branch = route({
      sourceId: "hub",
      targetId: "leaf",
      sourceContactId: "rail:branch:one",
      targetContactId: "leaf:port",
      points: [{x: 5, y: 0}, {x: 5, y: 10}],
    })

    expect(routeInteriorsIntersect(rail, branch)).toBe(false)
  })

  it("rejects a manifold branch touching a rail at an undeclared junction", () => {
    const rail = route({
      sourceId: "hub",
      targetId: "hub",
      sourceContactId: "rail:start",
      targetContactId: "rail:end",
    })
    const branch = route({
      sourceId: "hub",
      targetId: "leaf",
      sourceContactId: "rail:branch:one",
      targetContactId: "leaf:port",
      points: [{x: 5, y: 0}, {x: 5, y: 10}],
    })

    expect(routeInteriorsIntersect(rail, branch)).toBe(true)
  })

  it("allows only the shared semantic endpoint coordinate of incident routes", () => {
    const incoming = route({sourceId: "left", targetId: "shared"})
    const outgoing = route({sourceId: "shared", targetId: "bottom", points: [{x: 10, y: 0}, {x: 10, y: 10}]})

    expect(routeInteriorsIntersect(incoming, outgoing)).toBe(false)
  })

  it("rejects incident routes that cross again away from their shared endpoint", () => {
    const first = route({
      sourceId: "left",
      targetId: "shared",
      points: [{x: 0, y: 0}, {x: 10, y: 0}, {x: 10, y: 10}],
    })
    const second = route({
      sourceId: "shared",
      targetId: "bottom",
      points: [{x: 10, y: 10}, {x: 5, y: 0}, {x: 5, y: -5}],
    })

    expect(routeInteriorsIntersect(first, second)).toBe(true)
  })

  it("detects collinear overlap between unrelated route interiors", () => {
    const first = route({sourceId: "left", targetId: "middle"})
    const second = route({
      sourceId: "overlap-start",
      targetId: "overlap-end",
      points: [{x: 5, y: 0}, {x: 15, y: 0}],
    })

    expect(routeInteriorsIntersect(first, second)).toBe(true)
  })

  it("detects visible overlap between close parallel route strokes without a centerline crossing", () => {
    const first = route({
      strokeWidth: 10,
      points: [{x: 0, y: 0}, {x: 100, y: 0}],
    })
    const overlapping = route({
      sourceId: "c",
      targetId: "d",
      strokeWidth: 10,
      points: [{x: 0, y: 8}, {x: 100, y: 8}],
    })
    const clear = {...overlapping, points: [{x: 0, y: 11}, {x: 100, y: 11}], projectedPoints: [{x: 0, y: 11}, {x: 100, y: 11}]}

    expect(routeInteriorsIntersect(first, overlapping)).toBe(false)
    expect(routeStrokesOverlap(first, overlapping)).toBe(true)
    expect(routeStrokesOverlap(first, clear)).toBe(false)
  })

  it("allows visible manifold strokes to join only inside their declared shared junction", () => {
    const rail = route({
      sourceId: "hub",
      targetId: "hub",
      sourceContactId: "rail:start",
      targetContactId: "rail:end",
      strokeWidth: 10,
      points: [{x: 0, y: 0}, {x: 100, y: 0}],
      junctions: [{
        id: "rail:branch:one",
        point: {x: 50, y: 0},
        projectedPoint: {x: 50, y: 0},
      }],
    })
    const branch = route({
      sourceId: "hub",
      targetId: "leaf",
      sourceContactId: "rail:branch:one",
      targetContactId: "leaf:port",
      strokeWidth: 10,
      points: [{x: 50, y: 0}, {x: 50, y: 100}],
    })

    expect(routeStrokesOverlap(rail, branch)).toBe(false)
    expect(routeStrokesOverlap(
      {...rail, junctions: []},
      branch,
    )).toBe(true)
  })

  it("reports group overlap, nonmember overlap, and escaped declared members", () => {
    const snapshot = {
      groups: [
        {id: "group-a", gatewayId: "gateway-a", memberIds: ["member-a"], box: {left: 0, top: 0, right: 100, bottom: 100}},
        {id: "group-b", gatewayId: "gateway-b", memberIds: [], box: {left: 90, top: 90, right: 150, bottom: 150}},
      ],
      nodes: [
        {id: "gateway-a", groupId: "group-a", box: {left: 10, top: 10, right: 20, bottom: 20}},
        {id: "member-a", groupId: "group-a", box: {left: 95, top: 95, right: 105, bottom: 105}},
        {id: "gateway-b", groupId: "group-b", box: {left: 110, top: 110, right: 120, bottom: 120}},
        {id: "outsider", groupId: null, box: {left: 80, top: 90, right: 110, bottom: 100}},
      ],
    }

    expect(groupGeometryViolations(snapshot)).toEqual([
      "groups group-a and group-b overlap",
      "group group-a overlaps nonmember outsider",
      "declared member member-a is outside group group-a",
      "group group-b overlaps nonmember member-a",
      "group group-b overlaps nonmember outsider",
    ])
  })

  it("excludes only explicitly declared nested groups and their nodes", () => {
    const snapshot = {
      groups: [
        {id: "outer", gatewayId: "", memberIds: [], box: {left: 0, top: 0, right: 100, bottom: 100}},
        {id: "inner", parentGroupId: "outer", gatewayId: "inner-node", memberIds: [], box: {left: 20, top: 20, right: 80, bottom: 80}},
      ],
      nodes: [{id: "inner-node", groupId: "inner", box: {left: 30, top: 30, right: 40, bottom: 40}}],
    }

    expect(groupGeometryViolations(snapshot)).toEqual([])
  })
})

import {describe, expect, it} from "vitest"

import {backboneEmptyState, edgeClassCounts, formatEdgeClassStatus} from "./topology_class_stats"

describe("topology_class_stats", () => {
  it("edgeClassCounts returns null without stats or class keys", () => {
    expect(edgeClassCounts(null)).toBeNull()
    expect(edgeClassCounts(undefined)).toBeNull()
    expect(edgeClassCounts("nope")).toBeNull()
    expect(edgeClassCounts({final_edges: 12, final_attachment: 3})).toBeNull()
  })

  it("edgeClassCounts normalizes numeric and string counts", () => {
    const counts = edgeClassCounts({
      edge_class_backbone: 4,
      edge_class_attachment: "57",
      edge_class_inferred: 12,
      edge_class_hosted: "3",
      edge_class_observed: -1,
    })

    expect(counts).toEqual({backbone: 4, attachment: 57, inferred: 12, hosted: 3, observed: 0})
  })

  it("edgeClassCounts prefers backbone_edge_count when present", () => {
    const counts = edgeClassCounts({backbone_edge_count: 0, edge_class_backbone: 9})
    expect(counts.backbone).toEqual(0)
  })

  it("backboneEmptyState fires only when backbone is zero and other classes exist", () => {
    expect(
      backboneEmptyState({backbone_edge_count: 0, edge_class_attachment: 57, edge_class_inferred: 12}),
    ).toEqual(true)
    expect(backboneEmptyState({backbone_edge_count: 0, edge_class_hosted: 1})).toEqual(true)
    expect(backboneEmptyState({backbone_edge_count: 8, edge_class_attachment: 57})).toEqual(false)
    expect(backboneEmptyState({backbone_edge_count: 0})).toEqual(false)
    expect(backboneEmptyState({final_edges: 42})).toEqual(false)
    expect(backboneEmptyState(null)).toEqual(false)
  })

  it("formatEdgeClassStatus renders a compact status fragment with an empty marker", () => {
    expect(
      formatEdgeClassStatus({
        backbone_edge_count: 0,
        edge_class_backbone: 0,
        edge_class_attachment: 57,
        edge_class_inferred: 12,
        edge_class_hosted: 3,
        edge_class_observed: 2,
      }),
    ).toEqual("classes=bb:0/att:57/inf:12/host:3/obs:2 backbone=EMPTY")

    expect(
      formatEdgeClassStatus({
        backbone_edge_count: 8,
        edge_class_backbone: 8,
        edge_class_attachment: 4,
        edge_class_inferred: 0,
        edge_class_hosted: 0,
        edge_class_observed: 0,
      }),
    ).toEqual("classes=bb:8/att:4/inf:0/host:0/obs:0")

    expect(formatEdgeClassStatus(null)).toEqual("")
    expect(formatEdgeClassStatus({final_edges: 7})).toEqual("")
  })
})

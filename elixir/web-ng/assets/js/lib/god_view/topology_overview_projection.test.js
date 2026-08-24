import {describe, expect, it} from "vitest"

import {collapsedFarm01Graph, reverseGraphArrays} from "./fixtures/farm01_topology_regression"
import {prepareTopologyOverviewInput} from "./topology_overview_projection"

describe("topology_overview_projection", () => {
  it("is invariant under shuffled farm01 input", () => {
    const forward = prepareTopologyOverviewInput(collapsedFarm01Graph())
    const shuffled = prepareTopologyOverviewInput(reverseGraphArrays(collapsedFarm01Graph()))

    expect(shuffled.graphKey).toEqual(forward.graphKey)
    expect(shuffled.nodes).toEqual(forward.nodes)
    expect(shuffled.treeRelations).toEqual(forward.treeRelations)
    expect(shuffled.crossLinks).toEqual(forward.crossLinks)
    expect(shuffled.roots).toEqual(forward.roots)
  })

  it("projects farm01 into a spanning infrastructure forest with census leaves", () => {
    const overview = prepareTopologyOverviewInput(collapsedFarm01Graph())

    expect(overview.nodes).toHaveLength(12)
    expect(overview.nodes.filter((node) => node.role === "infrastructure")).toHaveLength(6)
    expect(overview.nodes.filter((node) => node.role === "summary")).toHaveLength(6)
    expect(overview.treeRelations).toHaveLength(11)
    expect(overview.crossLinks).toHaveLength(3)
    expect(overview.manifest).toMatchObject({
      glyphs: 12,
      infrastructureNodes: 6,
      collapsedSummaries: 6,
      treeRelations: 11,
      crossLinks: 3,
      omittedAttachmentNodes: 18,
      components: 1,
      semanticNodes: 12,
    })
    expect(overview.synthetic).toEqual({nodeIds: [], relationIds: []})
    expect(overview.roots).toEqual(["farm01:gateway-01"])
  })

  it("selects two trusted cycle edges and preserves the rejected pair as a cross-link", () => {
    const overview = prepareTopologyOverviewInput({
      nodes: [
        {id: "gamma", details: {topology_plane: "backbone"}},
        {id: "alpha", details: {topology_plane: "backbone"}},
        {id: "beta", details: {topology_plane: "backbone"}},
      ],
      edges: [
        {id: "gamma-alpha", source: 0, target: 1, topologyClass: "backbone", evidenceClass: "direct"},
        {id: "alpha-beta", source: 1, target: 2, topologyClass: "backbone", evidenceClass: "direct"},
        {id: "beta-gamma", source: 2, target: 0, topologyClass: "backbone", evidenceClass: "direct"},
      ],
    })

    expect(overview.roots).toEqual(["alpha"])
    expect(overview.treeRelations.map((relation) => [relation.sourceId, relation.targetId])).toEqual([
      ["alpha", "beta"],
      ["alpha", "gamma"],
    ])
    expect(overview.crossLinks).toEqual([expect.objectContaining({
      pairId: "overview:pair:beta|gamma",
      semanticRelationIds: ["beta-gamma"],
    })])
  })

  it("adds an ELK-only super-root for disconnected components without including it in the semantic manifest", () => {
    const overview = prepareTopologyOverviewInput({
      nodes: [
        {id: "bravo", details: {topology_plane: "backbone"}},
        {id: "alpha", details: {topology_plane: "backbone"}},
        {id: "delta", details: {topology_plane: "backbone"}},
        {id: "charlie", details: {topology_plane: "backbone"}},
      ],
      edges: [
        {id: "bravo-alpha", source: 0, target: 1, topologyClass: "backbone"},
        {id: "delta-charlie", source: 2, target: 3, topologyClass: "backbone"},
      ],
    })

    expect(overview.roots).toEqual(["alpha", "charlie"])
    expect(overview.nodes).toContainEqual(expect.objectContaining({id: "overview:super-root", synthetic: true, width: 0, height: 0}))
    expect(overview.synthetic).toEqual({
      nodeIds: ["overview:super-root"],
      relationIds: ["overview:super-root|alpha", "overview:super-root|charlie"],
    })
    expect(overview.treeRelations.slice(-2)).toEqual([
      expect.objectContaining({id: "overview:super-root|alpha", sourceId: "overview:super-root", targetId: "alpha", synthetic: true}),
      expect.objectContaining({id: "overview:super-root|charlie", sourceId: "overview:super-root", targetId: "charlie", synthetic: true}),
    ])
    expect(overview.manifest).toMatchObject({semanticNodes: 4, components: 2})
    expect(overview.manifest.nodeIds).not.toContain("overview:super-root")
  })

  it("omits malformed and self-loop input while aggregating duplicate semantic evidence deterministically", () => {
    const graph = {
      nodes: [
        {id: " beta ", details: {topology_plane: "backbone"}},
        {id: "alpha", details: {topology_plane: "backbone"}},
        {id: "attachment", details: {topology_plane: "attachment"}},
        {id: "", details: {topology_plane: "backbone"}},
      ],
      edges: [
        {id: "z-duplicate", source: 0, target: 1, topologyClass: "observed", evidenceClass: "observed", metadata: {seen: "late"}},
        {id: "a-duplicate", source: 1, target: 0, topologyClass: "backbone", evidenceClass: "direct", metadata: {seen: "early"}},
        {id: "self-loop", source: 0, target: 0, topologyClass: "backbone"},
        {id: "missing-endpoint", source: 1, target: 12, topologyClass: "backbone"},
        {id: "attachment-only", source: 0, target: 2, topologyClass: "endpoints", evidenceClass: "endpoint-attachment"},
      ],
    }
    const overview = prepareTopologyOverviewInput(graph)
    const relation = overview.treeRelations.find((candidate) => candidate.pairId === "overview:pair:alpha|beta")

    expect(overview.nodes.map((node) => node.id)).toEqual(["alpha", "beta"])
    expect(relation).toMatchObject({semanticRelationIds: ["a-duplicate", "z-duplicate"]})
    expect(relation.evidence.map((evidence) => evidence.id)).toEqual(["a-duplicate", "z-duplicate"])
    expect(overview.manifest).toMatchObject({omittedMalformedEdges: 2, omittedAttachmentNodes: 1})
  })

  it("chooses a summary parent by canonical pair when multiple attachment candidates exist", () => {
    const graph = {
      nodes: [
        {id: "beta", details: {cluster_kind: "endpoint-anchor"}},
        {id: "alpha", details: {cluster_kind: "endpoint-anchor"}},
        {id: "summary", details: {cluster_kind: "endpoint-summary", cluster_anchor_id: "alpha"}},
      ],
      edges: [
        {id: "beta-summary", source: 0, target: 2, topologyClass: "endpoints", evidenceClass: "endpoint-attachment"},
        {id: "alpha-summary", source: 1, target: 2, topologyClass: "endpoints", evidenceClass: "endpoint-attachment"},
        {id: "alpha-beta", source: 1, target: 0, topologyClass: "backbone"},
      ],
    }

    const forward = prepareTopologyOverviewInput(graph)
    const shuffled = prepareTopologyOverviewInput(reverseGraphArrays(graph))

    expect(forward.treeRelations.find((relation) => relation.targetId === "summary")).toMatchObject({sourceId: "alpha"})
    expect(shuffled).toEqual(forward)
  })
})

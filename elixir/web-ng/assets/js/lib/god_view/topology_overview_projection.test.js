import {describe, expect, it} from "vitest"

import {collapsedFarm01Graph, expandedFarm01Graph, reverseGraphArrays} from "./fixtures/farm01_topology_regression"
import {prepareTopologyOverviewInput} from "./topology_overview_projection"

function denseLowTrustFanoutGraph(endpointCount = 160) {
  const nodes = [
    {id: "core", details: {type: "Router", device_role: "router", topology_plane: "backbone"}},
    {id: "access", details: {type: "Switch", device_role: "switch_l2", topology_plane: "backbone"}},
    {id: "handoff", details: {type: "Firewall", identity_source: "inventory", topology_plane: "backbone"}},
    {id: "sighting", details: {type: "Router", identity_source: "mapper_topology_sighting", topology_plane: "backbone"}},
    {id: "guest", details: {type: "Virtual", device_role: "virtual-guest", topology_plane: "backbone"}},
    ...Array.from({length: endpointCount}, (_, index) => ({
      id: `attachment-${String(index).padStart(3, "0")}`,
      details: {
        type: index === 0 ? "Switch" : "unknown",
        identity_source: "endpoint_attachment_projection",
        topology_plane: "backbone",
      },
    })),
  ]
  const indexById = new Map(nodes.map((node, index) => [node.id, index]))
  const inferred = (targetId, id) => ({
    id,
    source: indexById.get("access"),
    target: indexById.get(targetId),
    topologyClass: "inferred",
    evidenceClass: "inferred",
    metadata: {
      connectivity_forest_bridge: true,
      evidence_class: "inferred",
      relation_type: "INFERRED_TO",
      topology_plane: "backbone",
    },
  })

  return {
    nodes,
    edges: [
      {
        id: "core-access",
        source: indexById.get("core"),
        target: indexById.get("access"),
        topologyClass: "backbone",
        evidenceClass: "direct",
        metadata: {evidence_class: "direct-physical", relation_type: "CONNECTS_TO", topology_plane: "backbone"},
      },
      {
        id: "core-handoff",
        source: indexById.get("core"),
        target: indexById.get("handoff"),
        topologyClass: "backbone",
        evidenceClass: "direct",
        metadata: {evidence_class: "direct-physical", relation_type: "CONNECTS_TO", topology_plane: "backbone"},
      },
      inferred("sighting", "access-sighting"),
      {
        id: "core-guest",
        source: indexById.get("core"),
        target: indexById.get("guest"),
        topologyClass: "hosted",
        evidenceClass: "hosted",
        metadata: {evidence_class: "hosted-virtual", relation_type: "HOSTED_ON", topology_plane: "hosted"},
      },
      ...nodes
        .filter((node) => node.id.startsWith("attachment-"))
        .map((node) => inferred(node.id, `access-${node.id}`)),
    ],
  }
}

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
        {id: "gamma", details: {type: "Switch", topology_plane: "backbone"}},
        {id: "alpha", details: {type: "Router", topology_plane: "backbone"}},
        {id: "beta", details: {type: "Switch", topology_plane: "backbone"}},
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
        {id: "bravo", details: {type: "Switch", topology_plane: "backbone"}},
        {id: "alpha", details: {type: "Router", topology_plane: "backbone"}},
        {id: "delta", details: {type: "Switch", topology_plane: "backbone"}},
        {id: "charlie", details: {type: "Router", topology_plane: "backbone"}},
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
        {id: " beta ", details: {type: "Switch", topology_plane: "backbone"}},
        {id: "alpha", details: {type: "Router", topology_plane: "backbone"}},
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

    // "attachment" is a real endpoint attached to a switch, and a lone client on an anchor is
    // now drawn rather than discarded -- an anchor holding one or two clients used to render as
    // an isolated dot with the clients gone. Malformed and self-loop input is still omitted.
    expect(overview.nodes.map((node) => node.id)).toEqual(["alpha", "attachment", "beta"])
    expect(relation).toMatchObject({semanticRelationIds: ["a-duplicate", "z-duplicate"]})
    expect(relation.evidence.map((evidence) => evidence.id)).toEqual(["a-duplicate", "z-duplicate"])
    expect(overview.manifest).toMatchObject({
      omittedMalformedEdges: 2,
      omittedAttachmentNodes: 0,
      attachedEndpoints: 1,
    })
  })

  it("admits a sub-threshold attachment fan but drops one the server should have summarized", () => {
    // Two anchors, both with endpoints the server left unclustered. The bound is enforced here
    // rather than assumed: "anything at or above the cluster minimum is already a summary" only
    // holds when the server actually clustered, and where it did not, a raw fan would bury the
    // backbone. An anchor over the limit keeps NONE of its endpoints -- a partial fan would
    // misrepresent itself as the whole set.
    const nodes = [
      {id: "small-anchor", details: {type: "Switch", topology_plane: "backbone"}},
      {id: "big-anchor", details: {type: "Switch", topology_plane: "backbone"}},
      {id: "spine", details: {type: "Router", topology_plane: "backbone"}},
    ]
    const edges = [
      {id: "spine-small", source: 0, target: 2, topologyClass: "backbone", evidenceClass: "direct"},
      {id: "spine-big", source: 1, target: 2, topologyClass: "backbone", evidenceClass: "direct"},
    ]

    const attach = (anchorIndex, id) => {
      edges.push({
        id: `att:${id}`,
        source: anchorIndex,
        target: nodes.length,
        topologyClass: "endpoints",
        evidenceClass: "endpoint-attachment",
        metadata: {relation_type: "ATTACHED_TO", topology_plane: "attachment"},
      })
      nodes.push({id, details: {type: "unknown", topology_plane: "attachment"}})
    }

    attach(0, "small-1")
    attach(0, "small-2")
    for (let index = 0; index < 5; index += 1) attach(1, `big-${index}`)

    const overview = prepareTopologyOverviewInput({nodes, edges})
    const ids = overview.nodes.filter((node) => !node.synthetic).map((node) => node.id)

    expect(ids).toContain("small-1")
    expect(ids).toContain("small-2")
    for (let index = 0; index < 5; index += 1) {
      expect(ids).not.toContain(`big-${index}`)
    }
    expect(overview.manifest).toMatchObject({attachedEndpoints: 2, omittedAttachmentNodes: 5})

    // Both admitted endpoints hang off their anchor, so the anchor is not left edgeless.
    const parents = overview.treeRelations
      .filter((relation) => ["small-1", "small-2"].includes(relation.targetId))
      .map((relation) => relation.sourceId)
    expect(parents).toEqual(["small-anchor", "small-anchor"])
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
    expect(forward.crossLinks).toContainEqual(expect.objectContaining({
      pairId: "overview:pair:beta|summary",
      semanticRelationIds: ["beta-summary"],
      evidence: [expect.objectContaining({id: "beta-summary"})],
    }))
    expect(shuffled).toEqual(forward)
  })

  it("admits an expanded endpoint member without promoting it into transport", () => {
    const graph = expandedFarm01Graph()
    const memberIndex = graph.nodes.findIndex((node) => node.id === "farm01:endpoint-member-01")
    const anchorIndex = graph.nodes.findIndex((node) => node.id === "farm01:gateway-01")
    graph.edges.push({
      id: "farm01:member-observed-link",
      source: memberIndex,
      target: anchorIndex,
      topologyClass: "observed",
      evidenceClass: "observed",
    })

    const overview = prepareTopologyOverviewInput(graph)

    // The invariant here is that incidental transport-looking evidence never promotes a
    // member into the backbone -- not that members are absent. An expanded cluster now
    // elaborates the atlas, so its members are present, as members.
    const member = overview.nodes.find((node) => node.id === "farm01:endpoint-member-01")

    expect(member, "an expanded member belongs in the atlas").toBeTruthy()
    expect(member.role, "observed evidence must not promote a member into transport").toEqual("member")
    expect(
      overview.nodes.some((node) => node.type === "endpoint-member" && node.role === "infrastructure"),
    ).toEqual(false)
  })

  it("keeps low-trust inferred endpoint fanout bounded while preserving a direct transport handoff", () => {
    const overview = prepareTopologyOverviewInput(denseLowTrustFanoutGraph())

    expect(overview.nodes.filter((node) => !node.synthetic).map((node) => node.id)).toEqual([
      "access",
      "core",
      "handoff",
    ])
    expect(overview.treeRelations.map((relation) => relation.id)).toEqual([
      "overview:pair:access|core",
      "overview:pair:core|handoff",
    ])
    expect(overview.crossLinks).toEqual([])
    expect(overview.manifest).toMatchObject({
      glyphs: 3,
      infrastructureNodes: 3,
      treeRelations: 2,
      omittedAttachmentNodes: 162,
      components: 1,
    })
  })
})

describe("expanded clusters inside the radial atlas", () => {
  // Expanding used to promote the whole graph to the bounded-detail scene, which threw away
  // the radial backbone and re-laid every node with the layered algorithm. The atlas should
  // elaborate instead: the backbone keeps its radial positions and the opened cluster gains a
  // ring of members in its own wedge.
  function expandedGraph({summaryIdMatchesClusterId}) {
    const anchorId = "farm01:gateway-01"
    const clusterId = `cluster:endpoints:${anchorId}`
    const summaryId = summaryIdMatchesClusterId ? clusterId : "farm01:endpoint-summary-01"
    const nodes = [
      {id: anchorId, label: "gateway", details: {cluster_kind: "endpoint-anchor", cluster_anchor_id: anchorId}},
      {id: summaryId, label: "6 endpoints", clusterCount: 6,
        details: {cluster_id: clusterId, cluster_kind: "endpoint-summary",
          cluster_anchor_id: anchorId, cluster_expanded: true}},
    ]
    const edges = [{id: "att:summary", source: 0, target: 1,
      topologyClass: "endpoints", evidenceClass: "endpoint-attachment"}]
    for (let index = 0; index < 6; index += 1) {
      edges.push({id: `att:member-${index}`, source: 0, target: nodes.length,
        topologyClass: "endpoints", evidenceClass: "endpoint-attachment"})
      nodes.push({id: `member-${index}`, label: `endpoint ${index}`,
        details: {cluster_id: clusterId, cluster_kind: "endpoint-member",
          cluster_anchor_id: anchorId, cluster_expanded: true}})
    }
    return {nodes, edges, summaryId, clusterId}
  }

  // Production names the summary node with the cluster id; the regression fixtures give it a
  // separate id. Both must resolve a member to its summary, so neither shape can regress.
  for (const summaryIdMatchesClusterId of [true, false]) {
    it(`admits expanded members and hangs them off the anchor (summaryId===clusterId: ${summaryIdMatchesClusterId})`, () => {
      const {summaryId, ...graph} = expandedGraph({summaryIdMatchesClusterId})
      const input = prepareTopologyOverviewInput(graph)
      const ids = new Set(input.nodes.map((node) => node.id))

      for (let index = 0; index < 6; index += 1) {
        expect(ids.has(`member-${index}`), `member-${index} must reach the atlas`).toBe(true)
      }

      const relationByTarget = new Map(input.treeRelations.map((relation) => [relation.targetId, relation]))
      for (let index = 0; index < 6; index += 1) {
        const relation = relationByTarget.get(`member-${index}`)
        expect(relation, `member-${index} must be connected`).toBeTruthy()
        expect(relation.sourceId).toBe("farm01:gateway-01")
        // A relation with no backing graph edge lays out but never renders -- the member
        // draws as an unconnected dot. Carrying the attachment edge's identity is what makes
        // it a drawn route.
        expect(relation.semanticRelationIds.length, "member route must carry its edge identity").toBeGreaterThan(0)
        expect(relation.evidence.length, "member route must carry its edge evidence").toBeGreaterThan(0)
      }
      // The bubble an expanded cluster replaced is no longer admitted at all: its members
      // stand in for it. Leaving it in the projection is what made an opened cluster an
      // island -- the renderer hides an expanded summary's glyph, so the members were
      // parented on something never drawn, while its own link to the backbone failed the
      // same visibility test and was filtered out.
      expect(ids.has(summaryId), "an expanded summary must not stay in the atlas").toBe(false)
      expect(
        relationByTarget.has(summaryId),
        "an expanded summary must not keep a relation",
      ).toBe(false)
    })
  }

  it("leaves a collapsed cluster as a single summary glyph", () => {
    const graph = expandedGraph({summaryIdMatchesClusterId: true})
    const collapsed = {
      ...graph,
      nodes: graph.nodes.map((node) => (
        node.details?.cluster_kind === "endpoint-member"
          ? node
          : {...node, details: {...node.details, cluster_expanded: false}}
      )).filter((node) => node.details?.cluster_kind !== "endpoint-member"),
      edges: graph.edges.slice(0, 1),
    }
    const input = prepareTopologyOverviewInput(collapsed)

    expect(input.nodes.some((node) => String(node.id).startsWith("member-"))).toBe(false)
  })
})

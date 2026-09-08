import {canonicalSemanticRelationId} from "./topology_relation_identity"

const SUPER_ROOT_ID = "overview:super-root"
// Keep this boundary aligned with the server's endpoint-like classification:
// incidental connectivity must never promote an observation into overview transport.
const TRANSPORT_NODE_TYPES = new Set([
  "access_point",
  "ap",
  "endpoint_cluster",
  "firewall",
  "hub",
  "ids",
  "ips",
  "load_balancer",
  "router",
  "switch",
])
const NON_PROMOTABLE_IDENTITY_SOURCES = new Set([
  "endpoint_attachment_projection",
  "mapper_topology_sighting",
])

function stringValue(value) {
  return value == null ? "" : String(value).trim()
}

function detailsFor(node) {
  return node?.details && typeof node.details === "object" ? node.details : {}
}

function metadataFor(edge) {
  return edge?.metadata && typeof edge.metadata === "object" ? edge.metadata : {}
}

function sortedUnique(values) {
  return Array.from(new Set(values)).sort((left, right) => left.localeCompare(right))
}

function stableValue(value) {
  if (Array.isArray(value)) return value.map(stableValue)
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.keys(value)
        .sort((left, right) => left.localeCompare(right))
        .map((key) => [key, stableValue(value[key])]),
    )
  }
  return value
}

function stableJson(value) {
  return JSON.stringify(stableValue(value))
}

function truthy(value) {
  return value === true || value === 1 || value === "1" || value === "true"
}

function isAttachmentRelation(edge) {
  if (truthy(metadataFor(edge).connectivity_forest_bridge)) return false

  const metadata = metadataFor(edge)
  const topologyClass = stringValue(edge?.topologyClass).toLowerCase()
  const evidenceClass = stringValue(edge?.evidenceClass ?? edge?.evidence_class).toLowerCase()
  const relationType = stringValue(edge?.relationType ?? metadata.relation_type).toUpperCase()
  const topologyPlane = stringValue(metadata.topology_plane).toLowerCase()

  return (
    topologyClass === "endpoint" ||
    topologyClass === "endpoints" ||
    topologyClass === "attachment" ||
    evidenceClass === "endpoint-attachment" ||
    relationType === "ATTACHED_TO" ||
    topologyPlane === "attachment"
  )
}

function trustRank(edge) {
  const metadata = metadataFor(edge)
  const topologyClass = stringValue(edge?.topologyClass).toLowerCase()
  const evidenceClass = stringValue(edge?.evidenceClass ?? edge?.evidence_class).toLowerCase()
  const topologyPlane = stringValue(metadata.topology_plane).toLowerCase()

  if (
    topologyClass === "backbone" ||
    evidenceClass === "direct" ||
    topologyPlane === "physical" ||
    topologyPlane === "backbone"
  ) return 0
  if (topologyClass === "logical" || evidenceClass === "logical") return 1
  if (topologyClass === "hosted" || evidenceClass === "hosted") return 2
  if (truthy(metadata.connectivity_forest_bridge)) return 3
  if (topologyClass === "inferred" || evidenceClass === "inferred") return 4
  if (topologyClass === "observed" || evidenceClass === "observed") return 5
  return 6
}

function nodeType(node) {
  const details = detailsFor(node)
  return stringValue(details.cluster_kind || details.type || node?.kind).toLowerCase() || "node"
}

function canonicalNodeType(value) {
  return stringValue(value).toLowerCase().replace(/[\s-]+/g, "_")
}

// An expanded cluster elaborates the atlas rather than replacing it: its members join the
// projection and hang off their summary, so the radial algorithm places them on the ring
// beyond it, inside that summary's own wedge. Collapsed clusters stay a single glyph.
function isExpandedEndpointMember(node) {
  return node.type === "endpoint-member" && truthy(detailsFor(node.raw).cluster_expanded)
}

// An expanded summary has been replaced by its own members -- standing in for them was the
// bubble's only job -- so it is dropped from the projection entirely. Leaving it admitted is
// what made an opened cluster an island: the renderer hides an expanded summary's glyph, but
// the members were still parented on it, so the ring orbited a hub that was never drawn while
// the hub's own link to the backbone failed the same visibility test and was filtered out.
// memberRelations re-parents the members onto the anchor, so the bubble is only removed when
// that anchor actually resolves to infrastructure; otherwise it stays and remains their parent.
function isElaboratedSummary(node, infrastructureIds) {
  if (node.type !== "endpoint-summary") return false
  if (!truthy(detailsFor(node.raw).cluster_expanded)) return false
  return infrastructureIds.has(stringValue(detailsFor(node.raw).cluster_anchor_id))
}

function isTransportInfrastructureNode(node) {
  if (node.type === "endpoint-anchor") return true
  const identitySource = stringValue(detailsFor(node.raw).identity_source).toLowerCase()
  return !NON_PROMOTABLE_IDENTITY_SOURCES.has(identitySource)
    && TRANSPORT_NODE_TYPES.has(canonicalNodeType(node.type))
}

function isTransportRelation(edge) {
  if (isAttachmentRelation(edge)) return false

  const metadata = metadataFor(edge)
  const topologyClass = stringValue(edge?.topologyClass).toLowerCase()
  const evidenceClass = stringValue(edge?.evidenceClass ?? edge?.evidence_class).toLowerCase()
  const relationType = stringValue(edge?.relationType ?? metadata.relation_type).toUpperCase()
  const topologyPlane = stringValue(metadata.topology_plane).toLowerCase()
  if (topologyClass === "hosted" || evidenceClass === "hosted" || topologyPlane === "hosted" || relationType === "HOSTED_ON") {
    return false
  }

  return ["backbone", "inferred", "logical", "observed"].includes(topologyClass)
    || ["direct", "inferred", "logical", "observed"].includes(evidenceClass)
    || ["backbone", "logical", "physical"].includes(topologyPlane)
    || ["CONNECTS_TO", "INFERRED_TO", "LOGICAL_PEER"].includes(relationType)
}

function normalizeNodes(graph) {
  const rawNodes = Array.isArray(graph?.nodes) ? graph.nodes : []
  const byId = new Map()
  const indexToId = new Map()

  rawNodes.forEach((rawNode, index) => {
    const id = stringValue(rawNode?.id)
    if (id === "") return
    indexToId.set(index, id)

    const candidate = {id, raw: stableValue(rawNode), type: nodeType(rawNode)}
    const current = byId.get(id)
    if (!current || stableJson(candidate.raw).localeCompare(stableJson(current.raw)) < 0) byId.set(id, candidate)
  })

  return {
    nodes: Array.from(byId.values()).sort((left, right) => left.id.localeCompare(right.id)),
    indexToId,
  }
}

function endpointId(value, indexToId, knownIds) {
  if (Number.isInteger(value) && value >= 0) return indexToId.get(value) || ""
  const id = stringValue(value)
  return knownIds.has(id) ? id : ""
}

function semanticRelationId(edge, sourceId, targetId) {
  return stringValue(edge?.id || edge?.edge_id) || canonicalSemanticRelationId(edge, sourceId, targetId)
}

function pairId(leftId, rightId) {
  const [left, right] = [leftId, rightId].sort((a, b) => a.localeCompare(b))
  return `overview:pair:${left}|${right}`
}

function evidenceFor(edge, relationId, sourceId, targetId) {
  const {source: _source, target: _target, ...rest} = edge || {}
  return stableValue({
    id: relationId,
    sourceId,
    targetId,
    ...rest,
  })
}

function aggregatePairs(graph, normalized) {
  const rawEdges = Array.isArray(graph?.edges) ? graph.edges : []
  const knownIds = new Set(normalized.nodes.map((node) => node.id))
  const pairs = new Map()
  const transportDegree = new Map(normalized.nodes.map((node) => [node.id, 0]))
  let omittedMalformedEdges = 0

  for (const edge of rawEdges) {
    const sourceId = endpointId(edge?.source, normalized.indexToId, knownIds)
    const targetId = endpointId(edge?.target, normalized.indexToId, knownIds)
    if (sourceId === "" || targetId === "" || sourceId === targetId) {
      omittedMalformedEdges += 1
      continue
    }

    const attachment = isAttachmentRelation(edge)
    const transport = isTransportRelation(edge)
    if (transport) {
      transportDegree.set(sourceId, (transportDegree.get(sourceId) || 0) + 1)
      transportDegree.set(targetId, (transportDegree.get(targetId) || 0) + 1)
    }

    const id = pairId(sourceId, targetId)
    const current = pairs.get(id) || {
      id,
      pairId: id,
      nodeIds: [sourceId, targetId].sort((left, right) => left.localeCompare(right)),
      entries: [],
      hasTransport: false,
      hasAttachment: false,
    }
    const relationId = semanticRelationId(edge, sourceId, targetId)
    current.entries.push({
      attachment,
      transport,
      evidence: evidenceFor(edge, relationId, sourceId, targetId),
      relationId,
      trustRank: trustRank(edge),
    })
    current.hasTransport = current.hasTransport || transport
    current.hasAttachment = current.hasAttachment || attachment
    pairs.set(id, current)
  }

  const aggregated = Array.from(pairs.values()).map((pair) => {
    const entries = [...pair.entries].sort((left, right) => {
      const byId = left.relationId.localeCompare(right.relationId)
      return byId === 0 ? stableJson(left.evidence).localeCompare(stableJson(right.evidence)) : byId
    })
    const usableEntries = entries.filter((entry) => !entry.attachment)
    const rankEntries = usableEntries.length > 0 ? usableEntries : entries
    return {
      ...pair,
      entries,
      evidence: entries.map((entry) => entry.evidence),
      semanticRelationIds: sortedUnique(entries.map((entry) => entry.relationId)),
      trustRank: Math.min(...rankEntries.map((entry) => entry.trustRank)),
    }
  })

  return {pairs: aggregated, transportDegree, omittedMalformedEdges}
}

// An endpoint the server did not cluster -- its anchor holds fewer than the cluster minimum --
// arrives as a plain node with a real attachment to admitted infrastructure. Admitting only
// clustered endpoints dropped it and took its anchor's only edges with it: a fleet where most
// anchors hold one or two clients rendered those anchors as isolated dots with the clients gone.
// A switch with two clients should draw two clients, not nothing.
//
// The cap is enforced here rather than assumed. "Anything at or above the cluster minimum is
// already a summary" only holds when the server actually clustered; where it did not, a
// low-trust ARP/FDB fanout arrives as hundreds of bare endpoints off one anchor and would bury
// the backbone it is supposed to sit beside. An anchor over the limit keeps none of them --
// that set belongs in a summary, and drawing a partial fan would misrepresent it as complete.
const MAX_UNCLUSTERED_ENDPOINTS_PER_ANCHOR = 2

// A node the endpoint-attachment projection synthesized is a stand-in that the cluster
// projection supersedes, never something to draw in its own right --
// isTransportInfrastructureNode already refuses to promote these, and admitting one here as a
// bare endpoint would put the superseded copy back on the surface.
function promotableEndpointNode(node) {
  const identitySource = stringValue(detailsFor(node.raw).identity_source).toLowerCase()
  return !NON_PROMOTABLE_IDENTITY_SOURCES.has(identitySource)
}

function attachedEndpointNodes(normalized, pairs, infrastructureIds, excludedIds) {
  const promotableIds = new Set(
    normalized.nodes.filter(promotableEndpointNode).map((node) => node.id),
  )
  const byAnchor = new Map()
  for (const pair of pairs || []) {
    const [left, right] = pair.nodeIds || []
    if (!left || !right) continue
    // Attachment pairs only. A connectivity-forest bridge also joins infrastructure to a
    // non-infrastructure node -- a virtual guest, or a raw projection stand-in -- and admitting
    // on any pair pulled those onto the surface, which is precisely the fanout the overview
    // exists to keep out.
    if (!pair.hasAttachment) continue
    const leftInfrastructure = infrastructureIds.has(left)
    if (leftInfrastructure === infrastructureIds.has(right)) continue
    const anchorId = leftInfrastructure ? left : right
    const endpointId = leftInfrastructure ? right : left
    if (excludedIds.has(endpointId) || !promotableIds.has(endpointId)) continue
    const bucket = byAnchor.get(anchorId) || new Set()
    bucket.add(endpointId)
    byAnchor.set(anchorId, bucket)
  }

  const attachedIds = new Set()
  for (const endpointIds of byAnchor.values()) {
    if (endpointIds.size > MAX_UNCLUSTERED_ENDPOINTS_PER_ANCHOR) continue
    for (const endpointId of endpointIds) attachedIds.add(endpointId)
  }

  return normalized.nodes.filter((node) => attachedIds.has(node.id))
}

function overviewNodes(normalized, pairs) {
  const infrastructure = normalized.nodes.filter(isTransportInfrastructureNode)
  const infrastructureIds = new Set(infrastructure.map((node) => node.id))
  const summaries = normalized.nodes.filter(
    (node) =>
      node.type === "endpoint-summary" &&
      !infrastructureIds.has(node.id) &&
      !isElaboratedSummary(node, infrastructureIds),
  )
  const summaryIds = new Set(summaries.map((node) => node.id))
  const members = normalized.nodes.filter(
    (node) => isExpandedEndpointMember(node) && !infrastructureIds.has(node.id) && !summaryIds.has(node.id),
  )
  // Every endpoint-summary is excluded, not just the admitted ones: an ELABORATED summary is
  // deliberately absent from summaryIds, and readmitting it here as a bare endpoint would undo
  // exactly the island fix that removed it.
  const excludedIds = new Set([
    ...infrastructureIds,
    ...normalized.nodes.filter((node) => node.type === "endpoint-summary").map((node) => node.id),
    ...members.map((node) => node.id),
  ])
  const attached = attachedEndpointNodes(normalized, pairs, infrastructureIds, excludedIds)
  const leaves = [...members, ...attached]
  const visibleIds = new Set([...infrastructure, ...summaries, ...leaves].map((node) => node.id))
  const roleFor = (node) => {
    if (infrastructureIds.has(node.id)) return "infrastructure"
    return summaryIds.has(node.id) ? "summary" : "member"
  }
  const semanticNodes = [...infrastructure, ...summaries, ...leaves]
    .map((node) => ({
      id: node.id,
      label: stringValue(node.raw?.label),
      role: roleFor(node),
      type: node.type,
    }))
    .sort((left, right) => left.id.localeCompare(right.id))

  return {attached, infrastructureIds, leaves, members, semanticNodes, summaries, visibleIds}
}

function comparePair(left, right) {
  return left.trustRank - right.trustRank || left.pairId.localeCompare(right.pairId)
}

function createUnionFind(nodeIds) {
  const parent = new Map(nodeIds.map((id) => [id, id]))
  const find = (id) => {
    const current = parent.get(id)
    if (current === id) return id
    const root = find(current)
    parent.set(id, root)
    return root
  }
  return {
    connected(left, right) {
      return find(left) === find(right)
    },
    join(left, right) {
      const leftRoot = find(left)
      const rightRoot = find(right)
      if (leftRoot === rightRoot) return false
      if (leftRoot.localeCompare(rightRoot) <= 0) parent.set(rightRoot, leftRoot)
      else parent.set(leftRoot, rightRoot)
      return true
    },
  }
}

function roleRank(node) {
  return node.type === "endpoint-anchor" ? 0 : 1
}

function infrastructureTypeRank(node) {
  const ranks = {"endpoint-anchor": 0, gateway: 1, router: 2, switch: 3, node: 4}
  return ranks[node.type] ?? 5
}

function relationFromPair(pair, sourceId, targetId) {
  return {
    id: pair.id,
    pairId: pair.pairId,
    sourceId,
    targetId,
    trustRank: pair.trustRank,
    semanticRelationIds: pair.semanticRelationIds,
    evidence: pair.evidence,
  }
}

function orientForest(treePairs, infrastructure, transportDegree) {
  const byId = new Map(infrastructure.map((node) => [node.id, node]))
  const adjacency = new Map(infrastructure.map((node) => [node.id, []]))
  for (const pair of treePairs) {
    const [left, right] = pair.nodeIds
    adjacency.get(left).push({pair, neighborId: right})
    adjacency.get(right).push({pair, neighborId: left})
  }
  for (const edges of adjacency.values()) {
    edges.sort((left, right) => left.neighborId.localeCompare(right.neighborId) || left.pairId?.localeCompare(right.pairId))
  }

  const visited = new Set()
  const roots = []
  const relations = []
  const candidateIds = infrastructure.map((node) => node.id).sort((left, right) => {
    const leftNode = byId.get(left)
    const rightNode = byId.get(right)
    return (
      roleRank(leftNode) - roleRank(rightNode) ||
      (transportDegree.get(right) || 0) - (transportDegree.get(left) || 0) ||
      infrastructureTypeRank(leftNode) - infrastructureTypeRank(rightNode) ||
      left.localeCompare(right)
    )
  })

  for (const rootId of candidateIds) {
    if (visited.has(rootId)) continue
    roots.push(rootId)
    visited.add(rootId)
    const queue = [rootId]
    for (let index = 0; index < queue.length; index += 1) {
      const sourceId = queue[index]
      for (const {pair, neighborId} of adjacency.get(sourceId)) {
        if (visited.has(neighborId)) continue
        visited.add(neighborId)
        queue.push(neighborId)
        relations.push(relationFromPair(pair, sourceId, neighborId))
      }
    }
  }

  return {roots, relations}
}

function summaryRelations(summaries, infrastructureIds, pairs) {
  const relations = []
  const crossLinks = []
  for (const summary of [...summaries].sort((left, right) => left.id.localeCompare(right.id))) {
    const anchorId = stringValue(detailsFor(summary.raw).cluster_anchor_id)
    const matchingPairs = pairs
      .filter((pair) => pair.nodeIds.includes(summary.id) && pair.nodeIds.some((id) => infrastructureIds.has(id)))
      .sort(comparePair)
    const matchingPair = matchingPairs[0]
    const parentId = matchingPair
      ? matchingPair.nodeIds.find((id) => id !== summary.id && infrastructureIds.has(id))
      : (infrastructureIds.has(anchorId) ? anchorId : "")
    if (parentId === "") continue

    if (matchingPair) relations.push(relationFromPair(matchingPair, parentId, summary.id))
    else {
      relations.push({
        id: `overview:summary:${parentId}|${summary.id}`,
        pairId: `overview:summary:${parentId}|${summary.id}`,
        sourceId: parentId,
        targetId: summary.id,
        trustRank: 6,
        semanticRelationIds: [],
        evidence: [],
        summary: true,
      })
    }

    for (const rejectedPair of matchingPairs.slice(1)) {
      const rejectedParentId = rejectedPair.nodeIds.find((id) => id !== summary.id && infrastructureIds.has(id))
      crossLinks.push(relationFromPair(rejectedPair, rejectedParentId, summary.id))
    }
  }
  return {relations, crossLinks}
}

// A member is parented on whatever its real attachment edge points at, and the relation is
// built from that pair so it carries the edge's identity and evidence.
//
// Both halves matter. The renderer resolves a route back to graph edges through
// `relationIds`; a fabricated relation has none, so the route is dropped as
// "missing-relation-bindings" and the member draws as an unconnected dot. And the other end
// is the cluster summary, not the anchor -- the server attaches an expanded member to its
// cluster node -- so looking for an anchor pair finds nothing and falls back to exactly that
// broken fabricated relation.
function memberRelations(members, visibleIds, pairs, infrastructureIds) {
  const pairsByNodeId = new Map()
  for (const pair of pairs) {
    for (const nodeId of pair.nodeIds) {
      const bucket = pairsByNodeId.get(nodeId) || []
      bucket.push(pair)
      pairsByNodeId.set(nodeId, bucket)
    }
  }

  return [...members]
    .sort((left, right) => left.id.localeCompare(right.id))
    .flatMap((member) => {
      const memberPairs = (pairsByNodeId.get(member.id) || []).sort(comparePair)
      const visiblePair = memberPairs.find((pair) =>
        pair.nodeIds.some((id) => id !== member.id && visibleIds.has(id)),
      )
      if (visiblePair) {
        const parentId = visiblePair.nodeIds.find((id) => id !== member.id && visibleIds.has(id))
        return [relationFromPair(visiblePair, parentId, member.id)]
      }

      // The server attaches a member to its cluster node, not to the anchor, so once the
      // elaborated summary is no longer admitted the member has no visible counterpart left to
      // pair with. Re-target its real attachment onto the anchor the summary itself hung from,
      // which is where the endpoint physically attaches -- that is what ties the opened ring
      // back to the backbone. Retargeting rather than synthesizing a fresh relation is what
      // keeps semanticRelationIds populated: a relation carrying no bindings produces a route
      // the renderer discards as missing-relation-bindings, which is the same invisible edge
      // by another name.
      const anchorId = stringValue(detailsFor(member.raw).cluster_anchor_id)
      if (!infrastructureIds.has(anchorId)) return []
      const attachment = memberPairs[0]
      if (attachment) return [relationFromPair(attachment, anchorId, member.id)]

      const id = `overview:member:${anchorId}|${member.id}`
      return [{
        id,
        pairId: id,
        sourceId: anchorId,
        targetId: member.id,
        trustRank: 6,
        semanticRelationIds: [],
        evidence: [],
      }]
    })
}

function graphKeyFor({semanticNodes, roots, semanticTreeRelations, crossLinks, synthetic}) {
  return stableJson({
    nodes: semanticNodes,
    roots,
    treeRelations: semanticTreeRelations,
    crossLinks,
    synthetic,
  })
}

export function prepareTopologyOverviewInput(graph) {
  const normalized = normalizeNodes(graph)
  const {pairs, transportDegree, omittedMalformedEdges} = aggregatePairs(graph, normalized)
  const {attached, infrastructureIds, leaves, members, semanticNodes, summaries, visibleIds} =
    overviewNodes(normalized, pairs)
  const infrastructure = normalized.nodes.filter((node) => infrastructureIds.has(node.id))
  const candidatePairs = pairs
    .filter((pair) => pair.hasTransport && pair.nodeIds.every((id) => infrastructureIds.has(id)))
    .sort(comparePair)
  const unionFind = createUnionFind(infrastructure.map((node) => node.id))
  const treePairs = []
  const crossLinks = []
  for (const pair of candidatePairs) {
    const [left, right] = pair.nodeIds
    if (unionFind.join(left, right)) treePairs.push(pair)
    else crossLinks.push(relationFromPair(pair, left, right))
  }

  const oriented = orientForest(treePairs, infrastructure, transportDegree)
  const {relations: summaryLeaves, crossLinks: summaryCrossLinks} = summaryRelations(summaries, infrastructureIds, pairs)
  const allCrossLinks = [...crossLinks, ...summaryCrossLinks].sort(
    (left, right) => left.pairId.localeCompare(right.pairId) || left.sourceId.localeCompare(right.sourceId),
  )
  const synthetic = {nodeIds: [], relationIds: []}
  const nodes = [...semanticNodes]
  const treeRelations = [
    ...oriented.relations,
    ...summaryLeaves,
    ...memberRelations(leaves, visibleIds, pairs, infrastructureIds),
  ]

  if (oriented.roots.length > 1) {
    nodes.push({id: SUPER_ROOT_ID, label: "", role: "synthetic", type: "super-root", synthetic: true, width: 0, height: 0})
    synthetic.nodeIds.push(SUPER_ROOT_ID)
    for (const rootId of oriented.roots) {
      const id = `${SUPER_ROOT_ID}|${rootId}`
      synthetic.relationIds.push(id)
      treeRelations.push({
        id,
        pairId: id,
        sourceId: SUPER_ROOT_ID,
        targetId: rootId,
        trustRank: -1,
        semanticRelationIds: [],
        evidence: [],
        synthetic: true,
      })
    }
  }

  const semanticTreeRelations = treeRelations.filter((relation) => !relation.synthetic)
  const omittedAttachmentNodes = normalized.nodes.filter((node) => !visibleIds.has(node.id)).length
  const manifest = {
    // The scene observer and the acceptance contract read a manifest in the detail
    // projection's vocabulary. Report those three keys here too rather than leaving them
    // undefined, which surfaced as an overview scene claiming zero nodes and zero edges.
    // attachmentEdges is genuinely 0: the overview renders none, and the ones it left out
    // are counted in omittedAttachmentNodes.
    nodes: semanticNodes.length,
    semanticEdges: semanticTreeRelations.length + allCrossLinks.length,
    attachmentEdges: 0,
    glyphs: semanticNodes.length,
    infrastructureNodes: infrastructure.length,
    collapsedSummaries: summaries.length,
    expandedMembers: members.length,
    // Endpoints admitted directly because their anchor held too few to cluster. Previously
    // these were counted only in omittedAttachmentNodes -- i.e. silently discarded.
    attachedEndpoints: attached.length,
    treeRelations: semanticTreeRelations.length,
    crossLinks: allCrossLinks.length,
    omittedAttachmentNodes,
    omittedMalformedEdges,
    components: oriented.roots.length,
    semanticNodes: semanticNodes.length,
    nodeIds: semanticNodes.map((node) => node.id),
  }

  return {
    nodes,
    roots: oriented.roots,
    treeRelations,
    crossLinks: allCrossLinks,
    synthetic,
    graphKey: graphKeyFor({semanticNodes, roots: oriented.roots, semanticTreeRelations, crossLinks: allCrossLinks, synthetic}),
    manifest,
  }
}

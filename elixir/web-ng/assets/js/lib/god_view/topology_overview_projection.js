import {canonicalSemanticRelationId} from "./topology_relation_identity"

const SUPER_ROOT_ID = "overview:super-root"

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
  return stringValue(details.cluster_kind || node?.kind).toLowerCase() || "node"
}

function isBackboneNode(node) {
  const plane = stringValue(detailsFor(node).topology_plane).toLowerCase()
  return plane === "backbone"
}

function normalizeNodes(graph) {
  const rawNodes = Array.isArray(graph?.nodes) ? graph.nodes : []
  const byId = new Map()
  const indexToId = new Map()

  rawNodes.forEach((rawNode, index) => {
    const id = stringValue(rawNode?.id)
    if (id === "") return
    indexToId.set(index, id)

    const candidate = {id, raw: stableValue(rawNode), type: nodeType(rawNode), backbone: isBackboneNode(rawNode)}
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
  const nonAttachmentIncident = new Set()
  let omittedMalformedEdges = 0

  for (const edge of rawEdges) {
    const sourceId = endpointId(edge?.source, normalized.indexToId, knownIds)
    const targetId = endpointId(edge?.target, normalized.indexToId, knownIds)
    if (sourceId === "" || targetId === "" || sourceId === targetId) {
      omittedMalformedEdges += 1
      continue
    }

    const attachment = isAttachmentRelation(edge)
    if (!attachment) {
      nonAttachmentIncident.add(sourceId)
      nonAttachmentIncident.add(targetId)
      transportDegree.set(sourceId, (transportDegree.get(sourceId) || 0) + 1)
      transportDegree.set(targetId, (transportDegree.get(targetId) || 0) + 1)
    }

    const id = pairId(sourceId, targetId)
    const current = pairs.get(id) || {
      id,
      pairId: id,
      nodeIds: [sourceId, targetId].sort((left, right) => left.localeCompare(right)),
      entries: [],
      hasNonAttachment: false,
    }
    const relationId = semanticRelationId(edge, sourceId, targetId)
    current.entries.push({
      attachment,
      evidence: evidenceFor(edge, relationId, sourceId, targetId),
      relationId,
      trustRank: trustRank(edge),
    })
    current.hasNonAttachment = current.hasNonAttachment || !attachment
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

  return {pairs: aggregated, transportDegree, nonAttachmentIncident, omittedMalformedEdges}
}

function overviewNodes(normalized, nonAttachmentIncident) {
  const infrastructure = normalized.nodes.filter(
    (node) => node.type === "endpoint-anchor" || node.backbone || nonAttachmentIncident.has(node.id),
  )
  const infrastructureIds = new Set(infrastructure.map((node) => node.id))
  const summaries = normalized.nodes.filter(
    (node) => node.type === "endpoint-summary" && !infrastructureIds.has(node.id),
  )
  const visibleIds = new Set([...infrastructure, ...summaries].map((node) => node.id))
  const semanticNodes = [...infrastructure, ...summaries]
    .map((node) => ({
      id: node.id,
      label: stringValue(node.raw?.label),
      role: infrastructureIds.has(node.id) ? "infrastructure" : "summary",
      type: node.type,
    }))
    .sort((left, right) => left.id.localeCompare(right.id))

  return {infrastructureIds, semanticNodes, summaries, visibleIds}
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
  return node.type === "endpoint-anchor" ? 0 : (node.backbone ? 1 : 2)
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
  const result = []
  for (const summary of [...summaries].sort((left, right) => left.id.localeCompare(right.id))) {
    const anchorId = stringValue(detailsFor(summary.raw).cluster_anchor_id)
    const matchingPair = pairs
      .filter((pair) => pair.nodeIds.includes(summary.id) && pair.nodeIds.some((id) => infrastructureIds.has(id)))
      .sort(comparePair)[0]
    const parentId = matchingPair
      ? matchingPair.nodeIds.find((id) => id !== summary.id && infrastructureIds.has(id))
      : (infrastructureIds.has(anchorId) ? anchorId : "")
    if (parentId === "") continue

    if (matchingPair) result.push(relationFromPair(matchingPair, parentId, summary.id))
    else {
      result.push({
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
  }
  return result
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
  const {pairs, transportDegree, nonAttachmentIncident, omittedMalformedEdges} = aggregatePairs(graph, normalized)
  const {infrastructureIds, semanticNodes, summaries, visibleIds} = overviewNodes(normalized, nonAttachmentIncident)
  const infrastructure = normalized.nodes.filter((node) => infrastructureIds.has(node.id))
  const candidatePairs = pairs
    .filter((pair) => pair.hasNonAttachment && pair.nodeIds.every((id) => infrastructureIds.has(id)))
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
  const summaryLeaves = summaryRelations(summaries, infrastructureIds, pairs)
  const synthetic = {nodeIds: [], relationIds: []}
  const nodes = [...semanticNodes]
  const treeRelations = [...oriented.relations, ...summaryLeaves]

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
    glyphs: semanticNodes.length,
    infrastructureNodes: infrastructure.length,
    collapsedSummaries: summaries.length,
    treeRelations: semanticTreeRelations.length,
    crossLinks: crossLinks.length,
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
    crossLinks,
    synthetic,
    graphKey: graphKeyFor({semanticNodes, roots: oriented.roots, semanticTreeRelations, crossLinks, synthetic}),
    manifest,
  }
}

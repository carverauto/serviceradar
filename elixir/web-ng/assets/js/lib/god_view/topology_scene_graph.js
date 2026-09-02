import {canonicalSemanticRelationId} from "./topology_relation_identity"

function stringValue(value) {
  return typeof value === "string" ? value.trim() : String(value || "").trim()
}

function nodeDetails(node) {
  return node?.details && typeof node.details === "object" ? node.details : {}
}

function clusterKind(node) {
  return stringValue(nodeDetails(node).cluster_kind)
}

function clusterId(node) {
  return stringValue(nodeDetails(node).cluster_id)
}

function anchorId(node) {
  return stringValue(nodeDetails(node).cluster_anchor_id)
}

function expandedFlag(value) {
  return value === true || value === "true" || value === 1
}

function isAttachmentRelation(edge) {
  if (expandedFlag(edge?.metadata?.connectivity_forest_bridge)) return false

  const topologyClass = stringValue(edge?.topologyClass).toLowerCase()
  const evidenceClass = stringValue(edge?.evidenceClass).toLowerCase()
  const relationType = stringValue(edge?.metadata?.relation_type || edge?.relationType).toUpperCase()
  const topologyPlane = stringValue(edge?.metadata?.topology_plane).toLowerCase()

  return (
    topologyClass === "endpoint" ||
    topologyClass === "endpoints" ||
    topologyClass === "attachment" ||
    evidenceClass === "endpoint-attachment" ||
    relationType === "ATTACHED_TO" ||
    topologyPlane === "attachment"
  )
}

function semanticRelationId(edge, sourceId, targetId) {
  const explicitId = stringValue(edge?.id || edge?.edge_id)
  if (explicitId !== "") return explicitId
  return canonicalSemanticRelationId(edge, sourceId, targetId)
}

export function canonicalRenderedRelationId(sourceId, targetId) {
  const [left, right] = [stringValue(sourceId), stringValue(targetId)].sort((a, b) => a.localeCompare(b))
  return `rendered:${left}|${right}`
}

function sortedUnique(values) {
  return Array.from(new Set(values)).sort((left, right) => String(left).localeCompare(String(right)))
}

function sceneNodes(graph) {
  const sourceNodes = Array.isArray(graph?.nodes) ? graph.nodes : []
  const seenIds = new Set()

  return sourceNodes.map((node, index) => {
    const id = stringValue(node?.id) || `node:${index}`
    if (seenIds.has(id)) throw new Error(`duplicate topology node id: ${id}`)
    seenIds.add(id)

    const details = nodeDetails(node)
    const kind = clusterKind(node) || "node"
    return {
      id,
      kind,
      clusterId: clusterId(node),
      anchorId: anchorId(node),
      topologyPlane: stringValue(details.topology_plane).toLowerCase(),
      expanded: expandedFlag(details.cluster_expanded),
    }
  })
}

function discoverGroups(nodes) {
  const candidates = new Map()
  for (const node of nodes) {
    if (node.clusterId === "") continue
    const current = candidates.get(node.clusterId) || {
      id: node.clusterId,
      anchorId: "",
      gatewayId: "",
      memberIds: [],
      expanded: false,
    }

    if (node.kind === "endpoint-anchor") current.anchorId = node.id
    if (node.kind === "endpoint-summary") current.gatewayId = node.id
    if (node.kind === "endpoint-member") current.memberIds.push(node.id)
    if (node.anchorId !== "" && current.anchorId === "") current.anchorId = node.anchorId
    current.expanded = current.expanded || node.expanded
    candidates.set(current.id, current)
  }

  return Array.from(candidates.values())
    .filter((group) => group.anchorId !== "" && group.gatewayId !== "")
    .map((group) => ({
      ...group,
      memberIds: sortedUnique(group.memberIds),
    }))
    .sort((left, right) => left.id.localeCompare(right.id))
}

function nodeSceneRecords(nodes, groups) {
  const groupById = new Map(groups.map((group) => [group.id, group]))
  return nodes
    .map((node) => {
      const group = groupById.get(node.clusterId)
      const inGroup = group && (node.id === group.gatewayId || group.memberIds.includes(node.id))
      const render = !(group?.expanded && node.id === group.gatewayId) && !(node.kind === "endpoint-member" && !group?.expanded)
      return {
        id: node.id,
        kind: node.kind,
        groupId: inGroup ? group.id : null,
        render,
      }
    })
    .sort((left, right) => left.id.localeCompare(right.id))
}

// A member's owner is its anchor OR its summary: the server attaches each endpoint to the
// cluster node, and this module already models that itself -- the layout relations below are
// built with sourceId: group.gatewayId. Matching only the anchor meant a real payload's member
// edges were never absorbed into the group, so all 24 survived as separate rendered routes
// (32 -> 56) and the fitted scale collapsed. Same anchor-vs-summary assumption the overview
// projection carried; this is that fix ported to the bounded-detail scene.
function isMemberClusterRelation(source, target, groupsById) {
  const member = source.kind === "endpoint-member" ? source : (target.kind === "endpoint-member" ? target : null)
  if (!member) return null

  const other = member === source ? target : source
  const group = groupsById.get(member.clusterId)
  if (!group || (other.id !== group.anchorId && other.id !== group.gatewayId)) return null
  return {group, member}
}

function renderedRelationEndpoints(source, target, hasAttachmentEvidence) {
  const ordered = [source, target].sort((left, right) => left.id.localeCompare(right.id))
  if (!hasAttachmentEvidence) return ordered

  const isSatellite = (node) =>
    node.kind === "endpoint-summary" ||
    node.kind === "endpoint-member" ||
    node.topologyPlane === "attachment"
  const leftIsSatellite = isSatellite(ordered[0])
  const rightIsSatellite = isSatellite(ordered[1])
  return leftIsSatellite !== rightIsSatellite && leftIsSatellite
    ? [ordered[1], ordered[0]]
    : ordered
}

function relations(graph, indexedNodes, groups) {
  const sourceEdges = Array.isArray(graph?.edges) ? graph.edges : []
  const groupsById = new Map(groups.map((group) => [group.id, group]))
  const rendered = new Map()
  const memberSemanticIds = new Map()
  let semanticEdges = 0
  let attachmentEdges = 0

  for (const edge of sourceEdges) {
    const source = indexedNodes[Number(edge?.source)]
    const target = indexedNodes[Number(edge?.target)]
    if (!source || !target || source.id === target.id) continue

    semanticEdges += 1
    const attachmentRelation = isAttachmentRelation(edge)
    if (attachmentRelation) attachmentEdges += 1
    const relationId = semanticRelationId(edge, source.id, target.id)
    const memberAnchor = isMemberClusterRelation(source, target, groupsById)
    if (memberAnchor) {
      const current = memberSemanticIds.get(memberAnchor.member.id) || []
      current.push(relationId)
      memberSemanticIds.set(memberAnchor.member.id, current)
      continue
    }

    const id = canonicalRenderedRelationId(source.id, target.id)
    const [left, right] = [source, target].sort(
      (leftNode, rightNode) => leftNode.id.localeCompare(rightNode.id),
    )
    const current = rendered.get(id) || {
      id,
      left,
      right,
      hasAttachmentEvidence: false,
      relationIds: [],
    }
    current.hasAttachmentEvidence = current.hasAttachmentEvidence || attachmentRelation
    current.relationIds.push(relationId)
    rendered.set(id, current)
  }

  const renderedRelations = Array.from(rendered.values())
    .map((relation) => {
      const [source, target] = renderedRelationEndpoints(
        relation.left,
        relation.right,
        relation.hasAttachmentEvidence,
      )
      return {
        id: relation.id,
        sourceId: source.id,
        targetId: target.id,
        relationIds: sortedUnique(relation.relationIds),
      }
    })
    .sort((left, right) => left.id.localeCompare(right.id))
  const layoutRelations = groups
    .filter((group) => group.expanded)
    .flatMap((group) =>
      group.memberIds.map((memberId) => ({
        id: `layout:${group.gatewayId}|${memberId}`,
        sourceId: group.gatewayId,
        targetId: memberId,
        relationIds: sortedUnique(memberSemanticIds.get(memberId) || []),
      })),
    )
    .sort((left, right) => left.id.localeCompare(right.id))

  return {semanticEdges, attachmentEdges, renderedRelations, layoutRelations}
}

function graphKeyFor({nodes, groups, renderedRelations, layoutRelations}) {
  return JSON.stringify({nodes, groups, renderedRelations, layoutRelations})
}

export function prepareTopologySceneInput(graph) {
  const indexedNodes = sceneNodes(graph)
  const groups = discoverGroups(indexedNodes)
  const nodes = nodeSceneRecords(indexedNodes, groups)
  const {semanticEdges, attachmentEdges, renderedRelations, layoutRelations} = relations(graph, indexedNodes, groups)
  const manifest = {
    nodes: indexedNodes.length,
    semanticEdges,
    attachmentEdges,
    renderedRoutes: renderedRelations.length,
    renderedGlyphs: nodes.filter((node) => node.render).length,
  }

  return {
    nodes,
    groups,
    renderedRelations,
    layoutRelations,
    graphKey: graphKeyFor({nodes, groups, renderedRelations, layoutRelations}),
    manifest,
  }
}

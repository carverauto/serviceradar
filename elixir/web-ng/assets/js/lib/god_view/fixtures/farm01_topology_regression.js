export const FARM01_EXPECTED = Object.freeze({
  collapsed: {nodes: 30, semanticEdges: 34, attachmentEdges: 24, renderedRoutes: 32, renderedGlyphs: 30},
  expanded: {nodes: 54, semanticEdges: 58, attachmentEdges: 48, renderedRoutes: 32, renderedGlyphs: 53},
  addedMemberCount: 24,
})

const EXPANDED_CLUSTER_ID = "cluster:endpoints:farm01:gateway-01"

function infrastructureNodes() {
  return Array.from({length: 6}, (_, index) => {
    const ordinal = index + 1
    const id = `farm01:gateway-${String(ordinal).padStart(2, "0")}`
    const clusterId = ordinal === 1 ? EXPANDED_CLUSTER_ID : `cluster:endpoints:farm01:gateway-${String(ordinal).padStart(2, "0")}`

    return {
      id,
      label: `Farm01 gateway ${ordinal}`,
      state: ordinal % 4,
      operUp: 1,
      details: {
        cluster_id: clusterId,
        cluster_kind: "endpoint-anchor",
        cluster_anchor_id: id,
      },
    }
  })
}

function summaryNodes() {
  return Array.from({length: 6}, (_, index) => {
    const ordinal = index + 1
    const anchorId = `farm01:gateway-${String(ordinal).padStart(2, "0")}`
    const clusterId = ordinal === 1 ? EXPANDED_CLUSTER_ID : `cluster:endpoints:farm01:gateway-${String(ordinal).padStart(2, "0")}`

    return {
      id: `farm01:endpoint-summary-${String(ordinal).padStart(2, "0")}`,
      label: `${ordinal * 4} endpoints`,
      state: 1,
      operUp: 1,
      clusterCount: ordinal * 4,
      details: {
        cluster_id: clusterId,
        cluster_kind: "endpoint-summary",
        cluster_anchor_id: anchorId,
        cluster_expanded: false,
      },
    }
  })
}

function attachmentNodes() {
  return Array.from({length: 18}, (_, index) => ({
    id: `farm01:attachment-${String(index + 1).padStart(2, "0")}`,
    label: `Farm01 attachment ${index + 1}`,
    state: (index + 2) % 4,
    operUp: 1,
    details: {topology_plane: "attachment"},
  }))
}

function backboneEdges() {
  return [
    [0, 1, "farm01:backbone:01"],
    [1, 0, "farm01:backbone:02-reverse"],
    [1, 2, "farm01:backbone:03"],
    [2, 3, "farm01:backbone:04"],
    [3, 2, "farm01:backbone:05-reverse"],
    [3, 4, "farm01:backbone:06"],
    [4, 5, "farm01:backbone:07"],
    [5, 0, "farm01:backbone:08"],
    [0, 2, "farm01:backbone:09"],
    [3, 5, "farm01:backbone:10"],
  ].map(([source, target, id]) => ({id, source, target, topologyClass: "backbone"}))
}

function collapsedAttachmentEdges() {
  const summaries = Array.from({length: 6}, (_, index) => ({
    id: `farm01:attachment:summary-${String(index + 1).padStart(2, "0")}`,
    source: index,
    target: 6 + index,
    topologyClass: "endpoints",
    evidenceClass: "endpoint-attachment",
  }))
  const attachments = Array.from({length: 18}, (_, index) => ({
    id: `farm01:attachment:device-${String(index + 1).padStart(2, "0")}`,
    source: index % 6,
    target: 12 + index,
    topologyClass: "endpoints",
    evidenceClass: "endpoint-attachment",
  }))

  return [...summaries, ...attachments]
}

function baseGraph() {
  const nodes = [...infrastructureNodes(), ...summaryNodes(), ...attachmentNodes()]
  return {nodes, edges: [...backboneEdges(), ...collapsedAttachmentEdges()]}
}

export function collapsedFarm01Graph() {
  return baseGraph()
}

export function expandedFarm01Graph() {
  const graph = baseGraph()
  const nodes = graph.nodes.map((node) => {
    if (node.id !== "farm01:endpoint-summary-01") return node
    return {
      ...node,
      details: {...node.details, cluster_expanded: true},
    }
  })
  // The server attaches each member to its summary/cluster node, never straight to the anchor.
  // Parenting these on the anchor instead made the island regression unreproducible: the member
  // already had a visible counterpart, so nothing exercised the re-parenting path.
  const summaryIndex = nodes.findIndex((node) => node.id === "farm01:endpoint-summary-01")
  const members = Array.from({length: FARM01_EXPECTED.addedMemberCount}, (_, index) => ({
    id: `farm01:endpoint-member-${String(index + 1).padStart(2, "0")}`,
    label: `Farm01 endpoint ${index + 1}`,
    state: 1,
    operUp: 1,
    details: {
      cluster_id: EXPANDED_CLUSTER_ID,
      cluster_kind: "endpoint-member",
      cluster_anchor_id: "farm01:gateway-01",
      cluster_expanded: true,
    },
  }))
  const memberEdges = members.map((_, index) => ({
    id: `farm01:attachment:member-${String(index + 1).padStart(2, "0")}`,
    source: summaryIndex,
    target: nodes.length + index,
    topologyClass: "endpoints",
    evidenceClass: "endpoint-attachment",
  }))

  return {nodes: [...nodes, ...members], edges: [...graph.edges, ...memberEdges]}
}

export function reverseGraphArrays(graph) {
  const originalNodes = Array.isArray(graph?.nodes) ? graph.nodes : []
  const originalEdges = Array.isArray(graph?.edges) ? graph.edges : []
  const nodes = [...originalNodes].reverse().map((node) => ({
    ...node,
    details: node?.details && typeof node.details === "object" ? {...node.details} : node?.details,
  }))
  const reversedIndexById = new Map(nodes.map((node, index) => [node.id, index]))

  return {
    ...graph,
    nodes,
    edges: [...originalEdges]
      .reverse()
      .map((edge) => ({
        ...edge,
        source: reversedIndexById.get(originalNodes[Number(edge.source)]?.id),
        target: reversedIndexById.get(originalNodes[Number(edge.target)]?.id),
      })),
  }
}

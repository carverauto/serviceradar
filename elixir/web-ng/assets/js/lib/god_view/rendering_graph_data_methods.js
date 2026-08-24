function isEndpointCensusSummary(node) {
  return String(node?.details?.cluster_kind || "").trim() === "endpoint-summary"
}

function isClusterExpanded(node) {
  const value = node?.details?.cluster_expanded
  return value === true || value === "true" || value === 1
}

function finiteRoutePath(points) {
  if (!Array.isArray(points)) return []
  if (!points.every((point) => Number.isFinite(Number(point?.x)) && Number.isFinite(Number(point?.y)))) return []
  return points.map((point) => [Number(point.x), Number(point.y), 0])
}

function midpointOnPath(path) {
  if (!Array.isArray(path) || path.length === 0) return [0, 0, 0]
  if (path.length === 1) return [...path[0]]

  const lengths = []
  let totalLength = 0
  for (let index = 1; index < path.length; index += 1) {
    const previous = path[index - 1]
    const point = path[index]
    const length = Math.hypot(point[0] - previous[0], point[1] - previous[1])
    lengths.push(length)
    totalLength += length
  }

  if (totalLength === 0) return [...path[0]]
  const midpointDistance = totalLength / 2
  let traversed = 0
  for (let index = 1; index < path.length; index += 1) {
    const length = lengths[index - 1]
    if (traversed + length >= midpointDistance) {
      const t = length === 0 ? 0 : (midpointDistance - traversed) / length
      const previous = path[index - 1]
      const point = path[index]
      return [
        previous[0] + ((point[0] - previous[0]) * t),
        previous[1] + ((point[1] - previous[1]) * t),
        0,
      ]
    }
    traversed += length
  }

  return [...path[path.length - 1]]
}

function rawRelationId(edge, nodes) {
  const explicitId = String(edge?.id || edge?.edge_id || "").trim()
  if (explicitId !== "") return explicitId

  const sourceId = String(nodes[Number(edge?.source)]?.id || "").trim()
  const targetId = String(nodes[Number(edge?.target)]?.id || "").trim()
  const [left, right] = [sourceId, targetId].sort((a, b) => a.localeCompare(b))
  const topologyClass = String(edge?.topologyClass || "").trim().toLowerCase() || "unknown"
  const label = String(edge?.label || "").trim()
  return `semantic:${left}|${right}|${topologyClass}|${label}`
}

export function hasManagedTopologySceneRoutes(effective) {
  return (
    effective?.shape === "local" &&
    effective?._layoutMode === "elk-scene" &&
    Array.isArray(effective?._topologyScene?.routes)
  )
}

export const godViewRenderingGraphDataMethods = {
  buildVisibleGraphData(effective) {
    const states = Uint8Array.from(effective.nodes.map((node) => node.state))
    const stateMask = this.visibilityMask(states)
    const mask = new Uint8Array(effective.nodes.length)
    const topologyLayers = this.state.topologyLayers || {}
    const endpointIncidentFlags =
      effective.shape === "local"
        ? effective.nodes.map(() => ({endpoint: false, nonEndpoint: false}))
        : null

    const edgeTopologyClass = (edge) => {
      if (typeof this.edgeTopologyClass === "function") {
        return this.edgeTopologyClass(edge)
      }

      const normalized = String(edge?.topologyClass || "").trim().toLowerCase()
      if (normalized === "endpoint") return "endpoints"
      return normalized || "unknown"
    }

    const attachmentCensusEdge = (edge) => {
      if (effective.shape !== "local" || topologyLayers.backbone === false) return false
      if (edgeTopologyClass(edge) !== "endpoints") return false

      const source = effective.nodes[Number(edge?.source)]
      const target = effective.nodes[Number(edge?.target)]
      return isEndpointCensusSummary(source) || isEndpointCensusSummary(target)
    }

    const expandedMemberEdge = (edge) => {
      if (effective.shape !== "local") return false
      const source = effective.nodes[Number(edge?.source)]
      const target = effective.nodes[Number(edge?.target)]
      const expandedMember = (node) =>
        String(node?.details?.cluster_kind || "").trim() === "endpoint-member" && isClusterExpanded(node)
      return expandedMember(source) || expandedMember(target)
    }

    if (endpointIncidentFlags) {
      for (const edge of effective.edges) {
        const topologyClass = edgeTopologyClass(edge)
        const endpointOnly = topologyClass === "endpoints"
        const source = Number(edge?.source)
        const target = Number(edge?.target)

        for (const index of [source, target]) {
          if (!Number.isInteger(index) || index < 0 || index >= endpointIncidentFlags.length) continue

          if (endpointOnly) {
            endpointIncidentFlags[index].endpoint = true
          } else {
            endpointIncidentFlags[index].nonEndpoint = true
          }
        }
      }
    }

    for (let i = 0; i < effective.nodes.length; i += 1) {
      const node = effective.nodes[i]
      const details = node?.details && typeof node.details === "object" ? node.details : {}
      const stateVisible = stateMask[i] === 1
      const clusterKind = String(details.cluster_kind || "").trim()
      const expandedSummary = isEndpointCensusSummary(node) && isClusterExpanded(node)
      const attachmentCensusVisible =
        topologyLayers.backbone !== false && isEndpointCensusSummary(node) && !expandedSummary
      const expandedMemberVisible =
        clusterKind === "endpoint-member" && isClusterExpanded(node)
      const endpointAnchorVisible = clusterKind === "endpoint-anchor"
      const endpointLayerVisible =
        !expandedSummary &&
        (!endpointIncidentFlags ||
          topologyLayers.endpoints !== false ||
          attachmentCensusVisible ||
          expandedMemberVisible ||
          endpointAnchorVisible ||
          endpointIncidentFlags[i].nonEndpoint ||
          !endpointIncidentFlags[i].endpoint)

      mask[i] = stateVisible && endpointLayerVisible ? 1 : 0
    }

    const visibleNodes = effective.nodes.map((node, index) => ({
      ...node,
      index,
      selected: this.state.selectedNodeIndex === index,
      visible: mask[index] === 1,
      zHeight: 0,
    }))
    const visibleById = new Map(visibleNodes.map((node) => [node.id, node]))
    const resolveVisibleEndpoint = (node) => {
      if (!node) return null
      if (node.visible) return node
      if (!isEndpointCensusSummary(node) || !isClusterExpanded(node)) return null
      const anchorId = String(node?.details?.cluster_anchor_id || "").trim()
      if (anchorId === "") return null
      const anchor = visibleById.get(anchorId)
      return anchor?.visible ? anchor : null
    }

    const rawEdgeData = effective.edges
      .filter((edge) => this.edgeEnabledByTopologyLayer(edge) || attachmentCensusEdge(edge) || expandedMemberEdge(edge))
      .map((edge, edgeIndex) => {
        const src =
          effective.shape === "local"
            ? resolveVisibleEndpoint(visibleNodes[edge.source])
            : visibleById.get(edge.sourceCluster)
        const dst =
          effective.shape === "local"
            ? resolveVisibleEndpoint(visibleNodes[edge.target])
            : visibleById.get(edge.targetCluster)
        if (!src || !dst || !src.visible || !dst.visible) return null
        if (src.id === dst.id) return null
        const label =
          effective.shape === "local"
            ? String(edge.label || `${src.label || src.id || "node"} -> ${dst.label || dst.id || "node"}`)
            : `${this.formatPps(edge.flowPps || 0)} / ${this.formatCapacity(edge.capacityBps || 0)}`
        const connectionLabel = this.connectionKindFromLabel(label)
        const sourceId = effective.shape === "local" ? src.id : src.id || edge.sourceCluster || "src"
        const targetId = effective.shape === "local" ? dst.id : dst.id || edge.targetCluster || "dst"
        const rawEdgeId = edge.id || edge.edge_id || edge.label || edge.type || `${sourceId}:${targetId}:${edgeIndex}`
        const telemetryEligible = edge.telemetryEligible === false || edge.telemetry_eligible === false
          ? false
          : true
        const topologyClass = edgeTopologyClass(edge)
        return {
          sourceId,
          targetId,
          sourcePosition: [src.x, src.y, 0],
          targetPosition: [dst.x, dst.y, 0],
          weight: edge.weight || 1,
          flowPps: Number(edge.flowPps || 0),
          flowPpsAb: Number(edge.flowPpsAb || 0),
          flowPpsBa: Number(edge.flowPpsBa || 0),
          flowBps: Number(edge.flowBps || 0),
          flowBpsAb: Number(edge.flowBpsAb || 0),
          flowBpsBa: Number(edge.flowBpsBa || 0),
          capacityBps: Number(edge.capacityBps || 0),
          midpoint: [(src.x + dst.x) / 2, (src.y + dst.y) / 2, 0],
          label: label.length > 56 ? `${label.slice(0, 56)}...` : label,
          connectionLabel,
          telemetryEligible,
          topologyClass,
          topologyClassCounts: edge.topologyClassCounts || null,
          protocol: String(edge.protocol || ""),
          evidenceClass: String(edge.evidenceClass || ""),
          details: edge.details && typeof edge.details === "object" ? edge.details : {},
          edgeCount: Number(edge.weight || 1),
          interactionKey: `${effective.shape}:${rawEdgeId}`,
        }
      })
      .filter(Boolean)

    const managedTopologyScene = hasManagedTopologySceneRoutes(effective)
    const edgeData = managedTopologyScene
      ? this.buildTopologySceneEdgeData(effective, edgeTopologyClass)
      : this.aggregateVisibleEdges(this.collapseExpandedMemberTrunks(rawEdgeData, visibleNodes))
    const edgeKeys = new Set(edgeData.map((edge) => edge.interactionKey))
    if (this.state.hoveredEdgeKey && !edgeKeys.has(this.state.hoveredEdgeKey)) this.state.hoveredEdgeKey = null
    if (this.state.selectedEdgeKey && !edgeKeys.has(this.state.selectedEdgeKey)) this.state.selectedEdgeKey = null
    const edgeLabelData = this.selectEdgeLabels(edgeData, effective.shape)

    const nodeData = visibleNodes
      .filter((node) => node.visible)
      .map((node) => ({
        id: node.id,
        position: [node.x, node.y, 0],
        zHeight: 0,
        index: node.index,
        state: node.state,
        selected: node.selected,
        clusterCount: node.clusterCount || 1,
        pps: Number(node.pps || 0),
        operUp: Number(node.operUp || 0),
        details: node.details || {},
        label:
          this.normalizeDisplayLabel(node.label, node.id || `node-${node.index + 1}`),
        metricText: this.nodeMetricText(node, effective.shape),
        statusIcon: this.nodeStatusIcon(node.operUp),
        stateReason: this.stateReasonForNode(node, edgeData, visibleNodes),
      }))
    const rootPulseNodes = nodeData.filter((node) => node.state === 0)

    this.state.lastVisibleNodeCount = nodeData.length
    this.state.lastVisibleEdgeCount = edgeData.length

    const selectedVisibleNode =
      effective.shape !== "local" || this.state.selectedNodeIndex === null
        ? null
        : nodeData.find((node) => node.index === this.state.selectedNodeIndex)

    return {edgeData, edgeLabelData, nodeData, rootPulseNodes, selectedVisibleNode}
  },
  buildTopologySceneEdgeData(effective, edgeTopologyClass) {
    const routes = effective?._topologyScene?.routes || []
    const relationById = new Map(
      (effective.edges || []).map((edge) => [rawRelationId(edge, effective.nodes || []), edge]),
    )
    const nodeByIndex = effective.nodes || []
    const classBuckets = ["backbone", "logical", "hosted", "inferred", "observed", "endpoints", "unknown"]
    const emptyClassCounts = () => Object.fromEntries(classBuckets.map((bucket) => [bucket, 0]))
    const classBucketForEdge = (edge) => {
      const topologyClass = String(edgeTopologyClass(edge) || "").trim().toLowerCase()
      return classBuckets.includes(topologyClass) ? topologyClass : "unknown"
    }
    const dominantClass = (counts) => classBuckets
      .map((bucket) => [bucket, Number(counts[bucket] || 0)])
      .sort((left, right) => right[1] - left[1] || left[0].localeCompare(right[0]))[0][1] > 0
      ? classBuckets
        .map((bucket) => [bucket, Number(counts[bucket] || 0)])
        .sort((left, right) => right[1] - left[1] || left[0].localeCompare(right[0]))[0][0]
      : "unknown"

    return routes
      .map((route) => {
        const path = finiteRoutePath(route?.points)
        if (path.length < 2) return null

        const relationIds = Array.isArray(route?.relationIds)
          ? [...route.relationIds].sort((left, right) => String(left).localeCompare(String(right)))
          : []
        const relations = relationIds.map((relationId) => relationById.get(relationId)).filter(Boolean)
        const metadata = route?.metadata && typeof route.metadata === "object" ? route.metadata : {}
        const topologyClassCounts = emptyClassCounts()
        const directional = {
          flowPpsAb: 0,
          flowPpsBa: 0,
          flowBpsAb: 0,
          flowBpsBa: 0,
        }

        for (const relation of relations) {
          const sourceId = String(nodeByIndex[Number(relation?.source)]?.id || "")
          const targetId = String(nodeByIndex[Number(relation?.target)]?.id || "")
          const reversed = sourceId === route.targetId && targetId === route.sourceId
          directional.flowPpsAb += Number(reversed ? relation.flowPpsBa : relation.flowPpsAb) || 0
          directional.flowPpsBa += Number(reversed ? relation.flowPpsAb : relation.flowPpsBa) || 0
          directional.flowBpsAb += Number(reversed ? relation.flowBpsBa : relation.flowBpsAb) || 0
          directional.flowBpsBa += Number(reversed ? relation.flowBpsAb : relation.flowBpsBa) || 0
          const bucket = classBucketForEdge(relation)
          topologyClassCounts[bucket] += 1
        }

        const metadataNumber = (field) => {
          if (!Object.hasOwn(metadata, field)) return null
          const value = Number(metadata[field])
          return Number.isFinite(value) ? value : null
        }
        const numeric = (field, fallback = 0) => {
          const metadataValue = metadataNumber(field)
          if (metadataValue !== null) return metadataValue
          return relations.length > 0
            ? relations.reduce((total, relation) => total + (Number(relation?.[field]) || 0), 0)
            : fallback
        }
        const directionalNumeric = (field, fallback) => metadataNumber(field) ?? fallback
        const relationWeight = relations.reduce(
          (total, relation) => total + Math.max(1, Number(relation?.weight || 1)),
          0,
        ) || 1
        const relationCapacityBps = relations.length > 0
          ? Math.max(0, ...relations.map((relation) => Number(relation?.capacityBps) || 0))
          : 0
        const relationLabels = relations
          .map((relation) => String(relation?.label || "").trim())
          .filter(Boolean)
        const relationDetails = relations
          .map((relation) => relation?.details)
          .filter((details) => details && typeof details === "object")
        const label = String(metadata.label || relationLabels[0] || `${route.sourceId} -> ${route.targetId}`)
        const telemetryEligible = Object.hasOwn(metadata, "telemetryEligible") || Object.hasOwn(metadata, "telemetry_eligible")
          ? metadata.telemetryEligible !== false && metadata.telemetry_eligible !== false
          : relations.length > 0
            ? relations.some((relation) => relation?.telemetryEligible !== false && relation?.telemetry_eligible !== false)
            : true
        const protocols = Array.from(new Set(relations.map((relation) => String(relation?.protocol || "")).filter(Boolean))).sort()
        const evidenceClasses = Array.from(new Set(relations.map((relation) => String(relation?.evidenceClass || "")).filter(Boolean))).sort()

        return {
          sourceId: route.sourceId,
          targetId: route.targetId,
          sourcePosition: [...path[0]],
          targetPosition: [...path[path.length - 1]],
          path,
          relationIds,
          weight: metadataNumber("weight") ?? relationWeight,
          flowPps: numeric("flowPps"),
          flowPpsAb: directionalNumeric("flowPpsAb", directional.flowPpsAb),
          flowPpsBa: directionalNumeric("flowPpsBa", directional.flowPpsBa),
          flowBps: numeric("flowBps"),
          flowBpsAb: directionalNumeric("flowBpsAb", directional.flowBpsAb),
          flowBpsBa: directionalNumeric("flowBpsBa", directional.flowBpsBa),
          capacityBps: metadataNumber("capacityBps") ?? relationCapacityBps,
          midpoint: midpointOnPath(path),
          label: label.length > 56 ? `${label.slice(0, 56)}...` : label,
          connectionLabel: this.connectionKindFromLabel(label),
          telemetryEligible,
          topologyClass: dominantClass(topologyClassCounts),
          topologyClassCounts,
          protocol: protocols.length === 1 ? protocols[0] : "",
          evidenceClass: evidenceClasses.length === 1 ? evidenceClasses[0] : "",
          details: metadata.details && typeof metadata.details === "object"
            ? metadata.details
            : relationDetails.find((details) => Array.isArray(details.interface_sparkline) && details.interface_sparkline.length > 1) || relationDetails[0] || {},
          edgeCount: Math.max(1, relationIds.length),
          interactionKey: `local:${route.id}`,
        }
      })
      .filter(Boolean)
  },
  collapseExpandedMemberTrunks(edgeData, visibleNodes) {
    if (!Array.isArray(edgeData) || edgeData.length === 0) return []

    const nodeById = new Map((visibleNodes || []).map((node) => [node.id, node]))
    const trunks = new Map()
    const kept = []

    for (const edge of edgeData) {
      const clusterId = this.expandedMemberTrunkClusterId(edge, nodeById)
      if (!clusterId) {
        kept.push(edge)
        continue
      }

      const length = Math.hypot(
        Number(edge.sourcePosition?.[0] || 0) - Number(edge.targetPosition?.[0] || 0),
        Number(edge.sourcePosition?.[1] || 0) - Number(edge.targetPosition?.[1] || 0),
      )
      const current = trunks.get(clusterId)
      if (!current || length < current.length) {
        trunks.set(clusterId, {edge, length})
      }
    }

    for (const {edge} of trunks.values()) kept.push(edge)
    return kept
  },
  expandedMemberTrunkClusterId(edge, nodeById) {
    const source = nodeById.get(edge?.sourceId)
    const target = nodeById.get(edge?.targetId)
    if (!source || !target) return ""

    const member = this.expandedEndpointMemberNode(source)
      ? source
      : (this.expandedEndpointMemberNode(target) ? target : null)
    const other = member === source ? target : source
    if (!member || !other) return ""

    const clusterId = String(member.details?.cluster_id || "").trim()
    if (clusterId === "") return ""

    const anchorId = String(member.details?.cluster_anchor_id || "").trim()
    const otherIsAnchor =
      (anchorId !== "" && other.id === anchorId) ||
      (String(other.details?.cluster_kind || "").trim() === "endpoint-anchor" &&
        String(other.details?.cluster_id || "").trim() === clusterId)

    return otherIsAnchor ? clusterId : ""
  },
  expandedEndpointMemberNode(node) {
    return String(node?.details?.cluster_kind || "").trim() === "endpoint-member" && isClusterExpanded(node)
  },
  aggregateVisibleEdges(edgeData) {
    if (!Array.isArray(edgeData) || edgeData.length === 0) return []

    const acc = new Map()

    const emptyClassCounts = () => ({
      backbone: 0,
      logical: 0,
      hosted: 0,
      inferred: 0,
      observed: 0,
      endpoints: 0,
      unknown: 0,
    })

    const classBucketForEdge = (edge) => {
      const classCounts = edge?.topologyClassCounts
      if (classCounts && typeof classCounts === "object") {
        const buckets = ["backbone", "logical", "hosted", "inferred", "observed", "endpoints", "unknown"]
        let bestBucket = "unknown"
        let bestCount = 0

        for (const bucket of buckets) {
          const count = Number(classCounts[bucket] || 0)
          if (count > bestCount) {
            bestBucket = bucket
            bestCount = count
          }
        }

        if (bestCount > 0) return bestBucket
      }

      const topologyClass = String(edge?.topologyClass || "").trim().toLowerCase()
      if (topologyClass === "backbone") return "backbone"
      if (topologyClass === "logical") return "logical"
      if (topologyClass === "hosted") return "hosted"
      if (topologyClass === "inferred") return "inferred"
      if (topologyClass === "observed") return "observed"
      if (topologyClass === "endpoint" || topologyClass === "endpoints") return "endpoints"
      return "unknown"
    }

    const canonicalPair = (edge) => {
      const sourceId = String(edge?.sourceId || "")
      const targetId = String(edge?.targetId || "")
      return sourceId.localeCompare(targetId) <= 0
        ? {left: sourceId, right: targetId, forward: true}
        : {left: targetId, right: sourceId, forward: false}
    }

    const edgeSignature = (edge) => {
      const pair = canonicalPair(edge)
      const topologyClass = classBucketForEdge(edge)
      return `${pair.left}|${pair.right}|${topologyClass}`
    }

    for (const edge of edgeData) {
      const pair = canonicalPair(edge)
      const key = `${pair.left}|${pair.right}`
      const classBucket = classBucketForEdge(edge)
      const current = acc.get(key) || {
        sourceId: pair.left,
        targetId: pair.right,
        sourcePosition: pair.forward ? edge.sourcePosition : edge.targetPosition,
        targetPosition: pair.forward ? edge.targetPosition : edge.sourcePosition,
        weight: 0,
        flowPps: 0,
        flowPpsAb: 0,
        flowPpsBa: 0,
        flowBps: 0,
        flowBpsAb: 0,
        flowBpsBa: 0,
        capacityBps: 0,
        midpoint: pair.forward ? edge.midpoint : edge.midpoint,
        label: edge.label,
        connectionLabel: edge.connectionLabel,
        telemetryEligible: false,
        topologyClass: "",
        topologyClassCounts: emptyClassCounts(),
        protocol: String(edge.protocol || ""),
        evidenceClass: String(edge.evidenceClass || ""),
        edgeCount: 0,
        interactionKey: `${edge.interactionKey.split(":")[0]}:pair:${pair.left}:${pair.right}`,
        signatures: new Set(),
        labels: new Set(),
        protocols: new Set(),
        evidenceClasses: new Set(),
        detailsList: [],
      }

      const edgeWeight = Math.max(1, Number(edge.weight || edge.edgeCount || 1))
      const flowPpsAb = Number(edge.flowPpsAb || 0)
      const flowPpsBa = Number(edge.flowPpsBa || 0)
      const flowBpsAb = Number(edge.flowBpsAb || 0)
      const flowBpsBa = Number(edge.flowBpsBa || 0)

      current.weight += edgeWeight
      current.flowPps += Number(edge.flowPps || 0)
      current.flowPpsAb += pair.forward ? flowPpsAb : flowPpsBa
      current.flowPpsBa += pair.forward ? flowPpsBa : flowPpsAb
      current.flowBps += Number(edge.flowBps || 0)
      current.flowBpsAb += pair.forward ? flowBpsAb : flowBpsBa
      current.flowBpsBa += pair.forward ? flowBpsBa : flowBpsAb
      current.capacityBps = Math.max(current.capacityBps, Number(edge.capacityBps || 0))
      current.telemetryEligible = current.telemetryEligible || edge.telemetryEligible !== false
      current.edgeCount += Math.max(1, Number(edge.edgeCount || 1))
      current.topologyClassCounts[classBucket] = Number(current.topologyClassCounts[classBucket] || 0) + 1
      current.signatures.add(edgeSignature(edge))
      if (edge.label) current.labels.add(String(edge.label))
      if (edge.protocol) current.protocols.add(String(edge.protocol))
      if (edge.evidenceClass) current.evidenceClasses.add(String(edge.evidenceClass))
      if (edge.details && typeof edge.details === "object") current.detailsList.push(edge.details)
      acc.set(key, current)
    }

    const aggregated = Array.from(acc.values()).map((edge) => {
      const labels = Array.from(edge.labels)
      const protocols = Array.from(edge.protocols).sort()
      const evidenceClasses = Array.from(edge.evidenceClasses).sort()
      const classBuckets = Object.entries(edge.topologyClassCounts || {})
        .filter(([, count]) => Number(count || 0) > 0)
        .sort((left, right) => Number(right[1] || 0) - Number(left[1] || 0))
      const dominantClass = classBuckets.length === 1 ? classBuckets[0][0] : ""
      const detailCandidates = Array.isArray(edge.detailsList) ? edge.detailsList : []
      const details =
        detailCandidates.find((candidate) => Array.isArray(candidate.interface_sparkline) && candidate.interface_sparkline.length > 1) ||
        detailCandidates[0] ||
        {}
      const {signatures: _signatures, labels: _labels, protocols: _protocols, evidenceClasses: _evidenceClasses, detailsList: _detailsList, ...plainEdge} = edge

      return {
        ...plainEdge,
        details,
        label: labels[0] || edge.label,
        topologyClass: dominantClass,
        protocol: protocols.length === 1 ? protocols[0] : "",
        evidenceClass: evidenceClasses.length === 1 ? evidenceClasses[0] : "",
        labels,
        protocols,
        evidenceClasses,
        edgeCount: Math.max(edge.edgeCount, edge.signatures.size),
      }
    })

    aggregated.sort((left, right) => {
      const leftWeight = Number(left.edgeCount || 0)
      const rightWeight = Number(right.edgeCount || 0)
      return rightWeight - leftWeight || left.sourceId.localeCompare(right.sourceId) || left.targetId.localeCompare(right.targetId)
    })

    return aggregated
  },
}

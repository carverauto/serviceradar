export const EMPTY_HORIZON_EGRESS_DATA = Object.freeze({
  egress_devices: [],
  external_nodes: [],
  edges: [],
  max_hops: 0,
  truncated: false,
})

const OUTAGE_STATES = new Set(["outage", "critical", "down", "major"])
const DEGRADED_STATES = new Set(["degraded", "warning", "partial"])
const HEALTHY_STATES = new Set(["healthy", "ok", "up"])

const KIND_PRIORITY = {
  Prefix: 1,
  IXP: 2,
  Vantage: 3,
  Facility: 4,
  TransitRouter: 5,
  ASN: 6,
  AnycastPop: 7,
  SaasTarget: 8,
}

export function normalizeHorizonEgressData(raw) {
  if (!raw || typeof raw !== "object") return EMPTY_HORIZON_EGRESS_DATA
  return {
    egress_devices: Array.isArray(raw.egress_devices) ? raw.egress_devices : [],
    external_nodes: Array.isArray(raw.external_nodes) ? raw.external_nodes : [],
    edges: Array.isArray(raw.edges) ? raw.edges : [],
    max_hops: Number.isFinite(Number(raw.max_hops)) ? Number(raw.max_hops) : 0,
    truncated: raw.truncated === true,
  }
}

export function formatPortSpeedMbps(rawMbps) {
  const mbps = Number(rawMbps)
  if (!Number.isFinite(mbps) || mbps <= 0) return ""
  if (mbps >= 1000) {
    const gbps = (mbps / 1000).toFixed(1).replace(/\.0$/, "")
    return `${gbps}G`
  }
  return `${Math.round(mbps)}M`
}

function parseOptionalNumber(raw) {
  if (raw === null || raw === undefined || typeof raw === "boolean") return null
  if (typeof raw === "string" && raw.trim() === "") return null
  const num = Number(raw)
  return Number.isFinite(num) ? num : null
}

function validPositiveAsn(rawAsn) {
  const asn = parseOptionalNumber(rawAsn)
  return asn !== null && asn > 0 ? asn : null
}

export function formatRttUs(rawUs) {
  const us = parseOptionalNumber(rawUs)
  if (us === null || us < 0) return ""
  const ms = us / 1000
  if (ms < 1) return `${Math.round(us)}us`
  if (ms < 100) return `${ms.toFixed(1)}ms`
  return `${Math.round(ms)}ms`
}

export function formatLossPct(rawLoss) {
  const loss = parseOptionalNumber(rawLoss)
  if (loss === null || loss < 0) return ""
  return `${loss.toFixed(1)}%`
}

export function horizonSeverity(entity) {
  if (!entity || typeof entity !== "object") return "neutral"
  const outage = String(entity.outage_state || "").trim().toLowerCase()
  const rpki = String(entity.rpki_state || "").trim().toLowerCase()
  const rtbh = entity.rtbh_active === true
  const loss = parseOptionalNumber(entity.loss_pct)

  if (OUTAGE_STATES.has(outage) || rtbh) return "outage"
  if (DEGRADED_STATES.has(outage) || rpki === "invalid" || (loss !== null && loss > 2)) {
    return "degraded"
  }
  if (rpki === "valid" || HEALTHY_STATES.has(outage)) return "healthy"
  return "neutral"
}

export function horizonSeverityRank(severity) {
  if (severity === "outage") return 3
  if (severity === "degraded") return 2
  if (severity === "healthy") return 1
  return 0
}

export function horizonEntityBadges(entity) {
  if (!entity || typeof entity !== "object") return []
  const badges = []
  const outage = String(entity.outage_state || "").trim().toLowerCase()
  const rpki = String(entity.rpki_state || "").trim().toLowerCase()

  if (OUTAGE_STATES.has(outage)) badges.push("[OUTAGE]")
  else if (DEGRADED_STATES.has(outage)) badges.push("[DEGRADED]")

  if (rpki === "invalid") badges.push("[RPKI INVALID]")
  if (entity.rtbh_active === true) badges.push("[RTBH]")

  const speed = formatPortSpeedMbps(entity.port_speed_mbps)
  if (speed) badges.push(speed)

  return badges
}

export function horizonNodeDisplayLabel(node) {
  if (!node || typeof node !== "object") return "external"
  const kind = String(node.kind || "").trim()
  const label = typeof node.label === "string" ? node.label.trim() : ""
  const asn = Number(node.asn)

  if (kind === "ASN" && Number.isFinite(asn) && asn > 0) {
    return label ? `AS${asn} · ${label}` : `AS${asn}`
  }
  return label || String(node.id || "external")
}

export function horizonNodeLabelWithBadges(node) {
  const base = horizonNodeDisplayLabel(node)
  const badges = horizonEntityBadges(node)
  return badges.length > 0 ? `${base} ${badges.join(" ")}` : base
}

export function stripHorizonTargetId(rawId) {
  if (typeof rawId !== "string") return ""
  return rawId.trim().replace(/^(?:saas|target):/i, "")
}

export function horizonInspectUrl(entity, connectedNodes = []) {
  const base = "/dashboards/horizon"
  if (!entity || typeof entity !== "object") return `${base}#tab=weather_map`

  const kind = String(entity.kind || "").trim().toLowerCase()

  if (kind === "saastarget") {
    const targetId = stripHorizonTargetId(String(entity.target_id || entity.id || ""))
    if (targetId) return `${base}#tab=multipath_dag&target_id=${encodeURIComponent(targetId)}`
    return `${base}#tab=weather_map`
  }

  if (kind === "vantage") {
    const directTarget = stripHorizonTargetId(String(entity.target_id || ""))
    const connectedTarget = (connectedNodes || []).find(
      (node) => String(node?.kind || "").trim().toLowerCase() === "saastarget",
    )
    const targetId = directTarget || stripHorizonTargetId(String(connectedTarget?.id || ""))
    if (targetId) return `${base}#tab=multipath_dag&target_id=${encodeURIComponent(targetId)}`
    return `${base}#tab=weather_map`
  }

  if (kind === "asn" || kind === "prefix") {
    const connectedAsnNode = (connectedNodes || []).find((node) => validPositiveAsn(node?.asn) !== null)
    const asn =
      validPositiveAsn(entity.asn) ??
      validPositiveAsn(entity.border_asn) ??
      validPositiveAsn(connectedAsnNode?.asn)
    const prefix = entity.prefix || (kind === "prefix" ? entity.id : "")
    const params = ["tab=bgp_sankey"]
    if (asn !== null) {
      params.push(`origin_asn=${encodeURIComponent(String(asn))}`)
    }
    if (typeof prefix === "string" && prefix.trim() !== "") {
      params.push(`prefix=${encodeURIComponent(prefix.trim())}`)
    }
    if (params.length > 1) return `${base}#${params.join("&")}`
    return `${base}#tab=weather_map`
  }

  if (entity.horizonEntityType === "edge" || (entity.src_id && entity.dst_id)) {
    const endpoints = [entity.dstNode, entity.srcNode, ...(connectedNodes || [])].filter(Boolean)
    const saasNode = endpoints.find((node) => String(node.kind || "").trim().toLowerCase() === "saastarget")
    if (saasNode) {
      const targetId = stripHorizonTargetId(String(saasNode.target_id || saasNode.id || ""))
      if (targetId) return `${base}#tab=multipath_dag&target_id=${encodeURIComponent(targetId)}`
    }
    const asnNode = endpoints.find((node) => validPositiveAsn(node?.asn) !== null)
    const prefixNode = endpoints.find((node) => String(node.kind || "").trim().toLowerCase() === "prefix")
    const asn = validPositiveAsn(entity.border_asn) ?? validPositiveAsn(asnNode?.asn)
    const prefix = prefixNode?.id || ""
    const params = ["tab=bgp_sankey"]
    if (asn !== null) {
      params.push(`origin_asn=${encodeURIComponent(String(asn))}`)
    }
    if (typeof prefix === "string" && prefix.trim() !== "") {
      params.push(`prefix=${encodeURIComponent(prefix.trim())}`)
    }
    if (params.length > 1) return `${base}#${params.join("&")}`
  }

  return `${base}#tab=weather_map`
}

export function horizonSeverityColor(severity, visual = null, alpha = 235) {
  if (severity === "outage") {
    const base = visual?.nodeRoot || [255, 42, 122]
    return [base[0], base[1], base[2], alpha]
  }
  if (severity === "degraded") {
    const base = visual?.nodeAffected || [255, 154, 0]
    return [base[0], base[1], base[2], alpha]
  }
  if (severity === "healthy") {
    const base = visual?.nodeHealthy || [0, 230, 118]
    return [base[0], base[1], base[2], alpha]
  }
  return [56, 189, 248, alpha]
}

export function horizonEdgeColor(edge, visual = null, selected = false) {
  const alpha = selected ? 255 : 210
  if (edge?.severity === "outage") return horizonSeverityColor("outage", visual, alpha)
  if (edge?.severity === "degraded") return horizonSeverityColor("degraded", visual, alpha)
  const source = String(edge?.egress_source || "").trim().toLowerCase()
  if (source === "manual") return [20, 184, 166, alpha]
  if (source === "automagic" || source === "prefix_origin") return [96, 165, 250, selected ? 255 : 195]
  return [100, 181, 246, selected ? 255 : 185]
}

function nodeBounds(anchorNodes) {
  let minX = Infinity
  let maxX = -Infinity
  let minY = Infinity
  let maxY = -Infinity

  for (const node of anchorNodes) {
    const pos = node?.position
    if (!Array.isArray(pos) || pos.length < 2) continue
    const x = Number(pos[0])
    const y = Number(pos[1])
    if (!Number.isFinite(x) || !Number.isFinite(y)) continue
    if (x < minX) minX = x
    if (x > maxX) maxX = x
    if (y < minY) minY = y
    if (y > maxY) maxY = y
  }

  if (!Number.isFinite(minX)) {
    return {minX: 0, maxX: 0, minY: 0, maxY: 0, cx: 0, cy: 0, spanX: 240, spanY: 160}
  }
  return {
    minX,
    maxX,
    minY,
    maxY,
    cx: (minX + maxX) / 2,
    cy: (minY + maxY) / 2,
    spanX: Math.max(240, maxX - minX),
    spanY: Math.max(160, maxY - minY),
  }
}

export function buildHorizonEgressGraphLayout(rawData, sceneNodes, options = {}) {
  const data = normalizeHorizonEgressData(rawData)
  const deviceLookup = new Map()
  if (data.egress_devices.length === 0 || !Array.isArray(sceneNodes) || sceneNodes.length === 0) {
    return {nodes: [], edges: [], pulseNodes: [], deviceLookup}
  }

  const sceneNodeByKey = new Map()
  for (const node of sceneNodes) {
    if (!node || !Array.isArray(node.position) || node.position.length < 2) continue
    const x = Number(node.position[0])
    const y = Number(node.position[1])
    if (!Number.isFinite(x) || !Number.isFinite(y)) continue
    const pos = [x, y, 0]
    const keys = [node.id, node.details?.device_uid, node.details?.id, ...(node.aliases || [])]
    for (const key of keys) {
      if (typeof key === "string" && key.trim() !== "" && !sceneNodeByKey.has(key.trim())) {
        sceneNodeByKey.set(key.trim(), {node, position: pos})
      }
    }
  }

  const matchedAnchors = new Map()
  for (const device of data.egress_devices) {
    const devId = typeof device?.id === "string" ? device.id.trim() : ""
    if (!devId) continue
    const match = sceneNodeByKey.get(devId)
    if (!match) continue
    matchedAnchors.set(devId, {device, sceneNode: match.node, position: match.position})
  }

  if (matchedAnchors.size === 0) {
    return {nodes: [], edges: [], pulseNodes: [], deviceLookup}
  }

  const externalNodeById = new Map()
  for (const extNode of data.external_nodes) {
    const id = typeof extNode?.id === "string" ? extNode.id.trim() : ""
    if (id) externalNodeById.set(id, extNode)
  }

  const neighborsById = new Map()
  const addNeighbor = (fromId, toId, kind) => {
    if (!neighborsById.has(fromId)) neighborsById.set(fromId, [])
    const list = neighborsById.get(fromId)
    if (!list.some((entry) => entry.toId === toId && entry.kind === kind)) {
      list.push({toId, kind})
    }
  }
  for (const edge of data.edges) {
    const src = typeof edge?.src_id === "string" ? edge.src_id.trim() : ""
    const dst = typeof edge?.dst_id === "string" ? edge.dst_id.trim() : ""
    if (!src || !dst) continue
    const kind = String(edge?.kind || "").trim().toUpperCase()
    if (kind === "AS_REL_PROVIDER") {
      // Horizon writes AS_REL_PROVIDER as provider -> customer (src -> dst);
      // walk ONLY upstream from customer (dst) to provider (src) — never down into customer cones.
      addNeighbor(dst, src, kind)
    } else if (kind === "AS_REL_PEER") {
      addNeighbor(src, dst, kind)
      addNeighbor(dst, src, kind)
    } else {
      addNeighbor(src, dst, kind)
      // external_reads.rs emits ORIGIN_PREFIX as asn -> prefix, and non-anchor external
      // edges may connect bidirectionally; traverse reverse edges without crossing anchors.
      if (kind === "ORIGIN_PREFIX" || !matchedAnchors.has(src)) {
        addNeighbor(dst, src, kind)
      }
    }
  }

  // BFS from matched egress devices to find reachable external nodes and hop depth.
  const hopDepthById = new Map()
  const parentAnchorsById = new Map()
  const anchorIdsById = new Map()
  const firstParentById = new Map()
  const queue = []

  for (const [devId, anchor] of matchedAnchors.entries()) {
    hopDepthById.set(devId, 0)
    parentAnchorsById.set(devId, [anchor.position])
    anchorIdsById.set(devId, [devId])
    queue.push(devId)
  }

  let head = 0
  while (head < queue.length) {
    const currentId = queue[head++]
    const currentDepth = hopDepthById.get(currentId) ?? 0
    const neighbors = neighborsById.get(currentId) || []

    for (const {toId: nextId, kind} of neighbors) {
      if (!nextId || matchedAnchors.has(nextId) || !externalNodeById.has(nextId)) continue
      // Only traverse direct ISP peers (depth 1 -> 2), never explode transitive peers at depth >= 2.
      if (kind === "AS_REL_PEER" && currentDepth >= 2) continue

      const nextDepth = currentDepth + 1
      const existingDepth = hopDepthById.get(nextId)
      if (existingDepth !== undefined && nextDepth > existingDepth) continue

      const anchors = parentAnchorsById.get(currentId) || []
      const anchorIds = anchorIdsById.get(currentId) || []
      if (existingDepth === undefined || nextDepth < existingDepth) {
        hopDepthById.set(nextId, nextDepth)
        parentAnchorsById.set(nextId, [...anchors])
        anchorIdsById.set(nextId, [...anchorIds])
        firstParentById.set(nextId, currentId)
        queue.push(nextId)
      } else {
        const existingAnchors = parentAnchorsById.get(nextId) || []
        for (const anchorPos of anchors) {
          if (!existingAnchors.includes(anchorPos)) existingAnchors.push(anchorPos)
        }
        const existingAnchorIds = anchorIdsById.get(nextId) || []
        for (const aid of anchorIds) {
          if (!existingAnchorIds.includes(aid)) existingAnchorIds.push(aid)
        }
      }
    }
  }

  // Mark nodes that bridge to higher-tier nodes or non-ASN high-signal targets so they survive tier caps.
  const bridgeParentIds = new Set()
  for (const [childId, parentId] of firstParentById.entries()) {
    if (externalNodeById.has(parentId)) {
      bridgeParentIds.add(parentId)
    }
    const childNode = externalNodeById.get(childId)
    if (childNode && childNode.kind !== "ASN" && externalNodeById.has(parentId)) {
      bridgeParentIds.add(parentId)
    }
  }

  const reachableExternal = []
  for (const [id, extNode] of externalNodeById.entries()) {
    const depth = hopDepthById.get(id)
    if (depth === undefined || depth < 1) continue
    const anchors = parentAnchorsById.get(id) || []
    const anchorIds = anchorIdsById.get(id) || []
    const anchorX =
      anchors.length > 0
        ? anchors.reduce((sum, pos) => sum + pos[0], 0) / anchors.length
        : 0
    const anchorY =
      anchors.length > 0
        ? anchors.reduce((sum, pos) => sum + pos[1], 0) / anchors.length
        : 0
    reachableExternal.push({
      extNode,
      id,
      depth,
      anchorX,
      anchorY,
      anchorId: anchorIds[0] || null,
      parentId: firstParentById.get(id) || null,
      isBridge: bridgeParentIds.has(id),
    })
  }

  const mode = options.mode || "cartesian"
  const zoomTier = options.zoomTier || (mode === "world" ? "local" : "local")
  const expandedSet = toExpandedClusterSet(options.expandedClusters)
  const bounds = options.bounds || nodeBounds(sceneNodes)
  const tierOffsetY = Number(options.tierOffsetY ?? 110)
  const tierStepY = Number(options.tierStepY ?? 95)
  const stepX = Number(options.stepX ?? 175)
  const maxNodesPerTier = Number.isFinite(Number(options.maxNodesPerTier))
    ? Math.max(1, Number(options.maxNodesPerTier))
    : 6

  const positionedExternalById = new Map()
  const renderedNodes = []
  const syntheticEdges = []
  const hiddenClusterMembersByKey = new Map()

  const consolidateAnchors = zoomTier === "global" || zoomTier === "regional"
  const itemsToRender = []
  const groupedByAnchor = new Map()

  for (const item of reachableExternal) {
    const clusterKey = item.anchorId ? horizonDeviceClusterKey(item.anchorId) : null
    if (consolidateAnchors && clusterKey && !expandedSet.has(clusterKey)) {
      if (!groupedByAnchor.has(item.anchorId)) groupedByAnchor.set(item.anchorId, [])
      groupedByAnchor.get(item.anchorId).push(item)
    } else {
      itemsToRender.push(item)
    }
  }

  for (const [devId, groupItems] of groupedByAnchor.entries()) {
    const anchor = matchedAnchors.get(devId)
    if (!anchor || groupItems.length === 0) continue
    const clusterKey = horizonDeviceClusterKey(devId)
    const sortedGroup = [...groupItems].sort((a, b) => {
      if (a.depth !== b.depth) return a.depth - b.depth
      const pa = KIND_PRIORITY[a.extNode.kind] ?? 99
      const pb = KIND_PRIORITY[b.extNode.kind] ?? 99
      if (pa !== pb) return pa - pb
      return a.id.localeCompare(b.id)
    })
    const primary = sortedGroup[0].extNode
    const primaryShort = shortClusterPrimaryLabel(primary)
    const extraCount = sortedGroup.length - 1
    const label =
      extraCount > 0 ? `Internet (${primaryShort} · +${extraCount})` : `Internet (${primaryShort})`
    const worstSev = pickWorstSeverity(...sortedGroup.map((entry) => horizonSeverity(entry.extNode)))
    const clusterExtNode = {
      id: clusterKey,
      kind: "EgressCluster",
      label,
      asn: primary.asn ?? null,
      outage_state: worstSev === "neutral" ? null : worstSev,
      port_speed_mbps: anchor.device?.port_speed_mbps ?? primary.port_speed_mbps ?? null,
      isCluster: true,
      clusterKey,
      clusterCount: sortedGroup.length,
      clusterExpanded: false,
      anchorId: devId,
    }
    const members = sortedGroup.map((entry) => entry.extNode)
    hiddenClusterMembersByKey.set(clusterKey, members)

    const baseOffset = Number(options.worldOffset ?? 18) * 1.15
    const pos =
      mode === "world"
        ? [anchor.position[0], anchor.position[1] - baseOffset, 0]
        : [anchor.position[0], bounds.minY - tierOffsetY, 0]
    const clusterRecord = buildExternalNodeRenderRecord(clusterExtNode, 1, pos)
    clusterRecord.connectedNodes = members
    positionedExternalById.set(clusterKey, clusterRecord)
    renderedNodes.push(clusterRecord)

    const primaryEdge = data.edges.find(
      (edge) =>
        String(edge?.src_id || "").trim() === devId &&
        String(edge?.dst_id || "").trim() === primary.id,
    )
    syntheticEdges.push({
      src_id: devId,
      dst_id: clusterKey,
      kind: primaryEdge?.kind || "EGRESSES_TO",
      egress_source: anchor.device?.egress_source || primaryEdge?.egress_source || "manual",
      port_speed_mbps: anchor.device?.port_speed_mbps ?? primaryEdge?.port_speed_mbps ?? null,
      avg_rtt_us: primaryEdge?.avg_rtt_us ?? null,
      loss_pct: primaryEdge?.loss_pct ?? null,
      severity: worstSev,
    })
  }

  const tiers = new Map()
  for (const item of itemsToRender) {
    const tier = Math.min(item.depth, 4)
    if (!tiers.has(tier)) tiers.set(tier, [])
    tiers.get(tier).push(item)
  }

  const sortedTierKeys = [...tiers.keys()].sort((a, b) => a - b)
  for (const tier of sortedTierKeys) {
    const rawItems = tiers.get(tier)
    const prioritized = [...rawItems].sort((a, b) => {
      const sa = horizonSeverityRank(horizonSeverity(a.extNode))
      const sb = horizonSeverityRank(horizonSeverity(b.extNode))
      if (sa !== sb) return sb - sa
      if (a.isBridge !== b.isBridge) return a.isBridge ? -1 : 1
      const pa = KIND_PRIORITY[a.extNode.kind] ?? 99
      const pb = KIND_PRIORITY[b.extNode.kind] ?? 99
      if (pa !== pb) return pa - pb
      const spdA = Number(a.extNode.port_speed_mbps || 0)
      const spdB = Number(b.extNode.port_speed_mbps || 0)
      if (spdA !== spdB) return spdB - spdA
      return a.id.localeCompare(b.id)
    })

    const tierClusterKey = horizonTierClusterKey(tier)
    const tierExpanded = expandedSet.has(tierClusterKey)
    const visibleItems = tierExpanded ? prioritized : prioritized.slice(0, maxNodesPerTier)
    const hiddenItems = tierExpanded ? [] : prioritized.slice(maxNodesPerTier)
    const items = [...visibleItems]
    items.sort((a, b) => {
      if (a.anchorX !== b.anchorX) return a.anchorX - b.anchorX
      const pa = KIND_PRIORITY[a.extNode.kind] ?? 99
      const pb = KIND_PRIORITY[b.extNode.kind] ?? 99
      if (pa !== pb) return pa - pb
      return a.id.localeCompare(b.id)
    })

    if (hiddenItems.length > 0) {
      const worstHiddenSeverity = pickWorstSeverity(
        ...hiddenItems.map((h) => horizonSeverity(h.extNode)),
      )
      const summaryParent =
        hiddenItems
          .map((h) => h.parentId)
          .find((pid) => pid && (matchedAnchors.has(pid) || positionedExternalById.has(pid))) ||
        matchedAnchors.keys().next().value ||
        null
      const avgAnchorX =
        hiddenItems.reduce((sum, h) => sum + h.anchorX, 0) / hiddenItems.length
      const avgAnchorY =
        hiddenItems.reduce((sum, h) => sum + h.anchorY, 0) / hiddenItems.length
      const summaryExtNode = {
        id: tierClusterKey,
        kind: "EgressCluster",
        label: `+${hiddenItems.length} more`,
        outage_state: worstHiddenSeverity === "neutral" ? null : worstHiddenSeverity,
        isCluster: true,
        isSummary: true,
        clusterKey: tierClusterKey,
        clusterCount: hiddenItems.length,
        clusterExpanded: false,
      }
      const members = hiddenItems.map((h) => h.extNode)
      hiddenClusterMembersByKey.set(tierClusterKey, members)
      items.push({
        extNode: summaryExtNode,
        id: tierClusterKey,
        depth: tier,
        anchorX: avgAnchorX,
        anchorY: avgAnchorY,
        parentId: summaryParent,
        isCluster: true,
      })
      if (summaryParent) {
        syntheticEdges.push({
          src_id: summaryParent,
          dst_id: tierClusterKey,
          kind: "CLUSTER_SUMMARY",
          egress_source: "summary",
          severity: worstHiddenSeverity,
        })
      }
    }

    if (mode === "world") {
      const count = items.length
      const crowdScale = 1 + Math.max(0, count - 2) * 0.18
      const worldOffset = Number(options.worldOffset ?? 18) * (1 + (tier - 1) * 1.15) * crowdScale
      const angleSpread = Math.min(Math.PI * 1.15, Math.max(0.45, (count - 1) * 0.45))
      items.forEach((item, idx) => {
        const t = count === 1 ? 0 : idx / (count - 1) - 0.5
        const angle = -Math.PI / 2 + t * angleSpread
        const position = [
          item.anchorX + Math.cos(angle) * worldOffset,
          item.anchorY + Math.sin(angle) * worldOffset,
          0,
        ]
        const nodeObj = buildExternalNodeRenderRecord(item.extNode, item.depth, position)
        positionedExternalById.set(item.id, nodeObj)
        renderedNodes.push(nodeObj)
      })
    } else {
      const y = bounds.minY - tierOffsetY - (tier - 1) * tierStepY
      const spacing = Math.max(stepX, bounds.spanX / Math.max(1, items.length))
      const totalWidth = (items.length - 1) * spacing
      const startX = bounds.cx - totalWidth / 2
      items.forEach((item, idx) => {
        const x = startX + idx * spacing
        const position = [x, y, 0]
        const nodeObj = buildExternalNodeRenderRecord(item.extNode, item.depth, position)
        positionedExternalById.set(item.id, nodeObj)
        renderedNodes.push(nodeObj)
      })
    }
  }

  // Link connectedNodes on each external node and build edge list
  const renderedEdges = []
  const seenEdgeKeys = new Set()
  const connectedByExtId = new Map()
  const addConnected = (extId, otherNode) => {
    if (!extId || !otherNode) return
    if (!connectedByExtId.has(extId)) connectedByExtId.set(extId, [])
    const list = connectedByExtId.get(extId)
    if (!list.includes(otherNode)) list.push(otherNode)
  }

  for (const [devId, anchor] of matchedAnchors.entries()) {
    const info = {
      device: anchor.device,
      connectedNodes: [],
      edges: [],
    }
    deviceLookup.set(devId, info)
    const sceneId = anchor.sceneNode?.id
    if (typeof sceneId === "string" && sceneId.trim() !== "") {
      deviceLookup.set(sceneId.trim(), info)
    }
    const uid = anchor.sceneNode?.details?.device_uid
    if (typeof uid === "string" && uid.trim() !== "") {
      deviceLookup.set(uid.trim(), info)
    }
  }

  for (const edge of [...data.edges, ...syntheticEdges]) {
    const srcId = typeof edge?.src_id === "string" ? edge.src_id.trim() : ""
    const dstId = typeof edge?.dst_id === "string" ? edge.dst_id.trim() : ""
    if (!srcId || !dstId) continue

    const srcAnchor = matchedAnchors.get(srcId)
    const dstAnchor = matchedAnchors.get(dstId)
    const srcExt = positionedExternalById.get(srcId)
    const dstExt = positionedExternalById.get(dstId)

    const srcPos = srcAnchor?.position || srcExt?.position
    const dstPos = dstAnchor?.position || dstExt?.position
    if (!srcPos || !dstPos) continue

    const kind = String(edge.kind || "EGRESSES_TO").toUpperCase()
    const interactionKey = [
      "horizon-edge",
      encodeURIComponent(srcId),
      encodeURIComponent(dstId),
      encodeURIComponent(kind),
    ].join(":")
    if (seenEdgeKeys.has(interactionKey)) continue
    seenEdgeKeys.add(interactionKey)

    const edgeSeverity = pickWorstSeverity(
      horizonSeverity(edge),
      srcExt?.severity || "neutral",
      dstExt?.severity || "neutral",
    )

    const edgeRecord = {
      ...edge,
      src_id: srcId,
      dst_id: dstId,
      kind,
      sourcePosition: srcPos,
      targetPosition: dstPos,
      severity: edgeSeverity,
      badges: horizonEntityBadges(edge),
      srcNode: srcExt || srcAnchor?.device || null,
      dstNode: dstExt || dstAnchor?.device || null,
      horizonEntityType: "edge",
      interactionKey,
    }
    renderedEdges.push(edgeRecord)

    if (srcExt && dstExt) {
      addConnected(srcId, dstExt)
      addConnected(dstId, srcExt)
    }
    if (srcAnchor && dstExt) {
      const info = deviceLookup.get(srcId)
      if (info) {
        info.edges.push(edgeRecord)
        info.connectedNodes.push(dstExt)
      }
      addConnected(dstId, srcAnchor.device)
    }
    if (dstAnchor && srcExt) {
      const info = deviceLookup.get(dstId)
      if (info) {
        info.edges.push(edgeRecord)
        info.connectedNodes.push(srcExt)
      }
      addConnected(srcId, dstAnchor.device)
    }
  }

  for (const node of renderedNodes) {
    const clusterMembers = hiddenClusterMembersByKey.get(node.id)
    const linked = connectedByExtId.get(node.id) || []
    if (clusterMembers && clusterMembers.length > 0) {
      const merged = [...clusterMembers]
      for (const item of linked) {
        if (!merged.includes(item)) merged.push(item)
      }
      node.connectedNodes = merged
    } else {
      node.connectedNodes = linked
    }
  }

  const pulseNodes = renderedNodes.filter(
    (node) => node.severity === "outage" || node.rtbh_active === true,
  )

  return {
    nodes: renderedNodes,
    edges: renderedEdges,
    pulseNodes,
    deviceLookup,
  }
}

export function horizonDeviceClusterKey(deviceId) {
  return `horizon-cluster:${String(deviceId || "").trim()}`
}

export function horizonTierClusterKey(tier) {
  return `horizon-tier-cluster:tier-${Number(tier)}`
}

function toExpandedClusterSet(expandedClusters) {
  if (expandedClusters instanceof Set) return expandedClusters
  if (Array.isArray(expandedClusters)) {
    return new Set(expandedClusters.map((v) => String(v || "").trim()).filter(Boolean))
  }
  return new Set()
}

function shortClusterPrimaryLabel(node) {
  if (!node || typeof node !== "object") return "Egress"
  const kind = String(node.kind || "").trim()
  const asn = Number(node.asn)
  if (kind === "ASN" && Number.isFinite(asn) && asn > 0) return `AS${asn}`
  return horizonNodeDisplayLabel(node)
}

export function selectVisibleHorizonLabels(nodes, options = {}) {
  if (!Array.isArray(nodes) || nodes.length === 0) return []
  const mode = options.mode || "cartesian"
  const zoomTier = options.zoomTier || "local"
  const zoom = Number(options.zoom ?? 0)
  const clampedZoom = Math.max(-6, Math.min(8, Number.isFinite(zoom) ? zoom : 0))
  const worldPerPx = 2 ** -clampedZoom
  const selectedKey = options.selectedKey || null
  const hoveredKey = options.hoveredKey || null
  const maxLabels = Number.isFinite(Number(options.maxLabels)) ? Number(options.maxLabels) : 16

  const priorityFor = (node) => {
    const key = node?.interactionKey
    if (key && (key === selectedKey || key === hoveredKey)) return 1000
    if (node?.isCluster) return 500
    if (node?.severity === "outage") return 400
    if (node?.severity === "degraded") return 350
    const depth = Number(node?.hopDepth ?? 99)
    if (depth <= 1) return 200
    if (depth === 2) return 100
    return 10
  }

  const eligible = nodes.filter((node) => {
    const key = node?.interactionKey
    if (key && (key === selectedKey || key === hoveredKey)) return true
    if (node?.isCluster || node?.severity === "outage" || node?.severity === "degraded") return true
    if (mode === "world" && zoomTier === "global") {
      return Number(node?.hopDepth ?? 99) <= 1
    }
    if (mode === "world" && zoomTier === "regional") {
      return Number(node?.hopDepth ?? 99) <= 2
    }
    return true
  })

  const sorted = [...eligible].sort((a, b) => {
    const pa = priorityFor(a)
    const pb = priorityFor(b)
    if (pa !== pb) return pb - pa
    return String(a?.id || "").localeCompare(String(b?.id || ""))
  })

  const placedBoxes = []
  const visible = []
  const boxHeight = 20 * worldPerPx

  for (const node of sorted) {
    const pos = node?.position
    if (!Array.isArray(pos) || pos.length < 2) continue
    const x = Number(pos[0])
    const y = Number(pos[1])
    if (!Number.isFinite(x) || !Number.isFinite(y)) continue

    const isFocused =
      Boolean(node.interactionKey) &&
      (node.interactionKey === selectedKey || node.interactionKey === hoveredKey)
    if (!isFocused && visible.length >= maxLabels) continue

    const text = String(node.labelText || node.label || node.id || "")
    const boxWidth = Math.max(56, Math.min(220, text.length * 6.5 + 16)) * worldPerPx

    if (!isFocused) {
      const collides = placedBoxes.some(
        (box) =>
          Math.abs(x - box.x) < (boxWidth + box.w) * 0.5 &&
          Math.abs(y - box.y) < (boxHeight + box.h) * 0.5,
      )
      if (collides) continue
    }

    placedBoxes.push({x, y, w: boxWidth, h: boxHeight})
    visible.push(node)
  }

  return visible
}

export function horizonDeviceChains(rawData, maxItemsPerDevice = 6) {
  const data = normalizeHorizonEgressData(rawData)
  const nodesById = new Map(data.external_nodes.map((node) => [node.id, node]))
  const anchorIds = new Set(
    data.egress_devices.map((d) => String(d?.id || "").trim()).filter(Boolean),
  )

  const neighborsById = new Map()
  const addNeighbor = (fromId, toId, kind, edge) => {
    if (!neighborsById.has(fromId)) neighborsById.set(fromId, [])
    const list = neighborsById.get(fromId)
    if (!list.some((entry) => entry.toId === toId && entry.kind === kind)) {
      list.push({toId, kind, edge})
    }
  }

  for (const edge of data.edges) {
    const src = typeof edge?.src_id === "string" ? edge.src_id.trim() : ""
    const dst = typeof edge?.dst_id === "string" ? edge.dst_id.trim() : ""
    if (!src || !dst) continue
    const kind = String(edge?.kind || "").trim().toUpperCase()
    if (kind === "AS_REL_PROVIDER") {
      addNeighbor(dst, src, kind, edge)
    } else if (kind === "AS_REL_PEER") {
      addNeighbor(src, dst, kind, edge)
      addNeighbor(dst, src, kind, edge)
    } else {
      addNeighbor(src, dst, kind, edge)
      if (kind === "ORIGIN_PREFIX" || !anchorIds.has(src)) {
        addNeighbor(dst, src, kind, edge)
      }
    }
  }

  const chains = new Map()
  for (const device of data.egress_devices) {
    const devId = String(device?.id || "").trim()
    if (!devId) continue
    const visited = new Set([devId])
    const queue = [{id: devId, depth: 0}]
    const chain = []
    let head = 0
    while (head < queue.length && chain.length < maxItemsPerDevice) {
      const current = queue[head++]
      const neighbors = neighborsById.get(current.id) || []
      for (const {toId, kind, edge} of neighbors) {
        if (visited.has(toId) || anchorIds.has(toId)) continue
        if (kind === "AS_REL_PEER" && current.depth >= 2) continue
        const ext = nodesById.get(toId)
        if (!ext) continue
        visited.add(toId)
        chain.push({ext, edge, depth: current.depth + 1})
        queue.push({id: toId, depth: current.depth + 1})
        if (chain.length >= maxItemsPerDevice) break
      }
    }
    chains.set(devId, chain)
  }
  return chains
}

function buildExternalNodeRenderRecord(extNode, hopDepth, position) {
  const severity = horizonSeverity(extNode)
  const displayLabel = horizonNodeDisplayLabel(extNode)
  const badges = horizonEntityBadges(extNode)
  return {
    ...extNode,
    hopDepth,
    position,
    severity,
    displayLabel,
    badges,
    labelText: badges.length > 0 ? `${displayLabel} ${badges.join(" ")}` : displayLabel,
    horizonEntityType: "node",
    connectedNodes: [],
    interactionKey: `horizon-node:${encodeURIComponent(String(extNode.id || ""))}`,
  }
}

function pickWorstSeverity(...severities) {
  let worst = "neutral"
  let worstRank = 0
  for (const s of severities) {
    const rank = horizonSeverityRank(s)
    if (rank > worstRank) {
      worst = s
      worstRank = rank
    }
  }
  return worst
}

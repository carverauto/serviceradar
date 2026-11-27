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

export function formatRttUs(rawUs) {
  const us = Number(rawUs)
  if (!Number.isFinite(us) || us < 0) return ""
  const ms = us / 1000
  if (ms < 1) return `${Math.round(us)}us`
  if (ms < 100) return `${ms.toFixed(1)}ms`
  return `${Math.round(ms)}ms`
}

export function horizonSeverity(entity) {
  if (!entity || typeof entity !== "object") return "neutral"
  const outage = String(entity.outage_state || "").trim().toLowerCase()
  const rpki = String(entity.rpki_state || "").trim().toLowerCase()
  const rtbh = entity.rtbh_active === true
  const loss = Number(entity.loss_pct)

  if (OUTAGE_STATES.has(outage) || rtbh) return "outage"
  if (DEGRADED_STATES.has(outage) || rpki === "invalid" || (Number.isFinite(loss) && loss > 2)) {
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
    const connectedAsnNode = (connectedNodes || []).find((node) => Number.isFinite(Number(node?.asn)))
    const asn = entity.asn ?? entity.border_asn ?? connectedAsnNode?.asn
    const prefix = entity.prefix || (kind === "prefix" ? entity.id : "")
    const params = ["tab=bgp_sankey"]
    if (asn !== null && asn !== undefined && String(asn).trim() !== "") {
      params.push(`origin_asn=${encodeURIComponent(String(asn).trim())}`)
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
    const asnNode = endpoints.find((node) => Number.isFinite(Number(node.asn)) && Number(node.asn) > 0)
    const prefixNode = endpoints.find((node) => String(node.kind || "").trim().toLowerCase() === "prefix")
    const asn = entity.border_asn ?? asnNode?.asn
    const prefix = prefixNode?.id || ""
    const params = ["tab=bgp_sankey"]
    if (asn !== null && asn !== undefined && String(asn).trim() !== "") {
      params.push(`origin_asn=${encodeURIComponent(String(asn).trim())}`)
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

  const outgoingById = new Map()
  for (const edge of data.edges) {
    const src = typeof edge?.src_id === "string" ? edge.src_id.trim() : ""
    const dst = typeof edge?.dst_id === "string" ? edge.dst_id.trim() : ""
    if (!src || !dst) continue
    if (!outgoingById.has(src)) outgoingById.set(src, [])
    outgoingById.get(src).push(edge)
  }

  // BFS from matched egress devices to find reachable external nodes and hop depth.
  const hopDepthById = new Map()
  const parentAnchorsById = new Map()
  const queue = []

  for (const [devId, anchor] of matchedAnchors.entries()) {
    hopDepthById.set(devId, 0)
    parentAnchorsById.set(devId, [anchor.position])
    queue.push(devId)
  }

  let head = 0
  while (head < queue.length) {
    const currentId = queue[head++]
    const currentDepth = hopDepthById.get(currentId) ?? 0
    const edges = outgoingById.get(currentId) || []

    for (const edge of edges) {
      const nextId = typeof edge?.dst_id === "string" ? edge.dst_id.trim() : ""
      if (!nextId || matchedAnchors.has(nextId)) continue

      const nextDepth = currentDepth + 1
      if (!parentAnchorsById.has(nextId)) parentAnchorsById.set(nextId, [])
      const anchors = parentAnchorsById.get(currentId) || []
      for (const anchorPos of anchors) {
        parentAnchorsById.get(nextId).push(anchorPos)
      }

      if (!hopDepthById.has(nextId) || nextDepth < hopDepthById.get(nextId)) {
        hopDepthById.set(nextId, nextDepth)
        queue.push(nextId)
      }
    }
  }

  const reachableExternal = []
  for (const [id, extNode] of externalNodeById.entries()) {
    const depth = hopDepthById.get(id)
    if (depth === undefined || depth < 1) continue
    const anchors = parentAnchorsById.get(id) || []
    const anchorX =
      anchors.length > 0
        ? anchors.reduce((sum, pos) => sum + pos[0], 0) / anchors.length
        : 0
    const anchorY =
      anchors.length > 0
        ? anchors.reduce((sum, pos) => sum + pos[1], 0) / anchors.length
        : 0
    reachableExternal.push({extNode, id, depth, anchorX, anchorY})
  }

  const mode = options.mode || "cartesian"
  const bounds = options.bounds || nodeBounds(sceneNodes)
  const tierOffsetY = Number(options.tierOffsetY ?? 90)
  const tierStepY = Number(options.tierStepY ?? 75)
  const stepX = Number(options.stepX ?? 150)

  const tiers = new Map()
  for (const item of reachableExternal) {
    const tier = Math.min(item.depth, 4)
    if (!tiers.has(tier)) tiers.set(tier, [])
    tiers.get(tier).push(item)
  }

  const positionedExternalById = new Map()
  const renderedNodes = []

  const sortedTierKeys = [...tiers.keys()].sort((a, b) => a - b)
  for (const tier of sortedTierKeys) {
    const items = tiers.get(tier)
    items.sort((a, b) => {
      if (a.anchorX !== b.anchorX) return a.anchorX - b.anchorX
      const pa = KIND_PRIORITY[a.extNode.kind] ?? 99
      const pb = KIND_PRIORITY[b.extNode.kind] ?? 99
      if (pa !== pb) return pa - pb
      return a.id.localeCompare(b.id)
    })

    if (mode === "world") {
      const worldOffset = Number(options.worldOffset ?? 18) * (1 + (tier - 1) * 0.75)
      const count = items.length
      items.forEach((item, idx) => {
        const angleSpread = Math.min(Math.PI * 0.85, Math.max(0.35, (count - 1) * 0.35))
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
  const connectedByExtId = new Map()
  const addConnected = (extId, otherNode) => {
    if (!extId || !otherNode) return
    if (!connectedByExtId.has(extId)) connectedByExtId.set(extId, [])
    connectedByExtId.get(extId).push(otherNode)
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

  for (const edge of data.edges) {
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
      interactionKey: [
        "horizon-edge",
        encodeURIComponent(srcId),
        encodeURIComponent(dstId),
        encodeURIComponent(kind),
      ].join(":"),
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
    node.connectedNodes = connectedByExtId.get(node.id) || []
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

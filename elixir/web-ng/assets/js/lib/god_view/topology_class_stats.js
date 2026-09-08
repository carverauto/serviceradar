// Pure helpers for the per-edge-class snapshot meta (backbone-empty signal).
//
// The god-view snapshot meta carries per-topology-class edge counts
// (`edge_class_*`) plus an explicit `backbone_edge_count`. These helpers
// normalize those counts, decide whether the snapshot is in the degraded
// "backbone empty" state (zero backbone-class edges while other-class edges
// exist), and format the compact debug status-line fragment.

const CLASS_KEYS = [
  ["backbone", "edge_class_backbone"],
  ["attachment", "edge_class_attachment"],
  ["inferred", "edge_class_inferred"],
  ["hosted", "edge_class_hosted"],
  ["observed", "edge_class_observed"],
]

function toCount(value) {
  const parsed =
    typeof value === "number" ? value :
    (typeof value === "string" && value.trim() !== "" ? Number(value) : NaN)
  return Number.isFinite(parsed) && parsed >= 0 ? Math.floor(parsed) : null
}

export function edgeClassCounts(stats) {
  if (!stats || typeof stats !== "object") return null

  const out = {}
  let present = false
  for (const [name, key] of CLASS_KEYS) {
    const parsed = toCount(stats[key])
    if (parsed !== null) present = true
    out[name] = parsed === null ? 0 : parsed
  }

  const backboneCount = toCount(stats.backbone_edge_count)
  if (backboneCount !== null) {
    present = true
    out.backbone = backboneCount
  }

  return present ? out : null
}

export function backboneEmptyState(stats) {
  const counts = edgeClassCounts(stats)
  if (!counts) return false
  const otherEdges = counts.attachment + counts.inferred + counts.hosted + counts.observed
  return counts.backbone === 0 && otherEdges > 0
}

export function formatEdgeClassStatus(stats) {
  const counts = edgeClassCounts(stats)
  if (!counts) return ""
  const base =
    `classes=bb:${counts.backbone}/att:${counts.attachment}/inf:${counts.inferred}` +
    `/host:${counts.hosted}/obs:${counts.observed}`
  return backboneEmptyState(stats) ? `${base} backbone=EMPTY` : base
}

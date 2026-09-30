// Pure helpers for the per-edge-class snapshot meta (backbone-empty signal).
//
// The god-view snapshot meta carries per-topology-class edge counts
// (`edge_class_*`) plus an explicit `backbone_edge_count`. These helpers
// normalize those counts, decide whether the snapshot is in the degraded
// "backbone empty" state (zero backbone-class edges while other-class edges
// exist), and format the compact debug status-line fragment.

const CLASS_KEYS = [
  ["backbone", "edge_class_backbone"],
  ["logical", "edge_class_logical"],
  ["attachment", "edge_class_attachment"],
  ["inferred", "edge_class_inferred"],
  ["hosted", "edge_class_hosted"],
  ["observed", "edge_class_observed"],
  ["unknown", "edge_class_unknown"],
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
    out[name] = parsed
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
  const hasOtherEdges = [counts.logical, counts.attachment, counts.inferred, counts.hosted, counts.observed, counts.unknown]
    .some(count => count !== null && count > 0)
  return counts.backbone === 0 && hasOtherEdges
}

export function formatEdgeClassStatus(stats) {
  const counts = edgeClassCounts(stats)
  if (!counts) return ""
  const base =
    `classes=bb:${counts.backbone ?? "—"}/att:${counts.attachment ?? "—"}/inf:${counts.inferred ?? "—"}` +
    `/log:${counts.logical ?? "—"}/host:${counts.hosted ?? "—"}/obs:${counts.observed ?? "—"}/unk:${counts.unknown ?? "—"}`
  return backboneEmptyState(stats) ? `${base} backbone=EMPTY` : base
}

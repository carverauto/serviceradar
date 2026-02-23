export const godViewRenderingStylePipelineMethods = {
  pipelineStatsFromHeaders(headers) {
    if (!headers || typeof headers.get !== "function") return null
    const readInt = (name) => {
      const raw = headers.get(name)
      if (raw == null || raw === "") return null
      const parsed = Number.parseInt(raw, 10)
      return Number.isFinite(parsed) ? parsed : null
    }

    const stats = {
      raw_links: readInt("x-sr-god-view-pipeline-raw-links"),
      unique_pairs: readInt("x-sr-god-view-pipeline-unique-pairs"),
      final_edges: readInt("x-sr-god-view-pipeline-final-edges"),
      final_direct: readInt("x-sr-god-view-pipeline-final-direct"),
      final_inferred: readInt("x-sr-god-view-pipeline-final-inferred"),
      final_attachment: readInt("x-sr-god-view-pipeline-final-attachment"),
      unresolved_endpoints: readInt("x-sr-god-view-pipeline-unresolved-endpoints"),
    }

    const hasAny = Object.values(stats).some((value) => Number.isFinite(value))
    return hasAny ? stats : null
  },
  normalizePipelineStats(raw) {
    if (!raw || typeof raw !== "object") return null
    const keys = [
      "raw_links",
      "unique_pairs",
      "final_edges",
      "final_direct",
      "final_inferred",
      "final_attachment",
      "unresolved_endpoints",
    ]
    const out = {}
    for (let i = 0; i < keys.length; i += 1) {
      const key = keys[i]
      const value = raw[key]
      const parsed =
        Number.isFinite(value) ? Number(value) :
        (typeof value === "string" ? Number.parseInt(value, 10) : NaN)
      if (Number.isFinite(parsed)) out[key] = parsed
    }
    return Object.keys(out).length > 0 ? out : null
  },
}

export const godViewRenderingStylePipelineMethods = {
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

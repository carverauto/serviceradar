export const MANAGED_VISUAL_DENSITY_DETAIL = "detail"
export const MANAGED_VISUAL_DENSITY_OVERVIEW = "overview"
export const MANAGED_VISUAL_DENSITY_COMPACT = "compact"

const CONTRACTS = Object.freeze({
  [MANAGED_VISUAL_DENSITY_DETAIL]: Object.freeze({
    key: MANAGED_VISUAL_DENSITY_DETAIL,
    ordinaryOuterRadius: 20,
    memberOuterRadius: 20,
    summaryOuterRadius: Number.POSITIVE_INFINITY,
    anchorOuterRadius: Number.POSITIVE_INFINITY,
    routeMaxWidth: 12,
    labelShape: "local",
  }),
  [MANAGED_VISUAL_DENSITY_OVERVIEW]: Object.freeze({
    key: MANAGED_VISUAL_DENSITY_OVERVIEW,
    ordinaryOuterRadius: 10,
    memberOuterRadius: 10,
    summaryOuterRadius: 20,
    anchorOuterRadius: 12,
    routeMaxWidth: 10,
    labelShape: "global",
  }),
  // The ladder used to bottom out at overview, so a scene too dense for it had nowhere to go:
  // Fit kept zooming out while the glyphs stayed 10-12px, until they overlapped. Two clusters
  // expanded in an 800x1000 viewport put an anchor and a member 278 world units apart, which
  // projects to 18px at the fitted scale while overview needs 22px. Anchor + member here is
  // 14px, which clears it -- and the tightest pair in that scene (two adjacent members, 208
  // units apart) needs 12px and gets 13.8px.
  [MANAGED_VISUAL_DENSITY_COMPACT]: Object.freeze({
    key: MANAGED_VISUAL_DENSITY_COMPACT,
    ordinaryOuterRadius: 6,
    memberOuterRadius: 6,
    summaryOuterRadius: 12,
    anchorOuterRadius: 8,
    routeMaxWidth: 6,
    labelShape: "global",
  }),
})

export const MANAGED_VISUAL_DENSITY_PREFERENCE = Object.freeze([
  MANAGED_VISUAL_DENSITY_DETAIL,
  MANAGED_VISUAL_DENSITY_OVERVIEW,
  MANAGED_VISUAL_DENSITY_COMPACT,
])

// Membership test, not an equality chain. Mapping every unrecognised value to "detail" meant a
// newly added tier would be selected by the fit and then drawn at the WIDEST extents -- 20px
// glyphs with uncapped summary/anchor radii -- which is strictly worse than not having it.
export function normalizeManagedVisualDensity(value) {
  return Object.hasOwn(CONTRACTS, value) ? value : MANAGED_VISUAL_DENSITY_DETAIL
}

export function managedVisualDensityContract(value) {
  return CONTRACTS[normalizeManagedVisualDensity(value)]
}

export function managedNodeVisualRole(node) {
  const kind = String(node?.details?.cluster_kind || "")
  if (kind === "endpoint-summary") return "summary"
  if (kind === "endpoint-anchor") return "anchor"
  if (kind === "endpoint-member") return "member"
  return "ordinary"
}

export function managedNodeOuterRadiusCap(node, density) {
  const contract = managedVisualDensityContract(density)
  switch (managedNodeVisualRole(node)) {
    case "summary":
      return contract.summaryOuterRadius
    case "anchor":
      return contract.anchorOuterRadius
    case "member":
      return contract.memberOuterRadius
    case "ordinary":
      return contract.ordinaryOuterRadius
    default:
      return contract.ordinaryOuterRadius
  }
}

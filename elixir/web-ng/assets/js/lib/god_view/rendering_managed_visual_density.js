export const MANAGED_VISUAL_DENSITY_DETAIL = "detail"
export const MANAGED_VISUAL_DENSITY_OVERVIEW = "overview"

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
})

export const MANAGED_VISUAL_DENSITY_PREFERENCE = Object.freeze([
  MANAGED_VISUAL_DENSITY_DETAIL,
  MANAGED_VISUAL_DENSITY_OVERVIEW,
])

export function normalizeManagedVisualDensity(value) {
  return value === MANAGED_VISUAL_DENSITY_OVERVIEW
    ? MANAGED_VISUAL_DENSITY_OVERVIEW
    : MANAGED_VISUAL_DENSITY_DETAIL
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

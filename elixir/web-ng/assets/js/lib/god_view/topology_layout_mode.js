export const TOPOLOGY_OVERVIEW_MODE = "elk-radial-overview"
export const TOPOLOGY_DETAIL_MODE = "elk-scene-detail"

export function topologySemanticLevel(graph) {
  return graph?._topologySemanticLevel === "detail" ? "detail" : "overview"
}

function hasTopologyScene(graph) {
  return Boolean(graph?._topologyScene) && typeof graph._topologyScene === "object"
}

export function isOverviewScene(graph) {
  return graph?._layoutMode === TOPOLOGY_OVERVIEW_MODE && hasTopologyScene(graph)
}

export function isDetailScene(graph) {
  return graph?._layoutMode === TOPOLOGY_DETAIL_MODE && hasTopologyScene(graph)
}

export function hasManagedTopologyScene(graph) {
  return isOverviewScene(graph) || isDetailScene(graph)
}

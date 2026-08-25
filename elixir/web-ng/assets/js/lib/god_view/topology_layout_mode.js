export const TOPOLOGY_OVERVIEW_MODE = "elk-radial-overview"
export const TOPOLOGY_DETAIL_MODE = "elk-scene-detail"

export function topologySemanticLevel(graph) {
  return graph?._topologySemanticLevel === "detail" ? "detail" : "overview"
}

function isPlainObject(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false
  const prototype = Object.getPrototypeOf(value)
  return prototype === Object.prototype || prototype === null
}

function hasFiniteBounds(bounds) {
  return (
    isPlainObject(bounds) &&
    Number.isFinite(bounds.minX) &&
    Number.isFinite(bounds.minY) &&
    Number.isFinite(bounds.maxX) &&
    Number.isFinite(bounds.maxY) &&
    bounds.minX <= bounds.maxX &&
    bounds.minY <= bounds.maxY
  )
}

function hasTopologyScene(graph) {
  const scene = graph?._topologyScene
  return (
    isPlainObject(scene) &&
    Array.isArray(scene.nodes) &&
    Array.isArray(scene.routes) &&
    hasFiniteBounds(scene.bounds)
  )
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

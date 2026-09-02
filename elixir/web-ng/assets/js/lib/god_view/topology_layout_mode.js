export const TOPOLOGY_OVERVIEW_MODE = "elk-radial-overview"
export const TOPOLOGY_DETAIL_MODE = "elk-scene-detail"

export function clusterExpandedFlag(value) {
  return value === true || value === "true" || value === 1
}

// Whether any cluster is expanded. This does NOT choose the layout: an expanded cluster
// elaborates the radial atlas in place -- the projection admits its members and parents them
// on their summary, so the backbone keeps its positions and only the opened cluster gains a
// ring. Promoting the whole graph to the bounded-detail scene instead re-laid every node with
// the layered algorithm, which is why expanding stopped looking like the same product.
//
// What this still answers is whether the scene is unbounded, which is what the label
// admission paths need: expansion can add arbitrarily many members to a scene sized for a
// handful, so those degrade rather than failing closed.
export function hasExpandedCluster(graph) {
  return (
    Array.isArray(graph?.nodes) &&
    graph.nodes.some((node) => clusterExpandedFlag(node?.details?.cluster_expanded))
  )
}

export function topologySemanticLevel(graph) {
  const declared = graph?._topologySemanticLevel
  if (declared === "detail" || declared === "overview") return declared
  return "overview"
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

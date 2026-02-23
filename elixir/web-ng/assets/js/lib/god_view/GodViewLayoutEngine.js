import {godViewLayoutAnimationMethods} from "./layout_animation_methods"
import {godViewLayoutClusterMethods} from "./layout_cluster_methods"
import {godViewLayoutTopologyMethods} from "./layout_topology_methods"

const LAYOUT_ENGINE_SHARED_METHODS = [
  "resolveZoomTier",
  "setZoomTier",
  "reshapeGraph",
  "geoGridData",
]

const LAYOUT_ENGINE_CONTEXT_METHODS = [
  "resolveZoomTier",
  "setZoomTier",
  "reshapeGraph",
  "reclusterByState",
  "reclusterByGrid",
  "clusterDetails",
  "clusterEdges",
  "animateTransition",
  "xyBuffer",
  "interpolateNodes",
  "prepareGraphLayout",
  "graphTopologyStamp",
  "sameTopology",
  "reusePreviousPositions",
  "shouldUseGeoLayout",
  "projectGeoLayout",
  "forceDirectedLayout",
  "geoGridData",
]

function bindApiMethods(instance, methods) {
  return Object.fromEntries(methods.map((method) => [method, instance[method].bind(instance)]))
}

export default class GodViewLayoutEngine {
  constructor(context) {
    this.context = context
  }

  getContextApi() {
    return bindApiMethods(this, LAYOUT_ENGINE_CONTEXT_METHODS)
  }

  getSharedApi() {
    return bindApiMethods(this, LAYOUT_ENGINE_SHARED_METHODS)
  }

  resolveZoomTier(...args) {
    return godViewLayoutClusterMethods.resolveZoomTier.call(this.context, ...args)
  }

  setZoomTier(...args) {
    return godViewLayoutClusterMethods.setZoomTier.call(this.context, ...args)
  }

  reshapeGraph(...args) {
    return godViewLayoutClusterMethods.reshapeGraph.call(this.context, ...args)
  }

  reclusterByState(...args) {
    return godViewLayoutClusterMethods.reclusterByState.call(this.context, ...args)
  }

  reclusterByGrid(...args) {
    return godViewLayoutClusterMethods.reclusterByGrid.call(this.context, ...args)
  }

  clusterDetails(...args) {
    return godViewLayoutClusterMethods.clusterDetails.call(this.context, ...args)
  }

  clusterEdges(...args) {
    return godViewLayoutClusterMethods.clusterEdges.call(this.context, ...args)
  }

  animateTransition(...args) {
    return godViewLayoutAnimationMethods.animateTransition.call(this.context, ...args)
  }

  xyBuffer(...args) {
    return godViewLayoutAnimationMethods.xyBuffer.call(this.context, ...args)
  }

  interpolateNodes(...args) {
    return godViewLayoutAnimationMethods.interpolateNodes.call(this.context, ...args)
  }

  prepareGraphLayout(...args) {
    return godViewLayoutTopologyMethods.prepareGraphLayout.call(this.context, ...args)
  }

  graphTopologyStamp(...args) {
    return godViewLayoutTopologyMethods.graphTopologyStamp.call(this.context, ...args)
  }

  sameTopology(...args) {
    return godViewLayoutTopologyMethods.sameTopology.call(this.context, ...args)
  }

  reusePreviousPositions(...args) {
    return godViewLayoutTopologyMethods.reusePreviousPositions.call(this.context, ...args)
  }

  shouldUseGeoLayout(...args) {
    return godViewLayoutTopologyMethods.shouldUseGeoLayout.call(this.context, ...args)
  }

  projectGeoLayout(...args) {
    return godViewLayoutTopologyMethods.projectGeoLayout.call(this.context, ...args)
  }

  forceDirectedLayout(...args) {
    return godViewLayoutTopologyMethods.forceDirectedLayout.call(this.context, ...args)
  }

  geoGridData(...args) {
    return godViewLayoutTopologyMethods.geoGridData.call(this.context, ...args)
  }
}

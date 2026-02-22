import {godViewLayoutAnimationMethods} from "./layout_animation_methods"
import {godViewLayoutClusterMethods} from "./layout_cluster_methods"
import {godViewLayoutTopologyMethods} from "./layout_topology_methods"

import SharedStateAdapter from "./SharedStateAdapter"

const LAYOUT_ENGINE_SHARED_METHODS = [
  "resolveZoomTier",
  "setZoomTier",
  "reshapeGraph",
  "geoGridData",
]

function bindApiMethods(instance, methods) {
  return Object.fromEntries(methods.map((method) => [method, instance[method].bind(instance)]))
}

export default class GodViewLayoutEngine extends SharedStateAdapter {
  constructor(state) {
    super(state)
  }

  getSharedApi() {
    return bindApiMethods(this, LAYOUT_ENGINE_SHARED_METHODS)
  }

  resolveZoomTier(...args) {
    return godViewLayoutClusterMethods.resolveZoomTier.call(this, ...args)
  }

  setZoomTier(...args) {
    return godViewLayoutClusterMethods.setZoomTier.call(this, ...args)
  }

  reshapeGraph(...args) {
    return godViewLayoutClusterMethods.reshapeGraph.call(this, ...args)
  }

  reclusterByState(...args) {
    return godViewLayoutClusterMethods.reclusterByState.call(this, ...args)
  }

  reclusterByGrid(...args) {
    return godViewLayoutClusterMethods.reclusterByGrid.call(this, ...args)
  }

  clusterDetails(...args) {
    return godViewLayoutClusterMethods.clusterDetails.call(this, ...args)
  }

  clusterEdges(...args) {
    return godViewLayoutClusterMethods.clusterEdges.call(this, ...args)
  }

  animateTransition(...args) {
    return godViewLayoutAnimationMethods.animateTransition.call(this, ...args)
  }

  xyBuffer(...args) {
    return godViewLayoutAnimationMethods.xyBuffer.call(this, ...args)
  }

  interpolateNodes(...args) {
    return godViewLayoutAnimationMethods.interpolateNodes.call(this, ...args)
  }

  prepareGraphLayout(...args) {
    return godViewLayoutTopologyMethods.prepareGraphLayout.call(this, ...args)
  }

  graphTopologyStamp(...args) {
    return godViewLayoutTopologyMethods.graphTopologyStamp.call(this, ...args)
  }

  sameTopology(...args) {
    return godViewLayoutTopologyMethods.sameTopology.call(this, ...args)
  }

  reusePreviousPositions(...args) {
    return godViewLayoutTopologyMethods.reusePreviousPositions.call(this, ...args)
  }

  shouldUseGeoLayout(...args) {
    return godViewLayoutTopologyMethods.shouldUseGeoLayout.call(this, ...args)
  }

  projectGeoLayout(...args) {
    return godViewLayoutTopologyMethods.projectGeoLayout.call(this, ...args)
  }

  forceDirectedLayout(...args) {
    return godViewLayoutTopologyMethods.forceDirectedLayout.call(this, ...args)
  }

  geoGridData(...args) {
    return godViewLayoutTopologyMethods.geoGridData.call(this, ...args)
  }
}

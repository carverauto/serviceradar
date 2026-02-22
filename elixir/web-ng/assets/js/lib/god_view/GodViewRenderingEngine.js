import {godViewRenderingMethods} from "./rendering_methods"

import SharedStateAdapter from "./SharedStateAdapter"

const RENDERING_ENGINE_SHARED_METHODS = [
  "renderGraph",
  "stateDisplayName",
  "edgeTopologyClass",
]

function bindApiMethods(instance, methods) {
  return Object.fromEntries(methods.map((method) => [method, instance[method].bind(instance)]))
}

export default class GodViewRenderingEngine extends SharedStateAdapter {
  constructor(state) {
    super(state)
  }

  getSharedApi() {
    return bindApiMethods(this, RENDERING_ENGINE_SHARED_METHODS)
  }

  autoFitViewState(...args) {
    return godViewRenderingMethods.autoFitViewState.call(this, ...args)
  }

  buildBitmapFallbackMetadata(...args) {
    return godViewRenderingMethods.buildBitmapFallbackMetadata.call(this, ...args)
  }

  buildGraphLayers(...args) {
    return godViewRenderingMethods.buildGraphLayers.call(this, ...args)
  }

  buildNodeAndLabelLayers(...args) {
    return godViewRenderingMethods.buildNodeAndLabelLayers.call(this, ...args)
  }

  buildPacketFlowInstances(...args) {
    return godViewRenderingMethods.buildPacketFlowInstances.call(this, ...args)
  }

  buildTransportAndEffectLayers(...args) {
    return godViewRenderingMethods.buildTransportAndEffectLayers.call(this, ...args)
  }

  buildVisibleGraphData(...args) {
    return godViewRenderingMethods.buildVisibleGraphData.call(this, ...args)
  }

  computeTraversalMask(...args) {
    return godViewRenderingMethods.computeTraversalMask.call(this, ...args)
  }

  connectionKindFromLabel(...args) {
    return godViewRenderingMethods.connectionKindFromLabel.call(this, ...args)
  }

  defaultStateReason(...args) {
    return godViewRenderingMethods.defaultStateReason.call(this, ...args)
  }

  edgeEnabledByTopologyLayer(...args) {
    return godViewRenderingMethods.edgeEnabledByTopologyLayer.call(this, ...args)
  }

  edgeIsFocused(...args) {
    return godViewRenderingMethods.edgeIsFocused.call(this, ...args)
  }

  edgeLayerId(...args) {
    return godViewRenderingMethods.edgeLayerId.call(this, ...args)
  }

  edgeTelemetryArcColors(...args) {
    return godViewRenderingMethods.edgeTelemetryArcColors.call(this, ...args)
  }

  edgeTelemetryColor(...args) {
    return godViewRenderingMethods.edgeTelemetryColor.call(this, ...args)
  }

  edgeTopologyClass(...args) {
    return godViewRenderingMethods.edgeTopologyClass.call(this, ...args)
  }

  edgeTopologyClassFromLabel(...args) {
    return godViewRenderingMethods.edgeTopologyClassFromLabel.call(this, ...args)
  }

  edgeWidthPixels(...args) {
    return godViewRenderingMethods.edgeWidthPixels.call(this, ...args)
  }

  ensureBitmapMetadata(...args) {
    return godViewRenderingMethods.ensureBitmapMetadata.call(this, ...args)
  }

  escapeHtml(...args) {
    return godViewRenderingMethods.escapeHtml.call(this, ...args)
  }

  focusNodeByIndex(...args) {
    return godViewRenderingMethods.focusNodeByIndex.call(this, ...args)
  }

  formatCapacity(...args) {
    return godViewRenderingMethods.formatCapacity.call(this, ...args)
  }

  formatPps(...args) {
    return godViewRenderingMethods.formatPps.call(this, ...args)
  }

  getNodeTooltip(...args) {
    return godViewRenderingMethods.getNodeTooltip.call(this, ...args)
  }

  handleHover(...args) {
    return godViewRenderingMethods.handleHover.call(this, ...args)
  }

  handlePick(...args) {
    return godViewRenderingMethods.handlePick.call(this, ...args)
  }

  humanizeCausalReason(...args) {
    return godViewRenderingMethods.humanizeCausalReason.call(this, ...args)
  }

  nodeColor(...args) {
    return godViewRenderingMethods.nodeColor.call(this, ...args)
  }

  nodeIndexLookup(...args) {
    return godViewRenderingMethods.nodeIndexLookup.call(this, ...args)
  }

  nodeMetricText(...args) {
    return godViewRenderingMethods.nodeMetricText.call(this, ...args)
  }

  nodeNeutralColor(...args) {
    return godViewRenderingMethods.nodeNeutralColor.call(this, ...args)
  }

  nodeRefByIndex(...args) {
    return godViewRenderingMethods.nodeRefByIndex.call(this, ...args)
  }

  nodeReferenceAction(...args) {
    return godViewRenderingMethods.nodeReferenceAction.call(this, ...args)
  }

  nodeStatusColor(...args) {
    return godViewRenderingMethods.nodeStatusColor.call(this, ...args)
  }

  nodeStatusIcon(...args) {
    return godViewRenderingMethods.nodeStatusIcon.call(this, ...args)
  }

  normalizeDisplayLabel(...args) {
    return godViewRenderingMethods.normalizeDisplayLabel.call(this, ...args)
  }

  normalizePipelineStats(...args) {
    return godViewRenderingMethods.normalizePipelineStats.call(this, ...args)
  }

  pipelineStatsFromHeaders(...args) {
    return godViewRenderingMethods.pipelineStatsFromHeaders.call(this, ...args)
  }

  renderGraph(...args) {
    return godViewRenderingMethods.renderGraph.call(this, ...args)
  }

  renderSelectionDetails(...args) {
    return godViewRenderingMethods.renderSelectionDetails.call(this, ...args)
  }

  selectEdgeLabels(...args) {
    return godViewRenderingMethods.selectEdgeLabels.call(this, ...args)
  }

  stateCategory(...args) {
    return godViewRenderingMethods.stateCategory.call(this, ...args)
  }

  stateDisplayName(...args) {
    return godViewRenderingMethods.stateDisplayName.call(this, ...args)
  }

  stateReasonForNode(...args) {
    return godViewRenderingMethods.stateReasonForNode.call(this, ...args)
  }

  visibilityMask(...args) {
    return godViewRenderingMethods.visibilityMask.call(this, ...args)
  }

}

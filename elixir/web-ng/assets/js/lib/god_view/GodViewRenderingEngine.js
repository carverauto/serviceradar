import {godViewRenderingMethods} from "./rendering_methods"

const RENDERING_ENGINE_SHARED_METHODS = [
  "renderGraph",
  "stateDisplayName",
  "edgeTopologyClass",
]

const RENDERING_ENGINE_CONTEXT_METHODS = [
  "autoFitViewState",
  "buildBitmapFallbackMetadata",
  "buildGraphLayers",
  "buildNodeAndLabelLayers",
  "buildPacketFlowInstances",
  "buildTransportAndEffectLayers",
  "buildVisibleGraphData",
  "computeTraversalMask",
  "connectionKindFromLabel",
  "defaultStateReason",
  "edgeEnabledByTopologyLayer",
  "edgeIsFocused",
  "edgeLayerId",
  "edgeTelemetryArcColors",
  "edgeTelemetryColor",
  "edgeTopologyClass",
  "edgeTopologyClassFromLabel",
  "edgeWidthPixels",
  "ensureBitmapMetadata",
  "escapeHtml",
  "focusNodeByIndex",
  "formatCapacity",
  "formatPps",
  "getNodeTooltip",
  "handleHover",
  "handlePick",
  "humanizeCausalReason",
  "nodeColor",
  "nodeIndexLookup",
  "nodeMetricText",
  "nodeNeutralColor",
  "nodeRefByIndex",
  "nodeReferenceAction",
  "nodeStatusColor",
  "nodeStatusIcon",
  "normalizeDisplayLabel",
  "normalizePipelineStats",
  "pipelineStatsFromHeaders",
  "renderGraph",
  "renderSelectionDetails",
  "selectEdgeLabels",
  "stateCategory",
  "stateDisplayName",
  "stateReasonForNode",
  "visibilityMask",
]

function bindApiMethods(instance, methods) {
  return Object.fromEntries(methods.map((method) => [method, instance[method].bind(instance)]))
}

export default class GodViewRenderingEngine {
  constructor(context) {
    this.context = context
  }

  getContextApi() {
    return bindApiMethods(this, RENDERING_ENGINE_CONTEXT_METHODS)
  }

  getSharedApi() {
    return bindApiMethods(this, RENDERING_ENGINE_SHARED_METHODS)
  }

  autoFitViewState(...args) {
    return godViewRenderingMethods.autoFitViewState.call(this.context, ...args)
  }

  buildBitmapFallbackMetadata(...args) {
    return godViewRenderingMethods.buildBitmapFallbackMetadata.call(this.context, ...args)
  }

  buildGraphLayers(...args) {
    return godViewRenderingMethods.buildGraphLayers.call(this.context, ...args)
  }

  buildNodeAndLabelLayers(...args) {
    return godViewRenderingMethods.buildNodeAndLabelLayers.call(this.context, ...args)
  }

  buildPacketFlowInstances(...args) {
    return godViewRenderingMethods.buildPacketFlowInstances.call(this.context, ...args)
  }

  buildTransportAndEffectLayers(...args) {
    return godViewRenderingMethods.buildTransportAndEffectLayers.call(this.context, ...args)
  }

  buildVisibleGraphData(...args) {
    return godViewRenderingMethods.buildVisibleGraphData.call(this.context, ...args)
  }

  computeTraversalMask(...args) {
    return godViewRenderingMethods.computeTraversalMask.call(this.context, ...args)
  }

  connectionKindFromLabel(...args) {
    return godViewRenderingMethods.connectionKindFromLabel.call(this.context, ...args)
  }

  defaultStateReason(...args) {
    return godViewRenderingMethods.defaultStateReason.call(this.context, ...args)
  }

  edgeEnabledByTopologyLayer(...args) {
    return godViewRenderingMethods.edgeEnabledByTopologyLayer.call(this.context, ...args)
  }

  edgeIsFocused(...args) {
    return godViewRenderingMethods.edgeIsFocused.call(this.context, ...args)
  }

  edgeLayerId(...args) {
    return godViewRenderingMethods.edgeLayerId.call(this.context, ...args)
  }

  edgeTelemetryArcColors(...args) {
    return godViewRenderingMethods.edgeTelemetryArcColors.call(this.context, ...args)
  }

  edgeTelemetryColor(...args) {
    return godViewRenderingMethods.edgeTelemetryColor.call(this.context, ...args)
  }

  edgeTopologyClass(...args) {
    return godViewRenderingMethods.edgeTopologyClass.call(this.context, ...args)
  }

  edgeTopologyClassFromLabel(...args) {
    return godViewRenderingMethods.edgeTopologyClassFromLabel.call(this.context, ...args)
  }

  edgeWidthPixels(...args) {
    return godViewRenderingMethods.edgeWidthPixels.call(this.context, ...args)
  }

  ensureBitmapMetadata(...args) {
    return godViewRenderingMethods.ensureBitmapMetadata.call(this.context, ...args)
  }

  escapeHtml(...args) {
    return godViewRenderingMethods.escapeHtml.call(this.context, ...args)
  }

  focusNodeByIndex(...args) {
    return godViewRenderingMethods.focusNodeByIndex.call(this.context, ...args)
  }

  formatCapacity(...args) {
    return godViewRenderingMethods.formatCapacity.call(this.context, ...args)
  }

  formatPps(...args) {
    return godViewRenderingMethods.formatPps.call(this.context, ...args)
  }

  getNodeTooltip(...args) {
    return godViewRenderingMethods.getNodeTooltip.call(this.context, ...args)
  }

  handleHover(...args) {
    return godViewRenderingMethods.handleHover.call(this.context, ...args)
  }

  handlePick(...args) {
    return godViewRenderingMethods.handlePick.call(this.context, ...args)
  }

  humanizeCausalReason(...args) {
    return godViewRenderingMethods.humanizeCausalReason.call(this.context, ...args)
  }

  nodeColor(...args) {
    return godViewRenderingMethods.nodeColor.call(this.context, ...args)
  }

  nodeIndexLookup(...args) {
    return godViewRenderingMethods.nodeIndexLookup.call(this.context, ...args)
  }

  nodeMetricText(...args) {
    return godViewRenderingMethods.nodeMetricText.call(this.context, ...args)
  }

  nodeNeutralColor(...args) {
    return godViewRenderingMethods.nodeNeutralColor.call(this.context, ...args)
  }

  nodeRefByIndex(...args) {
    return godViewRenderingMethods.nodeRefByIndex.call(this.context, ...args)
  }

  nodeReferenceAction(...args) {
    return godViewRenderingMethods.nodeReferenceAction.call(this.context, ...args)
  }

  nodeStatusColor(...args) {
    return godViewRenderingMethods.nodeStatusColor.call(this.context, ...args)
  }

  nodeStatusIcon(...args) {
    return godViewRenderingMethods.nodeStatusIcon.call(this.context, ...args)
  }

  normalizeDisplayLabel(...args) {
    return godViewRenderingMethods.normalizeDisplayLabel.call(this.context, ...args)
  }

  normalizePipelineStats(...args) {
    return godViewRenderingMethods.normalizePipelineStats.call(this.context, ...args)
  }

  pipelineStatsFromHeaders(...args) {
    return godViewRenderingMethods.pipelineStatsFromHeaders.call(this.context, ...args)
  }

  renderGraph(...args) {
    return godViewRenderingMethods.renderGraph.call(this.context, ...args)
  }

  renderSelectionDetails(...args) {
    return godViewRenderingMethods.renderSelectionDetails.call(this.context, ...args)
  }

  selectEdgeLabels(...args) {
    return godViewRenderingMethods.selectEdgeLabels.call(this.context, ...args)
  }

  stateCategory(...args) {
    return godViewRenderingMethods.stateCategory.call(this.context, ...args)
  }

  stateDisplayName(...args) {
    return godViewRenderingMethods.stateDisplayName.call(this.context, ...args)
  }

  stateReasonForNode(...args) {
    return godViewRenderingMethods.stateReasonForNode.call(this.context, ...args)
  }

  visibilityMask(...args) {
    return godViewRenderingMethods.visibilityMask.call(this.context, ...args)
  }
}

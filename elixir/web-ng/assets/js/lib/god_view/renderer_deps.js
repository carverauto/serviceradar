export function buildLayoutDeps(context) {
  return {
    renderGraph: (...args) => context.rendering.renderGraph(...args),
    stateDisplayName: (...args) => context.rendering.stateDisplayName(...args),
    edgeTopologyClass: (...args) => context.rendering.edgeTopologyClass(...args),
  }
}

export function buildRenderingDeps(context) {
  return {
    resolveZoomTier: (...args) => context.layout.resolveZoomTier(...args),
    setZoomTier: (...args) => context.layout.setZoomTier(...args),
    reshapeGraph: (...args) => context.layout.reshapeGraph(...args),
    geoGridData: (...args) => context.layout.geoGridData(...args),
    ensureDeck: (...args) => context.lifecycle.ensureDeck(...args),
  }
}

export function buildLifecycleDeps(context) {
  return {
    renderGraph: (...args) => context.rendering.renderGraph(...args),
    focusNodeByIndex: (...args) => context.rendering.focusNodeByIndex(...args),
    ensureBitmapMetadata: (...args) => context.rendering.ensureBitmapMetadata(...args),
    pipelineStatsFromHeaders: (...args) => context.rendering.pipelineStatsFromHeaders(...args),
    normalizePipelineStats: (...args) => context.rendering.normalizePipelineStats(...args),
    decodeArrowGraph: (...args) => context.lifecycle.decodeArrowGraph(...args),
    normalizeDisplayLabel: (...args) => context.rendering.normalizeDisplayLabel(...args),
    edgeTopologyClassFromLabel: (...args) => context.rendering.edgeTopologyClassFromLabel(...args),
    setZoomTier: (...args) => context.layout.setZoomTier(...args),
    resolveZoomTier: (...args) => context.layout.resolveZoomTier(...args),
    prepareGraphLayout: (...args) => context.layout.prepareGraphLayout(...args),
    graphTopologyStamp: (...args) => context.layout.graphTopologyStamp(...args),
    sameTopology: (...args) => context.layout.sameTopology(...args),
    animateTransition: (...args) => context.layout.animateTransition(...args),
  }
}

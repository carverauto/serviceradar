/**
 * @typedef {object} GodViewState
 * @property {Element} [el]
 * @property {(name: string, payload: unknown) => void} [pushEvent]
 * @property {(name: string, handler: Function) => void} [handleEvent]
 * @property {string} [csrfToken]
 */

/**
 * @typedef {object} GodViewLayoutApi
 * @property {(...args: any[]) => any} resolveZoomTier
 * @property {(...args: any[]) => any} setZoomTier
 * @property {(...args: any[]) => any} reshapeGraph
 * @property {(...args: any[]) => any} geoGridData
 * @property {(...args: any[]) => any} prepareGraphLayout
 * @property {(...args: any[]) => any} graphTopologyStamp
 * @property {(...args: any[]) => any} sameTopology
 * @property {(...args: any[]) => any} animateTransition
 */

/**
 * @typedef {object} GodViewRenderingApi
 * @property {(...args: any[]) => any} renderGraph
 * @property {(...args: any[]) => any} stateDisplayName
 * @property {(...args: any[]) => any} edgeTopologyClass
 * @property {(...args: any[]) => any} focusNodeByIndex
 * @property {(...args: any[]) => any} ensureBitmapMetadata
 * @property {(...args: any[]) => any} pipelineStatsFromHeaders
 * @property {(...args: any[]) => any} normalizePipelineStats
 * @property {(...args: any[]) => any} normalizeDisplayLabel
 * @property {(...args: any[]) => any} edgeTopologyClassFromLabel
 * @property {(...args: any[]) => any} getNodeTooltip
 * @property {(...args: any[]) => any} handleHover
 * @property {(...args: any[]) => any} handlePick
 */

/**
 * @typedef {object} GodViewLifecycleApi
 * @property {(...args: any[]) => any} ensureDeck
 * @property {(...args: any[]) => any} decodeArrowGraph
 */

/**
 * @typedef {object} GodViewRuntimeContext
 * @property {GodViewState} state
 * @property {Partial<GodViewLayoutApi>} layout
 * @property {Partial<GodViewRenderingApi>} rendering
 * @property {Partial<GodViewLifecycleApi>} lifecycle
 */

/**
 * @typedef {object} GodViewLayoutDeps
 * @property {(...args: any[]) => any} renderGraph
 * @property {(...args: any[]) => any} stateDisplayName
 * @property {(...args: any[]) => any} edgeTopologyClass
 */
export const LAYOUT_DEP_KEYS = ["renderGraph", "stateDisplayName", "edgeTopologyClass"]

/**
 * @typedef {object} GodViewRenderingDeps
 * @property {(...args: any[]) => any} resolveZoomTier
 * @property {(...args: any[]) => any} setZoomTier
 * @property {(...args: any[]) => any} reshapeGraph
 * @property {(...args: any[]) => any} geoGridData
 * @property {(...args: any[]) => any} ensureDeck
 */
export const RENDERING_DEP_KEYS = ["resolveZoomTier", "setZoomTier", "reshapeGraph", "geoGridData", "ensureDeck"]

/**
 * @typedef {object} GodViewLifecycleDeps
 * @property {(...args: any[]) => any} renderGraph
 * @property {(...args: any[]) => any} focusNodeByIndex
 * @property {(...args: any[]) => any} ensureBitmapMetadata
 * @property {(...args: any[]) => any} pipelineStatsFromHeaders
 * @property {(...args: any[]) => any} normalizePipelineStats
 * @property {(...args: any[]) => any} decodeArrowGraph
 * @property {(...args: any[]) => any} normalizeDisplayLabel
 * @property {(...args: any[]) => any} edgeTopologyClassFromLabel
 * @property {(...args: any[]) => any} getNodeTooltip
 * @property {(...args: any[]) => any} handleHover
 * @property {(...args: any[]) => any} handlePick
 * @property {(...args: any[]) => any} setZoomTier
 * @property {(...args: any[]) => any} resolveZoomTier
 * @property {(...args: any[]) => any} prepareGraphLayout
 * @property {(...args: any[]) => any} graphTopologyStamp
 * @property {(...args: any[]) => any} sameTopology
 * @property {(...args: any[]) => any} animateTransition
 */
export const LIFECYCLE_DEP_KEYS = [
  "renderGraph",
  "focusNodeByIndex",
  "ensureBitmapMetadata",
  "pipelineStatsFromHeaders",
  "normalizePipelineStats",
  "decodeArrowGraph",
  "normalizeDisplayLabel",
  "edgeTopologyClassFromLabel",
  "getNodeTooltip",
  "handleHover",
  "handlePick",
  "setZoomTier",
  "resolveZoomTier",
  "prepareGraphLayout",
  "graphTopologyStamp",
  "sameTopology",
  "animateTransition",
]

/**
 * @param {GodViewRuntimeContext} context
 * @returns {GodViewLayoutDeps}
 */
export function buildLayoutDeps(context) {
  return {
    renderGraph: (...args) => context.rendering.renderGraph(...args),
    stateDisplayName: (...args) => context.rendering.stateDisplayName(...args),
    edgeTopologyClass: (...args) => context.rendering.edgeTopologyClass(...args),
  }
}

/**
 * @param {GodViewRuntimeContext} context
 * @returns {GodViewRenderingDeps}
 */
export function buildRenderingDeps(context) {
  return {
    resolveZoomTier: (...args) => context.layout.resolveZoomTier(...args),
    setZoomTier: (...args) => context.layout.setZoomTier(...args),
    reshapeGraph: (...args) => context.layout.reshapeGraph(...args),
    geoGridData: (...args) => context.layout.geoGridData(...args),
    ensureDeck: (...args) => context.lifecycle.ensureDeck(...args),
  }
}

/**
 * @param {GodViewRuntimeContext} context
 * @returns {GodViewLifecycleDeps}
 */
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
    getNodeTooltip: (...args) => context.rendering.getNodeTooltip(...args),
    handleHover: (...args) => context.rendering.handleHover(...args),
    handlePick: (...args) => context.rendering.handlePick(...args),
    setZoomTier: (...args) => context.layout.setZoomTier(...args),
    resolveZoomTier: (...args) => context.layout.resolveZoomTier(...args),
    prepareGraphLayout: (...args) => context.layout.prepareGraphLayout(...args),
    graphTopologyStamp: (...args) => context.layout.graphTopologyStamp(...args),
    sameTopology: (...args) => context.layout.sameTopology(...args),
    animateTransition: (...args) => context.layout.animateTransition(...args),
  }
}

import GodViewLayoutEngine from "./god_view/GodViewLayoutEngine"
import GodViewLifecycleController from "./god_view/GodViewLifecycleController"
import GodViewRenderingEngine from "./god_view/GodViewRenderingEngine"

export default class GodViewRenderer {
  constructor(el, pushEvent, handleEvent, options = {}) {
    this.context = {
      state: {
        el,
        pushEvent,
        handleEvent,
        csrfToken:
          options.csrfToken || document.querySelector("meta[name='csrf-token']")?.getAttribute("content") || "",
      },
      layout: {},
      rendering: {},
      lifecycle: {},
    }

    const layoutDeps = {
      renderGraph: (...args) => this.context.rendering.renderGraph(...args),
      stateDisplayName: (...args) => this.context.rendering.stateDisplayName(...args),
      edgeTopologyClass: (...args) => this.context.rendering.edgeTopologyClass(...args),
    }

    const renderingDeps = {
      resolveZoomTier: (...args) => this.context.layout.resolveZoomTier(...args),
      setZoomTier: (...args) => this.context.layout.setZoomTier(...args),
      reshapeGraph: (...args) => this.context.layout.reshapeGraph(...args),
      geoGridData: (...args) => this.context.layout.geoGridData(...args),
      ensureDeck: (...args) => this.context.lifecycle.ensureDeck(...args),
    }

    const lifecycleDeps = {
      renderGraph: (...args) => this.context.rendering.renderGraph(...args),
      focusNodeByIndex: (...args) => this.context.rendering.focusNodeByIndex(...args),
      ensureBitmapMetadata: (...args) => this.context.rendering.ensureBitmapMetadata(...args),
      pipelineStatsFromHeaders: (...args) => this.context.rendering.pipelineStatsFromHeaders(...args),
      normalizePipelineStats: (...args) => this.context.rendering.normalizePipelineStats(...args),
      decodeArrowGraph: (...args) => this.context.lifecycle.decodeArrowGraph(...args),
      normalizeDisplayLabel: (...args) => this.context.rendering.normalizeDisplayLabel(...args),
      edgeTopologyClassFromLabel: (...args) => this.context.rendering.edgeTopologyClassFromLabel(...args),
      setZoomTier: (...args) => this.context.layout.setZoomTier(...args),
      resolveZoomTier: (...args) => this.context.layout.resolveZoomTier(...args),
      prepareGraphLayout: (...args) => this.context.layout.prepareGraphLayout(...args),
      graphTopologyStamp: (...args) => this.context.layout.graphTopologyStamp(...args),
      sameTopology: (...args) => this.context.layout.sameTopology(...args),
      animateTransition: (...args) => this.context.layout.animateTransition(...args),
    }

    this.layoutEngine = new GodViewLayoutEngine({state: this.context.state, deps: layoutDeps})
    this.renderingEngine = new GodViewRenderingEngine({state: this.context.state, deps: renderingDeps})
    this.lifecycleController = new GodViewLifecycleController({state: this.context.state, deps: lifecycleDeps})

    this.context.layout = this.layoutEngine.getContextApi()
    this.context.rendering = this.renderingEngine.getContextApi()
    this.context.lifecycle = this.lifecycleController.getContextApi()
  }

  mount() {
    this.lifecycleController.mount()
  }

  update() {
    if (typeof this.context.state.updated === "function") this.context.state.updated()
  }

  destroy() {
    this.lifecycleController.destroy()
  }
}

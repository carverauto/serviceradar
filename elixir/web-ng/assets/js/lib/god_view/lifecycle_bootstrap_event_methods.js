export const godViewLifecycleBootstrapEventMethods = {
  registerLifecycleEvents() {
    this.handleEvent("god_view:set_filters", ({filters}) => {
      if (filters && typeof filters === "object") {
        this.filters = {
          root_cause: filters.root_cause !== false,
          affected: filters.affected !== false,
          healthy: filters.healthy !== false,
          unknown: filters.unknown !== false,
        }
        if (this.lastGraph) this.renderGraph(this.lastGraph)
      }
    })

    this.handleEvent("god_view:set_zoom_mode", ({mode}) => {
      const normalized = mode === "global" || mode === "regional" || mode === "local" ? mode : "auto"
      this.zoomMode = normalized

      if (!this.deck) return

      if (normalized === "auto") {
        this.setZoomTier(this.resolveZoomTier(this.viewState.zoom || 0), true)
        return
      }

      const zoomByTier = {global: -0.9, regional: 0.35, local: 1.65}
      this.viewState = {
        ...this.viewState,
        zoom: zoomByTier[normalized] || this.viewState.zoom,
      }
      this.userCameraLocked = true
      this.isProgrammaticViewUpdate = true
      this.deck.setProps({viewState: this.viewState})
      this.setZoomTier(normalized, true)
    })

    this.handleEvent("god_view:set_layers", ({layers}) => {
      if (layers && typeof layers === "object") {
        this.layers = {
          mantle: layers.mantle !== false,
          crust: layers.crust !== false,
          atmosphere: layers.atmosphere !== false,
          security: layers.security !== false,
        }
        if (this.lastGraph) this.renderGraph(this.lastGraph)
      }
    })

    this.handleEvent("god_view:set_topology_layers", ({layers}) => {
      if (layers && typeof layers === "object") {
        this.topologyLayers = {
          backbone: layers.backbone !== false,
          inferred: layers.inferred === true,
          endpoints: layers.endpoints === true,
        }
        if (this.lastGraph) this.renderGraph(this.lastGraph)
      }
    })
  },
}

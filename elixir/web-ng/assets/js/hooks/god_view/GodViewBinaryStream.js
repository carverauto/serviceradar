let GodViewRendererModule = null

async function loadGodViewRenderer() {
  if (!GodViewRendererModule) {
    const mod = await import("../../lib/god_view/WorldMapRenderer")
    GodViewRendererModule = mod.default
  }
  return GodViewRendererModule
}

export default {
  async mounted() {
    const csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content") || ""
    const GodViewRenderer = await loadGodViewRenderer()
    if (this.isDestroyed) return
    this.renderer = new GodViewRenderer(
      this.el,
      this.pushEvent.bind(this),
      this.handleEvent.bind(this),
      {csrfToken},
    )
    this.renderer.mount()
  },
  updated() {
    this.renderer?.update?.()
  },
  destroyed() {
    this.isDestroyed = true
    this.renderer?.destroy?.()
    this.renderer = null
  },
}

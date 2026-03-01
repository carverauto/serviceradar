export default {
  storageKey: "sr:god_view:controls_collapsed",
  mounted() {
    this.syncFromStorage()
  },
  updated() {
    this.persistCurrentState()
  },
  syncFromStorage() {
    const stored = window.localStorage?.getItem(this.storageKey)
    if (stored !== "true" && stored !== "false") {
      this.persistCurrentState()
      return
    }

    const domCollapsed = this.el.dataset.collapsed === "true"
    const desired = stored === "true"
    if (desired !== domCollapsed) {
      this.pushEvent("set_controls_panel", {collapsed: desired})
    }
  },
  persistCurrentState() {
    const collapsed = this.el.dataset.collapsed === "true"
    window.localStorage?.setItem(this.storageKey, collapsed ? "true" : "false")
  },
}

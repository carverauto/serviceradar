export default {
  mounted() {
    this._apply()
  },
  updated() {
    this._apply()
  },
  _apply() {
    const iso = this.el.dataset.iso || ""
    if (!iso) return
    const d = new Date(iso)
    if (!(d instanceof Date) || Number.isNaN(d.getTime())) return

    // Local time. Full ISO remains on the parent cell title.
    try {
      this.el.textContent = d.toLocaleTimeString([], {hour: "2-digit", minute: "2-digit", second: "2-digit"})
    } catch (_e) {
      this.el.textContent = d.toISOString().slice(11, 19)
    }
  },
}

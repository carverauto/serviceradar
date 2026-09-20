const WINDOWS = new Set(["last_15m", "last_1h", "last_6h", "last_24h", "last_7d", "last_30d", "last_90d"])
const DEFAULTS = {netflow: "last_15m", events: "last_24h"}
const cookieName = kind => `dashboard_${kind}_window`

export function dashboardWindowPreferences(cookie = document.cookie) {
  const cookies = new Map(String(cookie || "").split(";").map(part => {
    const index = part.indexOf("=")
    return [part.slice(0, index).trim(), part.slice(index + 1)]
  }))
  return Object.fromEntries(Object.entries(DEFAULTS).map(([kind, fallback]) => {
    let value
    try { value = decodeURIComponent(cookies.get(cookieName(kind)) || "") } catch (_error) {}
    return [kind, WINDOWS.has(value) ? value : fallback]
  }))
}

export default {
  mounted() {
    this.onChange = () => {
      const kind = this.el.dataset.windowKind
      const window = this.el.value
      if (!Object.hasOwn(DEFAULTS, kind) || !WINDOWS.has(window)) return
      document.cookie = `${cookieName(kind)}=${encodeURIComponent(window)}; Max-Age=31536000; Path=/; SameSite=Lax`
      this.pushEvent("select_dashboard_window", {kind, window})
    }
    this.el.addEventListener("change", this.onChange)
  },
  updated() {
    const value = this.el.dataset.window
    if (WINDOWS.has(value)) this.el.value = value
  },
  destroyed() {
    this.el.removeEventListener("change", this.onChange)
  },
}

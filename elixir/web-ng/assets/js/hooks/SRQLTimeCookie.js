export default {
  mounted() {
    this._input = this.el.querySelector('input[name="q"]')
    if (!this._input) return

    this._debounceTimer = null
    this._lastSynced = (this.el.dataset.query || "").toString()

    const hasQParam = () => {
      try {
        return new URLSearchParams(window.location.search).has("q")
      } catch (_e) {
        return false
      }
    }

    const cookieGet = (name) => {
      const needle = `${name}=`
      const parts = (document.cookie || "").split(";").map((s) => s.trim())
      for (const part of parts) {
        if (part.startsWith(needle)) return decodeURIComponent(part.slice(needle.length))
      }
      return null
    }

    const cookieSet = (name, value, days = 365) => {
      if (!value) return
      const maxAge = days * 24 * 60 * 60
      document.cookie = `${name}=${encodeURIComponent(value)}; Max-Age=${maxAge}; Path=/; SameSite=Lax`
    }

    const extractTimeToken = (q) => {
      if (!q || typeof q !== "string") return null
      const m = q.match(/(?:^|\\s)time:(?:\"([^\"]+)\"|(\\S+))/)
      return m ? (m[1] || m[2] || null) : null
    }

    const upsertTimeToken = (q, timeToken) => {
      if (!q || typeof q !== "string") q = ""
      const trimmed = q.trim()
      const replacement = ` time:${timeToken}`
      if (/(?:^|\\s)time:(?:\"[^\"]+\"|\\S+)/.test(trimmed)) {
        return trimmed.replace(/(?:^|\\s)time:(?:\"[^\"]+\"|\\S+)/, replacement).trim()
      }
      return (trimmed + replacement).trim()
    }

    const persistFromInput = () => {
      const token = extractTimeToken(this._input.value)
      if (token) cookieSet("srql_time", token)
    }

    const maybeRestore = () => {
      if (hasQParam()) {
        // Respect deep links; just persist whatever the URL/query contains.
        persistFromInput()
        return
      }

      const token = cookieGet("srql_time")
      if (!token) return

      const current = (this._input.value || "").toString()
      const next = upsertTimeToken(current, token)
      if (next !== current) {
        this._input.value = next
        if (typeof this.el.requestSubmit === "function") {
          this.el.requestSubmit()
        } else {
          this.el.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }))
        }
      }
    }

    this._onInput = () => {
      clearTimeout(this._debounceTimer)
      this._debounceTimer = setTimeout(() => persistFromInput(), 150)
    }
    this._onSubmit = () => persistFromInput()

    this._input.addEventListener("input", this._onInput)
    this.el.addEventListener("submit", this._onSubmit)

    maybeRestore()
  },
  updated() {
    // LiveView keeps form inputs "sticky" to preserve user typing, which is usually good.
    // For SRQL-driven pages, other UI controls can emit SRQL via push_patch, and we want
    // the topbar query to reflect that new query. Sync it when the input isn't focused.
    if (!this._input) return
    if (document.activeElement === this._input) return

    const desired = (this.el.dataset.query || "").toString()
    if (!desired) return

    const current = (this._input.value || "").toString()
    if (current !== desired) {
      this._input.value = desired
      this._lastSynced = desired
    }
  },
  destroyed() {
    if (this._input && this._onInput) this._input.removeEventListener("input", this._onInput)
    if (this._onSubmit) this.el.removeEventListener("submit", this._onSubmit)
    clearTimeout(this._debounceTimer)
  }
}

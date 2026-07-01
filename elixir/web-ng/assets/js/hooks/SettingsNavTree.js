// SettingsNavTree: the Settings catalog left-panel 2-level tree.
//
// Renders server-side from `Settings.Catalog.nav_tree/2` as a set of native
// `<details data-nav-group>` parent-groups. This hook adds two client behaviours:
//
//   1. Collapse persistence — each group's open/closed state is remembered in
//      localStorage across navigation. The server still expands the ACTIVE group
//      by default (via the `open` attribute); an explicit user toggle overrides
//      and persists. (Purely cosmetic; never touches the server.)
//   2. Live "Search views…" filter — typing in the [data-view-filter-input] box
//      hides non-matching leaf views, hides groups with zero matches, and
//      temporarily expands groups that do match. Clearing the box restores each
//      group to its persisted (or server-default) state.
const KEY_PREFIX = "sr:settings-nav:"

export default {
  mounted() {
    this.filterInput = this.el.querySelector("[data-view-filter-input]")
    this.emptyEl = this.el.querySelector("[data-view-filter-empty]")
    this._filtering = false

    this._restoreAll()

    this._onToggle = (e) => this._save(e.currentTarget)
    this._groups().forEach((g) => g.addEventListener("toggle", this._onToggle))

    if (this.filterInput) {
      this._onInput = () => this._filter()
      this.filterInput.addEventListener("input", this._onInput)
    }
  },

  destroyed() {
    this._groups().forEach((g) => g.removeEventListener("toggle", this._onToggle))
    if (this.filterInput && this._onInput) {
      this.filterInput.removeEventListener("input", this._onInput)
    }
  },

  _groups() {
    return Array.from(this.el.querySelectorAll("[data-nav-group]"))
  },

  _key(g) {
    return KEY_PREFIX + (g.getAttribute("data-group-id") || "")
  },

  _restoreAll() {
    this._groups().forEach((g) => this._restore(g))
  },

  _restore(g) {
    // The active group (server-flagged via `data-active-group`) always opens so a
    // deep-link reveals the active leaf, even over a stale persisted "closed".
    // Every other group restores its persisted open/closed state, falling back to
    // the server-rendered default when there is none.
    if (g.hasAttribute("data-active-group")) {
      g.open = true
      return
    }

    let saved = null
    try {
      saved = localStorage.getItem(this._key(g))
    } catch (_) {
      saved = null
    }
    if (saved === "open") g.open = true
    else if (saved === "closed") g.open = false
    // else: leave the server-rendered default.
  },

  _save(g) {
    if (this._filtering) return
    try {
      localStorage.setItem(this._key(g), g.open ? "open" : "closed")
    } catch (_) {
      // ignore quota / privacy-mode errors
    }
  },

  _filter() {
    const query = (this.filterInput.value || "").trim().toLowerCase()
    let total = 0

    this._filtering = true
    this._groups().forEach((g) => {
      let visible = 0
      g.querySelectorAll("[data-view-search]").forEach((item) => {
        const haystack = item.getAttribute("data-view-search") || ""
        const match = query === "" || haystack.includes(query)
        item.classList.toggle("hidden", !match)
        if (match) visible += 1
      })

      g.classList.toggle("hidden", visible === 0)

      if (query !== "") {
        g.open = visible > 0
      } else {
        this._restore(g)
      }

      total += visible
    })
    this._filtering = false

    if (this.emptyEl) {
      this.emptyEl.classList.toggle("hidden", !(query !== "" && total === 0))
    }
  },
}

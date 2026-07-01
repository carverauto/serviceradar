// CommandPalette: Ctrl/Cmd+K command palette for the Settings shell.
//
// The dialog markup + item list are rendered server-side from
// `Settings.Catalog.palette_index/1`. This hook adds the client behaviour:
// open on Ctrl/Cmd+K, fuzzy substring filter, arrow-key roving, Enter to open
// the highlighted view, ESC/backdrop to close, and focus restore on close.
const ACTIVE_CLASS = "menu-active"

export default {
  mounted() {
    this.items = () => Array.from(this.el.querySelectorAll("[data-command-palette-item]"))
    this.input = this.el.querySelector("[data-command-palette-input]")
    this.empty = this.el.querySelector("[data-command-palette-empty]")
    this.activeIndex = 0
    this.lastFocused = null

    this._onWindowKeydown = (e) => this._maybeToggle(e)
    this._onInput = () => this._filter()
    this._onDialogKeydown = (e) => this._onKeydown(e)
    this._onClose = () => this._restoreFocus()

    window.addEventListener("keydown", this._onWindowKeydown)
    if (this.input) this.input.addEventListener("input", this._onInput)
    this.el.addEventListener("keydown", this._onDialogKeydown)
    this.el.addEventListener("close", this._onClose)
  },

  destroyed() {
    window.removeEventListener("keydown", this._onWindowKeydown)
    if (this.input) this.input.removeEventListener("input", this._onInput)
    this.el.removeEventListener("keydown", this._onDialogKeydown)
    this.el.removeEventListener("close", this._onClose)
  },

  _maybeToggle(e) {
    if ((e.ctrlKey || e.metaKey) && (e.key === "k" || e.key === "K")) {
      e.preventDefault()
      if (this.el.open) {
        this.el.close()
      } else {
        this._open()
      }
    }
  },

  _open() {
    this.lastFocused = document.activeElement
    if (typeof this.el.showModal === "function") {
      this.el.showModal()
    } else {
      this.el.setAttribute("open", "open")
    }
    if (this.input) {
      this.input.value = ""
      this.input.focus()
    }
    this._filter()
  },

  _restoreFocus() {
    if (this.lastFocused && typeof this.lastFocused.focus === "function") {
      this.lastFocused.focus()
    }
    this.lastFocused = null
  },

  _filter() {
    const query = (this.input ? this.input.value : "").trim().toLowerCase()
    const tokens = query.split(/\s+/).filter(Boolean)
    let visibleCount = 0

    this.items().forEach((item) => {
      const haystack = item.getAttribute("data-search") || ""
      const match = tokens.every((t) => haystack.indexOf(t) !== -1)
      item.classList.toggle("hidden", !match)
      if (match) visibleCount += 1
    })

    if (this.empty) this.empty.classList.toggle("hidden", visibleCount !== 0)
    this.activeIndex = 0
    this._highlight()
  },

  _visibleItems() {
    return this.items().filter((item) => !item.classList.contains("hidden"))
  },

  _highlight() {
    const visible = this._visibleItems()
    if (visible.length === 0) return
    if (this.activeIndex < 0) this.activeIndex = 0
    if (this.activeIndex >= visible.length) this.activeIndex = visible.length - 1

    visible.forEach((item, idx) => {
      const link = item.querySelector("[data-command-palette-link]")
      if (!link) return
      if (idx === this.activeIndex) {
        link.classList.add(ACTIVE_CLASS)
        link.scrollIntoView({block: "nearest"})
      } else {
        link.classList.remove(ACTIVE_CLASS)
      }
    })
  },

  _onKeydown(e) {
    if (e.key === "ArrowDown") {
      e.preventDefault()
      this.activeIndex += 1
      this._highlight()
    } else if (e.key === "ArrowUp") {
      e.preventDefault()
      this.activeIndex -= 1
      this._highlight()
    } else if (e.key === "Enter") {
      e.preventDefault()
      const visible = this._visibleItems()
      const item = visible[this.activeIndex]
      const link = item && item.querySelector("[data-command-palette-link]")
      if (link) {
        this.el.close()
        link.click()
      }
    }
  },
}

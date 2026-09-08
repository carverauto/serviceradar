// CommandPalette: Ctrl/Cmd+K command palette for the Settings shell.
//
// The dialog markup + item list are rendered server-side from
// `Settings.Catalog.palette_index/1`. This hook adds the client behaviour:
// open on Ctrl/Cmd+K (or a click on a [data-command-palette-open] trigger),
// fuzzy substring filter, a live match count, arrow-key roving with a blue
// "Jump" affordance on the active row, Enter to open the highlighted view,
// ESC/backdrop/close-button to dismiss, and focus restore on close.
const ACTIVE_CLASS = "menu-active"

export default {
  mounted() {
    this.items = () => Array.from(this.el.querySelectorAll("[data-command-palette-item]"))
    this.input = this.el.querySelector("[data-command-palette-input]")
    this.empty = this.el.querySelector("[data-command-palette-empty]")
    this.count = this.el.querySelector("[data-command-palette-count]")
    this.closeBtn = this.el.querySelector("[data-command-palette-close]")
    this.activeIndex = 0
    this.lastFocused = null

    this._onWindowKeydown = (e) => this._maybeToggle(e)
    this._onDocClick = (e) => this._maybeOpenFromTrigger(e)
    this._onInput = () => this._filter()
    this._onDialogKeydown = (e) => this._onKeydown(e)
    this._onClose = () => this._restoreFocus()
    this._onCloseClick = () => this.el.close()

    window.addEventListener("keydown", this._onWindowKeydown)
    document.addEventListener("click", this._onDocClick)
    if (this.input) this.input.addEventListener("input", this._onInput)
    this.el.addEventListener("keydown", this._onDialogKeydown)
    this.el.addEventListener("close", this._onClose)
    if (this.closeBtn) this.closeBtn.addEventListener("click", this._onCloseClick)
  },

  destroyed() {
    window.removeEventListener("keydown", this._onWindowKeydown)
    document.removeEventListener("click", this._onDocClick)
    if (this.input) this.input.removeEventListener("input", this._onInput)
    this.el.removeEventListener("keydown", this._onDialogKeydown)
    this.el.removeEventListener("close", this._onClose)
    if (this.closeBtn) this.closeBtn.removeEventListener("click", this._onCloseClick)
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

  _maybeOpenFromTrigger(e) {
    const trigger = e.target.closest && e.target.closest("[data-command-palette-open]")
    if (trigger) {
      e.preventDefault()
      if (!this.el.open) this._open()
    }
  },

  _open() {
    this.lastFocused = document.activeElement
    if (typeof this.el.showModal === "function") {
      this.el.showModal()
    } else {
      this.el.setAttribute("open", "open")
    }
    this._filter()
    // Auto-focus the search box so the user can type immediately. This is
    // finicky: the input's `autofocus` attribute is only honoured on the FIRST
    // showModal() (subsequent opens ignore it), showModal() runs its own dialog
    // focusing steps, and daisyUI plays an open transition — any of which can
    // leave focus off the input if we grab it too early. So we re-assert focus
    // ourselves across several timings (this tick, after the next paint via a
    // double rAF, and after the transition settles), re-querying the node fresh
    // each time and skipping once focus has already landed.
    const focusInput = () => {
      const input = this.el.querySelector("[data-command-palette-input]")
      if (!input) return
      if (document.activeElement !== input) {
        input.focus()
        input.select()
      }
    }
    focusInput()
    requestAnimationFrame(() => requestAnimationFrame(focusInput))
    setTimeout(focusInput, 60)
    setTimeout(focusInput, 180)
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
    if (this.count) this.count.textContent = String(visibleCount)
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
      const active = idx === this.activeIndex
      const jump = link.querySelector("[data-command-palette-jump]")
      const title = link.querySelector("[data-command-palette-title]")

      link.classList.toggle(ACTIVE_CLASS, active)
      if (title) title.classList.toggle("text-accent", active)
      if (jump) {
        jump.classList.toggle("hidden", !active)
        jump.classList.toggle("flex", active)
      }
      if (active) link.scrollIntoView({block: "nearest"})
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

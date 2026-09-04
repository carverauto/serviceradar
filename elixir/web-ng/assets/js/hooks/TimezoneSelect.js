import {filterTimezoneOptions, matchingTimezoneOptions} from "../utils/timezone_options"

function setHidden(el, hidden) {
  if (!el) return
  const row = typeof el.closest === "function" ? el.closest("li") || el : el
  row.hidden = hidden
  row.classList.toggle("hidden", hidden)
}

export default {
  mounted() {
    this.open = false
    this.supported = []
    this._onFocus = () => this._open()
    this._onInput = () => this._onQuery()
    this._onKeydown = (event) => this._keydown(event)
    this._onBlur = () => this._scheduleClose()
    this._onPointerDown = (event) => this._pick(event)
    this._onDocumentPointerDown = (event) => this._outside(event)

    this.el.addEventListener("focus", this._onFocus)
    this.el.addEventListener("input", this._onInput)
    this.el.addEventListener("keydown", this._onKeydown)
    this.el.addEventListener("blur", this._onBlur)

    const listbox = this._listbox()
    if (listbox) listbox.addEventListener("pointerdown", this._onPointerDown)
    this.el.ownerDocument.addEventListener("pointerdown", this._onDocumentPointerDown)

    this._syncSupported()
    this._close()
  },

  updated() {
    const inputValue = this.el.value
    this._syncSupported()
    this.el.value = inputValue
    if (this.open) this._renderMatches()
    else this._close()
  },

  destroyed() {
    this._clearCloseTimer()
    this.el.removeEventListener("focus", this._onFocus)
    this.el.removeEventListener("input", this._onInput)
    this.el.removeEventListener("keydown", this._onKeydown)
    this.el.removeEventListener("blur", this._onBlur)
    const listbox = this._listbox()
    if (listbox) listbox.removeEventListener("pointerdown", this._onPointerDown)
    this.el.ownerDocument.removeEventListener("pointerdown", this._onDocumentPointerDown)
  },

  _listbox() {
    const optionsId = this.el.dataset.optionsId
    return optionsId ? this.el.ownerDocument.getElementById(optionsId) : null
  },

  _items() {
    const listbox = this._listbox()
    return listbox ? [...listbox.querySelectorAll("[data-timezone]")] : []
  },

  _empty() {
    const listbox = this._listbox()
    return listbox ? listbox.querySelector("[data-timezone-empty]") : null
  },

  _syncSupported() {
    const items = this._items()
    const serverZones = items.map((item) => item.dataset.timezone).filter(Boolean)
    this.supported = filterTimezoneOptions(serverZones, this.el.dataset.currentTimezone, {
      intl: globalThis.Intl,
    })
    this._renderMatches({closed: true})
  },

  _open() {
    this._clearCloseTimer()
    this.open = true
    if (typeof this.el.select === "function") this.el.select()
    this.el.setAttribute("aria-expanded", "true")
    this._renderMatches()
  },

  _close() {
    this.open = false
    this.el.setAttribute("aria-expanded", "false")
    this.el.removeAttribute("aria-activedescendant")
    setHidden(this._listbox(), true)
  },

  _scheduleClose() {
    this._clearCloseTimer()
    this._closeTimer = setTimeout(() => this._close(), 120)
  },

  _clearCloseTimer() {
    if (this._closeTimer) {
      clearTimeout(this._closeTimer)
      this._closeTimer = null
    }
  },

  _onQuery() {
    this._clearCloseTimer()
    this.open = true
    this.el.setAttribute("aria-expanded", "true")
    this._renderMatches()
  },

  _renderMatches({closed = false} = {}) {
    const listbox = this._listbox()
    if (!listbox) return

    const matches = closed
      ? this.supported
      : matchingTimezoneOptions(this.supported, this.el.value, this.el.dataset.currentTimezone)
    const matchSet = new Set(matches)

    for (const item of this._items()) {
      setHidden(item, !matchSet.has(item.dataset.timezone))
    }

    setHidden(this._empty(), matches.length > 0)
    setHidden(listbox, closed || !this.open)

    if (!closed && this.open) {
      const items = this._visibleItems()
      const current = items.findIndex((item) => item.dataset.timezone === this.el.value)
      this._syncActive(items, current === -1 ? 0 : current)
    }
  },

  _visibleItems() {
    return this._items().filter((item) => {
      const row = typeof item.closest === "function" ? item.closest("li") || item : item
      return !row.hidden && !row.classList.contains("hidden")
    })
  },

  _keydown(event) {
    if (event.key === "Escape") {
      event.preventDefault()
      this._close()
      return
    }

    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault()
      if (!this.open) this._open()
      this._move(event.key === "ArrowDown" ? 1 : -1)
      return
    }

    if (event.key === "Enter" && this.open) {
      event.preventDefault()
      const selected = this._enterSelection()
      if (selected) this._choose(selected)
      else this._close()
    }
  },

  _enterSelection() {
    const items = this._visibleItems()
    const highlighted = items.find((item) => item.classList.contains("bg-sr-subtle"))
    if (highlighted?.dataset.timezone) return highlighted.dataset.timezone

    const typed = (this.el.value || "").trim()
    const exact = items.find((item) => item.dataset.timezone === typed)
    if (exact?.dataset.timezone) return exact.dataset.timezone
    if (items.length === 1) return items[0].dataset.timezone

    return null
  },

  _move(delta) {
    const items = this._visibleItems()
    if (items.length === 0) return

    const current = items.findIndex((item) => item.classList.contains("bg-sr-subtle"))
    const start = current === -1 ? (delta > 0 ? -1 : 0) : current
    const next = Math.min(items.length - 1, Math.max(0, start + delta))
    this._syncActive(items, next)
  },

  _syncActive(items, activeIndex) {
    items.forEach((item, index) => {
      const active = index === activeIndex
      item.classList.toggle("bg-sr-subtle", active)
      item.setAttribute("aria-selected", active ? "true" : "false")
      if (!item.id) {
        item.id = `timezone-option-${String(item.dataset.timezone || "").replace(/[^A-Za-z0-9_-]/g, "-")}`
      }
    })

    const active = items[activeIndex]
    if (active?.id) {
      this.el.setAttribute("aria-activedescendant", active.id)
      active.scrollIntoView?.({block: "nearest"})
    } else {
      this.el.removeAttribute("aria-activedescendant")
    }
  },

  _pick(event) {
    const item = event.target.closest?.("[data-timezone]")
    if (!item?.dataset.timezone) return
    event.preventDefault()
    this._choose(item.dataset.timezone)
  },

  _choose(zone) {
    this.el.value = zone
    this._close()
  },

  _outside(event) {
    const listbox = this._listbox()
    if (event.target === this.el) return
    if (listbox?.contains?.(event.target)) return
    this._close()
  },
}

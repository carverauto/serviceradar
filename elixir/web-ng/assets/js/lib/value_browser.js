import {trapDialogFocus} from "./dialog"

const CONTROL = "rounded-sr-control border border-sr-line bg-sr-control px-3 py-2 text-sm text-sr-ink focus-visible:ring-2 focus-visible:ring-sr-focus"
const BUTTON = `${CONTROL} font-semibold hover:border-sr-line-hover disabled:opacity-50`

function element(tag, className = "", text = "") {
  const el = document.createElement(tag)
  el.className = className
  el.textContent = text
  return el
}
function button(label, action) {
  const el = element("button", BUTTON, label)
  el.type = "button"
  el.addEventListener("click", action)
  return el
}

/** Searchable pages shared by LiveView list browsers and client-owned pickers.
 * load returns {items: [{value, count, href?}], cursor}; null selected means browse-only.
 */
export class ValueBrowser {
  constructor({parent, load, selected = null, maxSelected = 32, onConfirm, onCancel}) {
    Object.assign(this, {load, maxSelected})
    this.selected = selected === null ? null : new Set(selected)
    this.trail = [null]
    this.page = 1
    this.el = element("div", "space-y-3")
    this.search = element("input", `${CONTROL} w-full`)
    this.search.type = "search"
    this.search.placeholder = "Filter values"
    this.search.autocomplete = "off"
    this.search.maxLength = 256
    this.search.setAttribute("aria-label", "Filter values")
    this.search.setAttribute("data-dialog-autofocus", "")
    this.search.addEventListener("input", () => {
      this.cancelRequest()
      this.trail = [null]
      this.page = 1
      this.setBusy(true)
      this.timer = setTimeout(() => void this.refresh(), 200)
    })
    this.summary = element("p", "text-xs text-sr-muted")
    this.summary.setAttribute("aria-live", "polite")
    this.selection = element("div", "flex max-h-28 flex-wrap gap-2 overflow-y-auto")
    this.list = element("div", "max-h-[24rem] overflow-y-auto rounded-lg border border-sr-line")
    this.first = button("First", () => {this.trail = [null]; this.page = 1; void this.refresh()})
    this.previous = button("Previous", () => {this.trail.pop(); this.page--; void this.refresh()})
    this.next = button("Next", () => {
      this.trail.push(this.cursor)
      if (this.trail.length > 100) this.trail.shift()
      this.page++; void this.refresh()
    })
    const pages = element("div", "flex items-center justify-between gap-3")
    pages.append(this.first, this.previous, this.next)
    this.retry = button("Retry", () => void this.refresh())
    this.retry.hidden = true
    this.error = element("p", "text-sm text-sr-ink empty:hidden")
    this.error.setAttribute("role", "alert")
    this.el.append(this.search, this.summary, this.selection, this.list, pages, this.error, this.retry)
    if (this.selected) {
      this.confirm = button("Use selected values", () => {
        try {onConfirm([...this.selected])} catch (error) {this.error.textContent = error.message}
      })
      const actions = element("div", "sr-ui-modal-action")
      actions.append(button("Cancel", onCancel), this.confirm)
      this.el.append(actions)
      this.renderSelection()
    }
    parent.append(this.el)
    void this.refresh()
  }

  cancelRequest() {clearTimeout(this.timer); this.request?.abort(); this.request = null}

  setBusy(busy) {
    this.first.disabled = busy || this.page === 1
    this.previous.disabled = busy || this.trail.length < 2
    this.next.disabled = busy || !this.cursor
    this.list.setAttribute("aria-busy", String(busy))
    if (busy) {this.items = []; this.list.replaceChildren(); this.summary.textContent = "Loading values…"}
  }

  async refresh() {
    this.cancelRequest()
    const controller = new AbortController()
    this.request = controller
    this.error.textContent = ""
    this.retry.hidden = true
    this.setBusy(true)
    try {
      const result = await this.load({search: this.search.value.trim(), cursor: this.trail.at(-1), signal: controller.signal})
      if (controller.signal.aborted || this.request !== controller) return
      this.cursor = result.cursor
      this.items = result.items
      this.renderItems()
      this.summary.textContent = result.items.length ? `Page ${this.page} · ${result.items.length} values` :
        result.cursor ? "No matches in this page. Continue with Next to search more values." : "No matching values."
      this.setBusy(false)
    } catch (error) {
      if (controller.signal.aborted || this.request !== controller) return
      this.summary.textContent = "Values unavailable."
      this.error.textContent = error.message
      this.retry.hidden = false
      this.first.disabled = this.page === 1
      this.previous.disabled = this.trail.length < 2
      this.list.setAttribute("aria-busy", "false")
    }
  }

  renderItems() {
    this.list.replaceChildren()
    for (const item of this.items || []) {
      const row = element(this.selected ? "label" : "a", "flex items-center gap-3 border-b border-sr-line px-3 py-2 text-sm last:border-b-0 hover:bg-sr-subtle/70")
      if (this.selected) {
        const check = element("input", "sr-ui-checkbox size-4 shrink-0 accent-sr-brand")
        check.type = "checkbox"
        check.checked = this.selected.has(item.value)
        check.disabled = !check.checked && this.selected.size >= this.maxSelected
        check.setAttribute("aria-label", item.value)
        check.addEventListener("change", () => {
          if (check.checked) this.selected.add(item.value)
          else this.selected.delete(item.value)
          this.renderSelection()
          for (const input of this.list.querySelectorAll("input")) input.disabled = !input.checked && this.selected.size >= this.maxSelected
        })
        row.append(check)
      } else {
        row.href = item.href
        row.setAttribute("data-phx-link", "redirect")
        row.setAttribute("data-phx-link-state", "push")
      }
      row.append(element("span", "min-w-0 flex-1 break-words text-sr-ink", item.value),
        element("span", "shrink-0 rounded border border-sr-line px-2 py-0.5 text-xs text-sr-muted", new Intl.NumberFormat().format(item.count)))
      this.list.append(row)
    }
  }

  renderSelection() {
    this.selection.replaceChildren()
    for (const value of this.selected) {
      const remove = button(`${value} ×`, () => {this.selected.delete(value); this.renderSelection(); this.renderItems()})
      remove.className += " max-w-full break-all text-left"
      remove.setAttribute("aria-label", `Remove ${value}`)
      this.selection.append(remove)
    }
    this.confirm.disabled = this.selected.size === 0 || this.selected.size > this.maxSelected
    this.confirm.textContent = `Use ${this.selected.size} selected value${this.selected.size === 1 ? "" : "s"}`
  }

  destroy() {this.cancelRequest(); this.el.remove()}
}

/** Native dialog uses the same top-layer and sr-ui-modal primitives as ui_modal. */
export class ValuePicker {
  constructor({title, trigger, onClose, ...options}) {
    Object.assign(this, {trigger, onClose})
    this.dialog = element("dialog", "sr-ui-modal sr-ui-modal-open")
    this.dialog.setAttribute("aria-label", title)
    const box = element("div", "sr-ui-modal-box sr-ui-modal-box-form relative border border-sr-line bg-sr-surface text-sr-ink shadow-sr-raised")
    box.append(element("h3", "mb-3 text-lg font-semibold tracking-tight", title))
    this.dialog.append(box)
    this.browser = new ValueBrowser({...options, parent: box, onCancel: () => this.close()})
    this.dialog.addEventListener("cancel", event => {event.preventDefault(); this.close()})
    this.dialog.addEventListener("click", event => {if (event.target === this.dialog) this.close()})
    this.dialog.addEventListener("keydown", event => {trapDialogFocus(this.dialog, event); event.stopPropagation()})
    document.body.append(this.dialog)
    this.dialog.showModal()
    this.browser.search.focus()
  }

  close() {
    if (this.closed) return
    this.closed = true
    this.browser.destroy()
    this.dialog.close()
    this.dialog.remove()
    if (this.trigger?.isConnected) this.trigger.focus()
    this.onClose?.()
  }
}

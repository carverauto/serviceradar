// Promote LiveView-rendered <dialog class="sr-ui-modal"> into the browser
// top layer via showModal(). Ops shell content uses isolation:isolate and the
// sticky sidebar has its own stacking context — CSS z-index alone cannot
// escape those, so flow details (and other dialogs) paint *under* the rail.
//
// Usage:
//   <dialog id="unique" class="sr-ui-modal sr-ui-modal-open"
//           phx-hook="DialogTopLayer" data-cancel="close_event">
//
// data-cancel (optional): LiveView event to push on Escape / outside click.
// data-cancel-target (optional): phx-target for that event.
// data-static-backdrop (optional): "true" disables click-outside dismiss.

export default {
  mounted() {
    // showModal() owns this attribute in the browser. Keep LiveView patches
    // from stripping it and reopening the dialog, which would reset focus.
    this.js().ignoreAttributes(this.el, ["open"])
    this._returnFocus = this._resolveReturnFocus()
    this._onCancel = (e) => this._handleCancel(e)
    this._onClick = (e) => this._handleOutsideClick(e)
    this.el.addEventListener("cancel", this._onCancel)
    this.el.addEventListener("click", this._onClick)
    this._open()
  },

  updated() {
    // LiveView re-render may remount open state without reopening top layer.
    this._open()
  },

  destroyed() {
    this.el.removeEventListener("cancel", this._onCancel)
    this.el.removeEventListener("click", this._onClick)
    try {
      if (this.el.open) this.el.close()
    } catch (_err) {
      // Element may already be detached.
    }
    this._restoreFocus()
  },

  _open() {
    if (typeof this.el.showModal !== "function") {
      this.el.setAttribute("open", "open")
      this._focusAutofocus()
      return
    }
    if (!this.el.open) {
      try {
        this.el.showModal()
      } catch (_err) {
        // Ignore InvalidStateError if already open / not connected.
      }
      // showModal() focuses the first focusable (often the close button). Prefer
      // an explicit autofocus target so search fields are ready to type.
      this._focusAutofocus()
    }
  },

  _focusAutofocus() {
    const target =
      this.el.querySelector("[data-dialog-autofocus]") || this.el.querySelector("[autofocus]")
    if (!target || typeof target.focus !== "function") return

    // Defer so showModal()'s own focus pass finishes first.
    window.requestAnimationFrame(() => {
      try {
        target.focus({preventScroll: true})
      } catch (_err) {
        try {
          target.focus()
        } catch (_err2) {
          // ignore
        }
      }
    })
  },

  _handleOutsideClick(e) {
    // Native showModal() does not light-dismiss on backdrop click. Our dialog
    // is a full-viewport grid; clicks on the dimmed chrome hit the <dialog>
    // itself, while clicks on the panel hit .sr-ui-modal-box descendants.
    if (this.el.dataset.staticBackdrop === "true") return
    if (e.target !== this.el) return
    this._requestClose()
  },

  _handleCancel(e) {
    // Escape (and some browser light-dismiss paths) fire "cancel".
    // Keep the dialog open until LiveView removes it (controlled :if={@open}).
    if (this.el.dataset.cancel) {
      e.preventDefault()
      this._requestClose()
    }
  },

  _requestClose() {
    const eventName = this.el.dataset.cancel
    if (!eventName) {
      try {
        this.el.close()
      } catch (_err) {
        // ignore
      }
      this._restoreFocus()
      return
    }

    const target = this.el.dataset.cancelTarget
    if (target) {
      this.pushEventTo(target, eventName, {})
    } else {
      this.pushEvent(eventName, {})
    }
  },

  _resolveReturnFocus() {
    if (typeof document === "undefined") return null

    const selector = this.el.dataset.returnFocus
    if (selector) {
      try {
        const stableTarget = document.querySelector(selector)
        if (stableTarget) return stableTarget
      } catch (_err) {
        // Invalid selectors fall back to the element focused before opening.
      }
    }

    return document.activeElement
  },

  _restoreFocus() {
    const target = this._returnFocus
    if (!target || typeof target.focus !== "function") return

    try {
      target.focus({preventScroll: true})
    } catch (_err) {
      try {
        target.focus()
      } catch (_err2) {
        // The trigger may have been removed by navigation.
      }
    }
  },
}

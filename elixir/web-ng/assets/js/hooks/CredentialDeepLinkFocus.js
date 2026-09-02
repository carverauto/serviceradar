const CredentialDeepLinkFocus = {
  mounted() {
    this.wasTargeted = false
    this.focusIfTargeted()
  },

  updated() {
    this.focusIfTargeted()
  },

  destroyed() {
    this.cancelPendingFocus()
    this.wasTargeted = false
  },

  focusIfTargeted() {
    if (this.el.dataset.focused !== "true") {
      this.cancelPendingFocus()
      this.wasTargeted = false
      return
    }

    if (this.wasTargeted) return

    this.wasTargeted = true

    this.cancelPendingFocus()
    this.focusFrame = requestAnimationFrame(() => {
      this.focusFrame = null

      if (this.el.dataset.focused !== "true") return

      this.el.scrollIntoView({block: "center", inline: "nearest"})

      try {
        this.el.focus({preventScroll: true})
      } catch (_error) {
        this.el.focus()
      }
    })
  },

  cancelPendingFocus() {
    if (this.focusFrame == null) return

    cancelAnimationFrame(this.focusFrame)
    this.focusFrame = null
  },
}

export default CredentialDeepLinkFocus

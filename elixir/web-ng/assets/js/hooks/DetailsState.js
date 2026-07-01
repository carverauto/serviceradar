// Preserve the open/closed state of a native <details> disclosure across
// LiveView DOM patches.
//
// A <details>'s `open` attribute is toggled by the browser when the user
// clicks its <summary>; the server never renders that attribute. When the
// surrounding form re-renders (e.g. a `phx-change` fired by a nested
// <select>), LiveView's attribute merge sees no `open` in the new markup and
// strips the browser-set attribute, snapping the panel shut. Capture the
// current state right before each patch and restore it right after so the
// operator's expand/collapse choice survives field changes.
export default {
  mounted() {
    this._open = this.el.open
  },
  beforeUpdate() {
    this._open = this.el.open
  },
  updated() {
    if (this.el.open !== this._open) {
      this.el.open = this._open
    }
  },
}

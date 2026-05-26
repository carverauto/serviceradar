import {applySrqlMarkers, createSrqlEditor, ensureSrqlLanguage} from "../lib/srql/monaco_srql.js"

function parseJson(value, fallback) {
  if (!value) return fallback

  try {
    return JSON.parse(value)
  } catch (_error) {
    return fallback
  }
}

export default {
  mounted() {
    this.input = document.getElementById(this.el.dataset.inputId)
    this.error = this.el.dataset.error || null
    this.completions = parseJson(this.el.dataset.completions, [])
    this.compact = this.el.dataset.compact === "true"
    this.disabled = this.el.dataset.disabled === "true"

    createSrqlEditor(this.el, {
      value: this.input?.value || this.el.dataset.value || "",
      completions: this.completions,
      disabled: this.disabled,
      error: this.error,
      compact: this.compact,
    }).then(({monaco, editor}) => {
      this.monaco = monaco
      this.editor = editor
      this.subscription = editor.onDidChangeModelContent(() => this.syncInput(editor.getValue()))
      if (this.compact) {
        editor.addCommand(monaco.KeyCode.Enter, () => this.input?.form?.requestSubmit())
      }
    })
  },

  updated() {
    if (!this.editor || !this.monaco) return

    const completions = parseJson(this.el.dataset.completions, [])
    ensureSrqlLanguage(this.monaco, completions)

    const value = this.input?.value || this.el.dataset.value || ""
    if (this.editor.getValue() !== value) this.editor.setValue(value)

    this.editor.updateOptions({readOnly: this.el.dataset.disabled === "true"})
    applySrqlMarkers(this.monaco, this.editor, this.el.dataset.error || null)
  },

  destroyed() {
    this.subscription?.dispose()
    this.editor?.dispose()
    this.subscription = null
    this.editor = null
    this.monaco = null
  },

  syncInput(value) {
    if (!this.input) return

    this.input.value = value
    this.input.dispatchEvent(new Event("input", {bubbles: true}))
    this.input.dispatchEvent(new Event("change", {bubbles: true}))
  },
}

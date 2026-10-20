/** Keep keyboard focus inside a native modal, including the first/last Tab boundary. */
export function trapDialogFocus(dialog, event) {
  if (event.key !== "Tab" || !dialog.open) return

  const focusable = [...dialog.querySelectorAll(
    "a[href], button, input, select, textarea, [tabindex]"
  )].filter(el => el.tabIndex >= 0 && !el.matches(":disabled") && el.getClientRects().length)
  const first = focusable[0]
  const last = focusable[focusable.length - 1]
  const target = event.shiftKey && document.activeElement === first
    ? last
    : !event.shiftKey && document.activeElement === last ? first : null

  if (target) {
    event.preventDefault()
    target.focus()
  }
}

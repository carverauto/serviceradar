export function renderText(value) {
  if (value === null || value === undefined) {
    return ""
  }

  if (typeof value === "string") {
    return value
  }

  // An object reaching JSX children unmounts the whole console with a
  // minified React error and no message. Coerce so the tree survives and
  // the value stays visible (and warn with the live value for debugging).
  if (typeof window !== "undefined" && typeof window.console?.warn === "function") {
    window.console.warn("renderText: coerced non-string render value", value)
  }

  try {
    const rendered = JSON.stringify(value)

    if (typeof rendered === "string" && rendered !== "") {
      return rendered.slice(0, 500)
    }
  } catch (_stringifyError) {
    // Fall through to String() below.
  }

  return String(value)
}

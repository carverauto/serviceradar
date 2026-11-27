// Theme bootstrap. Load it from <head> as a classic (not module, not async)
// script so it runs before first paint and document.currentScript is set.
// No inline script is required.
//
// Preference is stored in localStorage under "sr:theme" ("light", "dark" or
// "system"). A consumer with a legacy key sets data-sr-theme-key on this
// script tag or on <html>.
(() => {
  const script = document.currentScript
  const root = document.documentElement
  const key =
    (script && script.getAttribute("data-sr-theme-key")) ||
    root.getAttribute("data-sr-theme-key") ||
    "sr:theme"
  const media = window.matchMedia("(prefers-color-scheme: dark)")

  const storageGet = () => {
    try {
      return localStorage.getItem(key)
    } catch (_error) {
      return null
    }
  }

  const storageSet = (value) => {
    try {
      localStorage.setItem(key, value)
    } catch (_error) {
      // Private mode and locked-down storage still get the attribute.
    }
  }

  const known = (value) => value === "light" || value === "dark" || value === "system"

  const apply = (theme, persist) => {
    const preference = known(theme) ? theme : "system"
    const resolved = preference === "system" ? (media.matches ? "dark" : "light") : preference
    if (persist) storageSet(preference)
    root.setAttribute("data-theme-preference", preference)
    root.setAttribute("data-theme", resolved)
  }

  apply(storageGet(), false)

  media.addEventListener("change", () => {
    if (storageGet() === "system" || !known(storageGet())) apply("system", false)
  })

  window.addEventListener("storage", (event) => {
    if (event.key === key) apply(event.newValue, false)
  })

  window.addEventListener("sr:set-theme", (event) => {
    const theme = event.detail && event.detail.theme
    if (known(theme)) apply(theme, true)
  })
})()

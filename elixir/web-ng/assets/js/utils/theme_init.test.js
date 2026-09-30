import {readFileSync} from "node:fs"
import {runInNewContext} from "node:vm"
import {Window} from "happy-dom"
import {describe, expect, it} from "vitest"

const source = readFileSync(new URL("../theme_init.js", import.meta.url), "utf8")

function boot(savedTheme) {
  const window = new Window()
  const {document, localStorage} = window
  if (savedTheme) localStorage.setItem("phx:theme", savedTheme)
  runInNewContext(source, {window, document, localStorage})
  return window
}

describe("theme initialization", () => {
  it("defaults to dark when no preference is saved", () => {
    const {document, localStorage} = boot()
    expect(document.documentElement.getAttribute("data-theme")).toBe("dark")
    expect(localStorage.getItem("phx:theme")).toBe("dark")
  })

  it.each(["light", "dark"])("restores the saved %s preference before first paint", (theme) => {
    const {document, localStorage} = boot(theme)
    expect(document.documentElement.getAttribute("data-theme")).toBe(theme)
    expect(localStorage.getItem("phx:theme")).toBe(theme)
  })

  it("persists light and dark selections across reload", () => {
    const window = boot()
    const button = window.document.createElement("button")
    window.document.body.append(button)

    for (const theme of ["light", "dark"]) {
      button.dataset.phxTheme = theme
      button.dispatchEvent(new window.CustomEvent("phx:set-theme", {bubbles: true}))

      const saved = window.localStorage.getItem("phx:theme")
      expect(saved).toBe(theme)
      expect(window.document.documentElement.getAttribute("data-theme")).toBe(saved)
      expect(boot(saved).document.documentElement.getAttribute("data-theme")).toBe(saved)
    }
  })

  it("synchronizes preferences from another tab and defaults to dark on removal", () => {
    const window = boot("dark")
    for (const theme of ["light", "dark", "light", null]) {
      window.dispatchEvent(new window.StorageEvent("storage", {key: "phx:theme", newValue: theme}))
      expect(window.document.documentElement.getAttribute("data-theme")).toBe(theme || "dark")
      expect(window.localStorage.getItem("phx:theme")).toBe(theme || "dark")
    }
    window.dispatchEvent(new window.StorageEvent("storage", {key: "unrelated", newValue: "light"}))
    expect(window.document.documentElement.getAttribute("data-theme")).toBe("dark")
  })
})

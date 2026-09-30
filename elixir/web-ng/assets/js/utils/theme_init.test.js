import {readFileSync} from "node:fs"
import {runInNewContext} from "node:vm"
import {Window} from "happy-dom"
import {describe, expect, it} from "vitest"

const source = readFileSync(new URL("../theme_init.js", import.meta.url), "utf8")

function boot(savedTheme, colorScheme = "light") {
  const window = new Window({settings: {device: {prefersColorScheme: colorScheme}}})
  const {document, localStorage} = window
  if (savedTheme) localStorage.setItem("phx:theme", savedTheme)
  runInNewContext(source, {window, document, localStorage})
  return window
}

describe("theme initialization", () => {
  it.each(["light", "dark"])("uses the OS %s palette when no preference is saved", (theme) => {
    const {document, localStorage} = boot(undefined, theme)
    expect(document.documentElement.getAttribute("data-theme")).toBe(theme)
    expect(document.documentElement.getAttribute("data-theme-preference")).toBe("system")
    expect(localStorage.getItem("phx:theme")).toBeNull()
  })

  it.each(["light", "dark"])("restores the saved %s preference before first paint", (theme) => {
    const {document, localStorage} = boot(theme, theme === "light" ? "dark" : "light")
    expect(document.documentElement.getAttribute("data-theme")).toBe(theme)
    expect(localStorage.getItem("phx:theme")).toBe(theme)
  })

  it("persists explicit selections across reload and returns to OS selection with System", () => {
    const window = boot()
    const button = window.document.createElement("button")
    window.document.body.append(button)

    for (const theme of ["light", "dark", "system"]) {
      button.dataset.phxTheme = theme
      button.dispatchEvent(new window.CustomEvent("phx:set-theme", {bubbles: true}))

      const saved = window.localStorage.getItem("phx:theme")
      const effective = theme === "system" ? "light" : theme
      expect(saved).toBe(theme === "system" ? null : theme)
      expect(window.document.documentElement.getAttribute("data-theme")).toBe(effective)
      expect(window.document.documentElement.getAttribute("data-theme-preference")).toBe(theme)
      expect(boot(saved).document.documentElement.getAttribute("data-theme")).toBe(effective)
    }
  })

  it("synchronizes preferences from another tab, including returning to System", () => {
    const window = boot("dark")
    for (const theme of ["light", "dark", "light", null]) {
      window.dispatchEvent(new window.StorageEvent("storage", {key: "phx:theme", newValue: theme}))
      expect(window.document.documentElement.getAttribute("data-theme")).toBe(theme || "light")
      expect(window.localStorage.getItem("phx:theme")).toBe(theme)
    }
    window.dispatchEvent(new window.StorageEvent("storage", {key: "unrelated", newValue: "dark"}))
    expect(window.document.documentElement.getAttribute("data-theme")).toBe("light")
  })

  it("tracks OS changes in System mode without overriding an explicit choice", () => {
    const window = boot("system")
    for (const theme of ["dark", "light"]) {
      window.happyDOM.settings.device.prefersColorScheme = theme
      window.dispatchEvent(new window.Event("resize"))
      expect(window.document.documentElement.getAttribute("data-theme")).toBe(theme)
      expect(window.document.documentElement.getAttribute("data-theme-preference")).toBe("system")
      expect(window.localStorage.getItem("phx:theme")).toBeNull()
    }

    const button = window.document.createElement("button")
    window.document.body.append(button)
    button.dataset.phxTheme = "light"
    button.dispatchEvent(new window.CustomEvent("phx:set-theme", {bubbles: true}))
    window.happyDOM.settings.device.prefersColorScheme = "dark"
    window.dispatchEvent(new window.Event("resize"))
    expect(window.document.documentElement.getAttribute("data-theme")).toBe("light")
    expect(window.document.documentElement.getAttribute("data-theme-preference")).toBe("light")
    expect(window.localStorage.getItem("phx:theme")).toBe("light")
  })
})

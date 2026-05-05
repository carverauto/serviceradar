// Browser-side runtime for the HMR dashboard harness. Loaded by the dev shell
// as a Vite module so it benefits from the same module graph as the renderer
// the customer is editing. Exposes:
//   bootstrap({state, renderer})
//     -> {replaceRenderer(nextModule)}
// where `state` is the JSON payload the dev server interpolates into the HTML
// shell (manifest + samples URLs + fixtures map + Mapbox token + theme),
// and `renderer` is the customer's renderer module.

const ROOT_SELECTOR = "[data-root]"
const STATUS_SELECTOR = "[data-status]"
const ERROR_SELECTOR = "[data-error-overlay]"
const ERROR_BODY_SELECTOR = "[data-error-body]"
const CALL_LOG_SELECTOR = "[data-call-log]"
const FIXTURE_SELECT_SELECTOR = "[data-fixture-select]"
const THEME_SELECTOR = "[data-theme-toggle]"
const TOKEN_INPUT_SELECTOR = "[data-mapbox-token]"
const RELOAD_BUTTON_SELECTOR = "[data-reload]"
const SIDEPANEL_TOGGLE_SELECTOR = "[data-sidepanel-toggle]"
const TOKEN_STORAGE_KEY = "sr-dashboard-mapbox-token"
const THEME_STORAGE_KEY = "sr-dashboard-theme"
const SIDEPANEL_STORAGE_KEY = "sr-dashboard-sidepanel-collapsed"

export async function bootstrap({state, renderer}) {
  const ctx = createContext(state)
  await ctx.mount(renderer)
  return ctx
}

function createContext(initialState) {
  const root = document.querySelector(ROOT_SELECTOR)
  if (!root) throw new Error("dev harness root element not found")

  const state = {
    ...initialState,
    activeFixture: initialState.initialFixture || "",
    mapboxToken: initialState.mapboxToken || readTokenFromStorage() || "",
    theme: readThemeFromStorage() ?? "light",
  }

  const themeListeners = new Set()
  const frameListeners = new Set()
  let frames = []
  let mounted = null
  let api = null

  const ctx = {
    async mount(module) {
      try {
        await loadFrames()
      } catch (error) {
        showError(`failed to load sample frames: ${error.message}`)
        return
      }

      try {
        const fn = pickMountFn(module)
        if (typeof fn !== "function") {
          showError("renderer module did not export `mountDashboard`")
          return
        }

        api = await createHostApi(state, frames, {
          themeListeners,
          frameListeners,
          onCall: appendCallLog,
        })

        const host = createHost(state)
        mounted = await fn(root, host, api) || null
        clearError()
        setStatus(`mounted ${state.manifest?.id || "renderer"}`)
      } catch (error) {
        showError(formatError(error))
      }
    },
    async replaceRenderer(nextModule) {
      destroyMounted(mounted)
      mounted = null
      await ctx.mount(nextModule)
    },
    async swapFixture(name) {
      if (!state.fixtures || !state.fixtures[name]) return
      state.activeFixture = name
      try {
        await loadFrames()
      } catch (error) {
        showError(`failed to load fixture "${name}": ${error.message}`)
        return
      }
      // Push the new frames through the existing api callbacks first; if the
      // renderer doesn't subscribe (most do via SDK hooks), remount.
      const broadcast = Array.from(frameListeners)
      if (broadcast.length === 0) {
        const next = await reimportRenderer()
        if (next) await ctx.replaceRenderer(next)
        return
      }
      for (const listener of broadcast) listener({frames})
    },
    setTheme(next) {
      state.theme = next === "dark" ? "dark" : "light"
      writeThemeToStorage(state.theme)
      for (const listener of themeListeners) listener(state.theme)
    },
    setMapboxToken(token) {
      state.mapboxToken = String(token || "")
      writeTokenToStorage(state.mapboxToken)
    },
  }

  wireSidePanel(ctx, state)

  async function loadFrames() {
    const url = state.fixtures?.[state.activeFixture] ?? state.samples?.frames ?? ""
    if (!url) {
      frames = []
      return
    }
    const response = await fetch(url)
    if (!response.ok) throw new Error(`HTTP ${response.status} ${url}`)
    const payload = await response.json()
    frames = Array.isArray(payload) ? payload : Array.isArray(payload?.frames) ? payload.frames : []
  }

  function appendCallLog(line) {
    const node = document.querySelector(CALL_LOG_SELECTOR)
    if (!node) return
    const stamp = new Date().toLocaleTimeString()
    node.textContent = `${stamp}  ${line}`
  }

  function setStatus(text) {
    const node = document.querySelector(STATUS_SELECTOR)
    if (node) node.textContent = text
  }

  function showError(message) {
    const overlay = document.querySelector(ERROR_SELECTOR)
    const body = document.querySelector(ERROR_BODY_SELECTOR)
    if (!overlay || !body) {
      console.error("[dev harness]", message)
      return
    }
    overlay.dataset.visible = "true"
    body.textContent = message
    setStatus("renderer error")
  }

  function clearError() {
    const overlay = document.querySelector(ERROR_SELECTOR)
    if (overlay) overlay.dataset.visible = "false"
  }

  return ctx
}

async function reimportRenderer() {
  // Not every host environment supports re-import; this is a fallback used
  // when fixture swap can't propagate via the host API. Returns null to skip.
  try {
    const meta = document.querySelector("[data-renderer-entry]")
    const entry = meta?.getAttribute("data-renderer-entry")
    if (!entry) return null
    const cacheBuster = `?t=${Date.now()}`
    return await import(/* @vite-ignore */ entry + cacheBuster)
  } catch (error) {
    console.warn("[dev harness] re-import failed", error)
    return null
  }
}

function pickMountFn(module) {
  if (!module) return null
  if (typeof module.mountDashboard === "function") return module.mountDashboard
  if (typeof module.default === "function") return module.default
  return null
}

function destroyMounted(mounted) {
  if (!mounted) return
  try {
    if (typeof mounted === "function") mounted()
    else if (typeof mounted.destroy === "function") mounted.destroy()
  } catch (error) {
    console.warn("[dev harness] destroy threw", error)
  }
}

function createHost(state) {
  return {
    version: "dashboard-browser-module-host-v1",
    package: state.manifest,
    instance: {settings: state.settings || {}},
    settings: state.settings || {},
    mapbox: {
      enabled: Boolean(state.mapboxToken),
      access_token: state.mapboxToken,
    },
  }
}

async function createHostApi(state, initialFrames, hooks) {
  const {themeListeners, frameListeners, onCall} = hooks
  let frames = initialFrames
  const libraries = await loadBrowserModuleLibraries()

  return {
    version: "dashboard-browser-module-host-v1",
    capabilityAllowed: () => true,
    requireCapability: () => {},
    theme: () => state.theme,
    isDarkMode: () => state.theme === "dark",
    frames: () => frames,
    frame: (id) => frames.find((entry) => String(entry?.id) === String(id)),
    srql: createSrqlClient(() => frames, onCall),
    setSrqlQuery(query, frameQueries = {}) {
      onCall(`srql.update ${query}`)
      console.info("[dev harness] SRQL update", {query, frameQueries})
    },
    navigate(target) {
      onCall(`navigate ${typeof target === "string" ? target : JSON.stringify(target)}`)
      console.info("[dev harness] navigate", target)
    },
    openDevice(uid) {
      onCall(`open device ${uid}`)
      console.info("[dev harness] openDevice", uid)
    },
    arrow: {
      frameBytes() { return new Uint8Array() },
      table() { return Promise.reject(new Error("Arrow decoding is provided by the production host")) },
    },
    mapbox: () => ({
      enabled: Boolean(state.mapboxToken),
      access_token: state.mapboxToken,
      style_dark: state.settings?.mapbox?.style_dark || state.settings?.mapbox_style_dark,
      style_light: state.settings?.mapbox?.style_light || state.settings?.mapbox_style_light,
    }),
    libraries,
    onThemeChange(callback) {
      themeListeners.add(callback)
      return () => themeListeners.delete(callback)
    },
    onFrameUpdate(callback) {
      frameListeners.add(callback)
      return () => frameListeners.delete(callback)
    },
    popup: {
      open(content) {
        onCall("popup open")
        console.info("[dev harness] popup", content)
        return {close: () => onCall("popup close")}
      },
      close() { onCall("popup close") },
    },
    details: {
      open(target) {
        onCall(`details ${typeof target === "string" ? target : JSON.stringify(target)}`)
      },
    },
  }
}

function createSrqlClient(getFrames, onCall) {
  const queryFor = (id) => {
    const frame = getFrames().find((entry) => String(entry?.id) === String(id || ""))
    return frame?.query || getFrames()[0]?.query || ""
  }
  const update = (query, frameQueries = {}) => {
    onCall(`srql.update ${query}`)
    console.info("[dev harness] srql.update", {query, frameQueries})
  }
  return Object.assign(() => ({query: queryFor()}), {
    query: queryFor,
    update,
    updateQuery: update,
    setQuery: update,
    escapeValue: (value) => String(value ?? "").trim().replace(/\s+/g, "\\ "),
    list: (values) => `(${Array.from(values || []).map((value) => String(value || "").trim()).join(",")})`,
    build: (options = {}) => `in:${options.entity || "devices"} limit:${options.limit || 100}`,
  })
}

async function loadBrowserModuleLibraries() {
  await import("mapbox-gl/dist/mapbox-gl.css")

  const [mapboxModule, deckLayers, deckMapbox] = await Promise.all([
    import("mapbox-gl"),
    import("@deck.gl/layers"),
    import("@deck.gl/mapbox"),
  ])

  return {
    mapboxgl: mapboxModule.default || mapboxModule,
    MapboxOverlay: deckMapbox.MapboxOverlay,
    ScatterplotLayer: deckLayers.ScatterplotLayer,
    TextLayer: deckLayers.TextLayer,
  }
}

function wireSidePanel(ctx, state) {
  const fixtureSelect = document.querySelector(FIXTURE_SELECT_SELECTOR)
  if (fixtureSelect) {
    const names = Object.keys(state.fixtures || {})
    if (names.length === 0) {
      fixtureSelect.disabled = true
    } else {
      for (const name of names) {
        const option = document.createElement("option")
        option.value = name
        option.textContent = name
        if (name === state.activeFixture) option.selected = true
        fixtureSelect.appendChild(option)
      }
      fixtureSelect.addEventListener("change", () => ctx.swapFixture(fixtureSelect.value))
    }
  }

  const themeButton = document.querySelector(THEME_SELECTOR)
  if (themeButton) {
    themeButton.addEventListener("click", () => {
      ctx.setTheme(state.theme === "dark" ? "light" : "dark")
      themeButton.textContent = state.theme === "dark" ? "☀ Light" : "☾ Dark"
    })
    themeButton.textContent = state.theme === "dark" ? "☀ Light" : "☾ Dark"
  }

  const tokenInput = document.querySelector(TOKEN_INPUT_SELECTOR)
  if (tokenInput) {
    tokenInput.value = state.mapboxToken
    tokenInput.addEventListener("change", () => ctx.setMapboxToken(tokenInput.value))
  }

  const reloadButton = document.querySelector(RELOAD_BUTTON_SELECTOR)
  if (reloadButton) {
    reloadButton.addEventListener("click", () => window.location.reload())
  }

  const app = document.getElementById("sr-app")
  const sidePanelButtons = Array.from(document.querySelectorAll(SIDEPANEL_TOGGLE_SELECTOR))
  if (app && sidePanelButtons.length > 0) {
    let collapsed = readSidePanelCollapsed()
    applySidePanelState(app, sidePanelButtons, collapsed)
    for (const button of sidePanelButtons) {
      button.addEventListener("click", () => {
        collapsed = !collapsed
        writeSidePanelCollapsed(collapsed)
        applySidePanelState(app, sidePanelButtons, collapsed)
      })
    }
  }
}

function readTokenFromStorage() {
  try { return window.localStorage?.getItem(TOKEN_STORAGE_KEY) } catch (_) { return null }
}

function writeTokenToStorage(value) {
  try { window.localStorage?.setItem(TOKEN_STORAGE_KEY, value) } catch (_) { /* noop */ }
}

function readThemeFromStorage() {
  try { return window.localStorage?.getItem(THEME_STORAGE_KEY) } catch (_) { return null }
}

function writeThemeToStorage(value) {
  try { window.localStorage?.setItem(THEME_STORAGE_KEY, value) } catch (_) { /* noop */ }
}

function readSidePanelCollapsed() {
  try { return window.localStorage?.getItem(SIDEPANEL_STORAGE_KEY) === "true" } catch (_) { return false }
}

function writeSidePanelCollapsed(value) {
  try { window.localStorage?.setItem(SIDEPANEL_STORAGE_KEY, value ? "true" : "false") } catch (_) { /* noop */ }
}

function applySidePanelState(app, buttons, collapsed) {
  app.dataset.sidepanelCollapsed = collapsed ? "true" : "false"
  for (const button of buttons) {
    button.textContent = collapsed ? "Tools" : "Hide"
    button.setAttribute("aria-expanded", collapsed ? "false" : "true")
  }
  requestAnimationFrame(() => {
    window.dispatchEvent(new Event("resize"))
    requestAnimationFrame(() => window.dispatchEvent(new Event("resize")))
  })
}

function formatError(error) {
  if (!error) return "unknown error"
  return error.stack || error.message || String(error)
}

import {beforeEach, describe, expect, test, vi} from "vitest"

import DashboardWasmHost from "./DashboardWasmHost"

function baseHost(overrides = {}) {
  return {
    instance: {
      settings: {},
    },
    package: {
      name: "Test Dashboard",
      capabilities: [],
      renderer: {
        kind: "browser_module",
        interface_version: "dashboard-browser-module-v1",
        trust: "trusted",
      },
      frames: [
        {
          id: "sites",
          query: "in:wifi_sites limit:500",
          status: "ok",
          results: [{site_code: "DEN"}],
        },
      ],
    },
    ...overrides,
  }
}

function hookContext(overrides = {}) {
  const children = []

  return {
    ...DashboardWasmHost,
    el: {
      dataset: {},
      innerHTML: "<div>loading</div>",
      classList: {add: vi.fn()},
      appendChild: vi.fn((node) => children.push(node)),
    },
    _children: children,
    _frameUpdateCallbacks: [],
    connectFrameStream: vi.fn(),
    updateVisibleSrqlQuery: vi.fn(),
    pushEvent: vi.fn(),
    isDarkMode: vi.fn(() => false),
    ...overrides,
  }
}

describe("DashboardWasmHost browser-module API", () => {
  beforeEach(() => {
    vi.restoreAllMocks()

    globalThis.window = {
      location: {
        href: "https://example.test/dashboards/ual-network-map",
        assign: vi.fn(),
      },
    }
    globalThis.document = {
      createElement: vi.fn(() => ({
        className: "",
        innerHTML: "",
        style: {},
        textContent: "",
        setAttribute: vi.fn(),
        appendChild: vi.fn(),
        remove: vi.fn(),
      })),
    }
  })

  test("pushes SRQL updates for the primary query and frame-specific queries", () => {
    const hook = hookContext()
    const api = hook.browserModuleApi(baseHost())

    api.srql.update("in:wifi_sites site_code:(DEN) limit:500", {
      devices: "in:wifi_devices site_code:(DEN) limit:1000",
      empty: "",
    })

    expect(hook.updateVisibleSrqlQuery).toHaveBeenCalledWith("in:wifi_sites site_code:(DEN) limit:500")
    expect(hook.pushEvent).toHaveBeenCalledWith("dashboard_srql_query", {
      q: "in:wifi_sites site_code:(DEN) limit:500",
      frame_devices: "in:wifi_devices site_code:(DEN) limit:1000",
    })
  })

  test("builds SRQL query strings with escaped values for renderer-owned filters", () => {
    const hook = hookContext()
    const api = hook.browserModuleApi(baseHost())

    expect(
      api.srql.build({
        entity: "wifi_sites",
        searchField: "site_name",
        search: "Denver International",
        include: {site_code: ["DEN", "IAH"]},
        exclude: {status: ["down"]},
        where: ["latitude:>=20"],
        limit: 500,
      }),
    ).toEqual("in:wifi_sites site_name:%Denver\\ International% site_code:(DEN,IAH) !status:(down) latitude:>=20 limit:500")
  })

  test("enforces navigation capabilities before opening ServiceRadar routes", () => {
    const hook = hookContext()
    const denied = hook.browserModuleApi(baseHost())

    expect(() => denied.openDevice("sr:sample den 1")).toThrow("dashboard capability is not approved: navigation.open")

    const allowed = hook.browserModuleApi(
      baseHost({
        package: {
          ...baseHost().package,
          capabilities: ["navigation.open"],
        },
      }),
    )

    allowed.openDevice("sr:sample den 1")

    expect(window.location.assign).toHaveBeenCalledWith("/devices/sr%3Asample%20den%201")
  })

  test("exposes Arrow IPC frame bytes and rejects JSON frames as Arrow", () => {
    const hook = hookContext()
    const api = hook.browserModuleApi(
      baseHost({
        package: {
          ...baseHost().package,
          frames: [
            {
              id: "arrow-sites",
              encoding: "arrow_ipc",
              payload_base64: Buffer.from([1, 2, 3, 4]).toString("base64"),
            },
            {
              id: "json-sites",
              encoding: "json",
              results: [],
            },
          ],
        },
      }),
    )

    expect(Array.from(api.arrow.frameBytes("arrow-sites"))).toEqual([1, 2, 3, 4])
    expect(() => api.arrow.frameBytes("json-sites")).toThrow("not arrow_ipc")
  })

  test("enforces preferences and saved query capabilities", () => {
    const hook = hookContext()
    const denied = hook.browserModuleApi(baseHost())

    expect(() => denied.preferences.set("density", "compact")).toThrow("dashboard capability is not approved: dashboard.preferences.write")
    expect(() => denied.savedQueries.list()).toThrow("dashboard capability is not approved: saved_queries.read")

    const host = baseHost({
      instance: {
        settings: {
          preferences: {density: "comfortable"},
          saved_queries: [{id: "den", name: "DEN", query: "in:wifi_sites site_code:(DEN) limit:500"}],
        },
      },
      package: {
        ...baseHost().package,
        capabilities: ["dashboard.preferences.write", "saved_queries.read"],
      },
    })
    const api = hook.browserModuleApi(host)

    expect(api.preferences.get("density")).toEqual("comfortable")
    expect(api.savedQueries.list()).toEqual([{id: "den", name: "DEN", query: "in:wifi_sites site_code:(DEN) limit:500"}])
    expect(api.preferences.set("density", "compact")).toEqual({density: "compact"})
    expect(hook.pushEvent).toHaveBeenCalledWith("dashboard_preference_update", {key: "density", value: "compact"})
  })

  test("enforces popup and detail host actions", () => {
    const hook = hookContext()
    const denied = hook.browserModuleApi(baseHost())

    expect(() => denied.popup.open({title: "Denied"})).toThrow("dashboard capability is not approved: popup.open")
    expect(() => denied.details.open({type: "site", site_code: "DEN"})).toThrow("dashboard capability is not approved: details.open")

    const allowed = hook.browserModuleApi(
      baseHost({
        package: {
          ...baseHost().package,
          capabilities: ["popup.open", "details.open"],
        },
      }),
    )

    const popup = allowed.popup.open({title: "DEN", fields: [{label: "APs", value: 42}]}, {x: 24, y: 36})
    allowed.details.open({type: "site", site_code: "DEN"})

    expect(hook.el.appendChild).toHaveBeenCalled()
    expect(hook._children[0].innerHTML).toContain("DEN")
    expect(hook._children[0].style.left).toEqual("24px")
    expect(hook._children[0].style.top).toEqual("36px")
    expect(hook.pushEvent).toHaveBeenCalledWith("dashboard_detail_request", {type: "site", site_code: "DEN"})

    popup.close()
    expect(hook._children[0].remove).toHaveBeenCalled()
  })
})

describe("DashboardWasmHost browser-module boot validation", () => {
  test("rejects unsupported browser-module interface versions", () => {
    const hook = hookContext()

    expect(() =>
      hook.validateInterfaceVersion(
        baseHost({
          package: {
            ...baseHost().package,
            renderer: {
              ...baseHost().package.renderer,
              interface_version: "dashboard-browser-module-v0",
            },
          },
        }),
      ),
    ).toThrow("unsupported dashboard browser module interface")
  })

  test("rejects untrusted browser-module renderers before importing them", async () => {
    const hook = hookContext()

    await expect(
      hook.bootBrowserModule(
        baseHost({
          package: {
            ...baseHost().package,
            renderer_url: "data:text/javascript,export function mountDashboard() {}",
            renderer: {
              ...baseHost().package.renderer,
              trust: "sandboxed",
            },
          },
        }),
      ),
    ).rejects.toThrow("dashboard browser module renderer must declare trust: trusted")
  })

  test("mounts trusted browser modules with the bounded host API", async () => {
    const hook = hookContext()
    const rendererUrl =
      "data:text/javascript,export function mountDashboard(el, host, api) { el.dataset.mounted = api.version; return { destroy() { el.dataset.destroyed = 'true' } } }"

    await hook.bootBrowserModule(
      baseHost({
        package: {
          ...baseHost().package,
          renderer_url: rendererUrl,
        },
      }),
    )

    expect(hook.el.innerHTML).toEqual("")
    expect(hook.el.classList.add).toHaveBeenCalledWith("sr-dashboard-browser-module")
    expect(hook.el.dataset.mounted).toEqual("dashboard-browser-module-host-v1")
    expect(typeof hook._moduleDestroy).toEqual("function")
    expect(hook.connectFrameStream).toHaveBeenCalled()
  })
})

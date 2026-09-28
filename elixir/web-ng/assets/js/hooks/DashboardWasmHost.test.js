import {afterEach, beforeEach, describe, expect, test, vi} from "vitest"

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
          results: [{site_code: "ZZC"}],
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
    pushEvent: vi.fn(),
    isDarkMode: vi.fn(() => false),
    ...overrides,
  }
}

beforeEach(() => {
  vi.restoreAllMocks()

  globalThis.window = {
    location: {
      href: "https://example.test/dashboards/wifi-network-map",
      assign: vi.fn(),
    },
    history: {
      state: {},
      replaceState: vi.fn((_state, _title, url) => {
        globalThis.window.location.href = url.toString()
      }),
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

afterEach(() => {
  vi.useRealTimers()
})

describe("DashboardWasmHost browser-module API", () => {
  test("pushes SRQL updates for the primary query and frame-specific queries", () => {
    const hook = hookContext()
    const api = hook.browserModuleApi(baseHost())

    api.srql.update("in:wifi_sites site_code:(ZZC) limit:500", {
      devices: "in:wifi_devices site_code:(ZZC) limit:1000",
      empty: "",
    })

    expect(window.history.replaceState).toHaveBeenCalledWith(
      window.history.state,
      "",
      new URL("https://example.test/dashboards/wifi-network-map?q=in%3Awifi_sites+site_code%3A%28ZZC%29+limit%3A500&frame_devices=in%3Awifi_devices+site_code%3A%28ZZC%29+limit%3A1000"),
    )
    expect(hook.pushEvent).toHaveBeenCalledWith("dashboard_srql_query", {
      q: "in:wifi_sites site_code:(ZZC) limit:500",
      frame_devices: "in:wifi_devices site_code:(ZZC) limit:1000",
    })
  })

  test("pages a frame through the live stream without rewriting the query URL", () => {
    const push = vi.fn()
    const hook = hookContext({_frameChannel: {push}})
    const api = hook.browserModuleApi(
      baseHost({
        package: {
          name: "Test Dashboard",
          capabilities: ["srql.execute"],
          renderer: {
            kind: "browser_module",
            interface_version: "dashboard-browser-module-v1",
            trust: "trusted",
          },
          frames: [{id: "results", query: "in:composite_results limit:200", status: "ok", results: []}],
        },
      }),
    )

    api.srql.page("results", "next-token")

    expect(push).toHaveBeenCalledWith("frames:page", {frame_id: "results", cursor: "next-token"})
    expect(hook.pushEvent).not.toHaveBeenCalled()
    expect(window.history.replaceState).not.toHaveBeenCalled()
  })

  test("rejects a frame page without srql.execute, a cursor, or a live stream", () => {
    const hook = hookContext()
    const denied = hook.browserModuleApi(baseHost())

    expect(() => denied.srql.page("results", "next-token")).toThrow(
      "dashboard capability is not approved: srql.execute",
    )

    const allowed = hook.browserModuleApi(
      baseHost({
        package: {
          name: "Test Dashboard",
          capabilities: ["srql.execute"],
          renderer: {
            kind: "browser_module",
            interface_version: "dashboard-browser-module-v1",
            trust: "trusted",
          },
          frames: [{id: "results", query: "in:composite_results limit:200", status: "ok", results: []}],
        },
      }),
    )

    expect(() => allowed.srql.page("results", "")).toThrow("dashboard frame page requires frame id and cursor")
    expect(() => allowed.srql.page("results", "next-token")).toThrow("dashboard frame stream is not connected")
  })

  test("builds SRQL query strings with escaped values for renderer-owned filters", () => {
    const hook = hookContext()
    const api = hook.browserModuleApi(baseHost())

    expect(
      api.srql.build({
        entity: "wifi_sites",
        searchField: "site_name",
        search: "Example International",
        include: {site_code: ["ZZC", "ZZA"]},
        exclude: {status: ["down"]},
        where: ["latitude:>=20"],
        limit: 500,
      }),
    ).toEqual("in:wifi_sites site_name:%Example\\ International% site_code:(ZZC,ZZA) !status:(down) latitude:>=20 limit:500")
  })

  test("enforces navigation capabilities before opening ServiceRadar routes", () => {
    const hook = hookContext()
    const denied = hook.browserModuleApi(baseHost())

    expect(() => denied.openDevice("sr:sample zzc 1")).toThrow("dashboard capability is not approved: navigation.open")

    const allowed = hook.browserModuleApi(
      baseHost({
        package: {
          ...baseHost().package,
          capabilities: ["navigation.open"],
        },
      }),
    )

    allowed.openDevice("sr:sample zzc 1")

    expect(window.location.assign).toHaveBeenCalledWith("/devices/sr%3Asample%20zzc%201")
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
          saved_queries: [{id: "zzc", name: "ZZC", query: "in:wifi_sites site_code:(ZZC) limit:500"}],
        },
      },
      package: {
        ...baseHost().package,
        capabilities: ["dashboard.preferences.write", "saved_queries.read"],
      },
    })
    const api = hook.browserModuleApi(host)

    expect(api.preferences.get("density")).toEqual("comfortable")
    expect(api.savedQueries.list()).toEqual([{id: "zzc", name: "ZZC", query: "in:wifi_sites site_code:(ZZC) limit:500"}])
    expect(api.preferences.set("density", "compact")).toEqual({density: "compact"})
    expect(hook.pushEvent).toHaveBeenCalledWith("dashboard_preference_update", {key: "density", value: "compact"})
  })

  test("gates the camera API on the package capability and the viewer's permission", () => {
    const hook = hookContext()
    const withoutCapability = hook.browserModuleApi(baseHost({permissions: {camera_stream_view: true}}))
    const request = {
      camera_source_id: "11111111-1111-4111-8111-111111111111",
      stream_profile_id: "22222222-2222-4222-8222-222222222222",
    }

    expect(() => withoutCapability.camera.open(request)).toThrow(
      expect.objectContaining({code: "capability_denied"})
    )

    const withoutPermission = hook.browserModuleApi(
      baseHost({package: {...baseHost().package, capabilities: ["camera.stream.view"]}})
    )

    expect(withoutPermission.camera.allowed()).toBe(false)
    expect(() => withoutPermission.camera.open(request)).toThrow(expect.objectContaining({code: "permission_denied"}))

    const allowed = hook.browserModuleApi(
      baseHost({
        package: {...baseHost().package, capabilities: ["camera.stream.view"]},
        permissions: {camera_stream_view: true},
      })
    )

    expect(allowed.camera.allowed()).toBe(true)
    expect(allowed.camera.maxSessions).toBe(9)
  })

  test("gates the action and event APIs and routes channel pushes to them", async () => {
    const pushes = []
    const channel = {
      push: vi.fn((event, payload) => {
        pushes.push({event, payload})
        const reply = event === "actions:invoke" ? {invocation_id: "inv-1", state: "dispatching"} : {}
        const push = {receive: (kind, callback) => (kind === "ok" && callback(reply), push)}
        return push
      }),
    }
    const hook = hookContext({_frameChannel: channel})

    const denied = hook.browserModuleApi(baseHost({permissions: {actions_invoke: true, events_subscribe: true}}))
    expect(denied.actions.allowed()).toBe(false)
    expect(() => denied.events.subscribe({}, vi.fn())).toThrow(expect.objectContaining({code: "capability_denied"}))

    const api = hook.browserModuleApi(
      baseHost({
        package: {...baseHost().package, capabilities: ["srql.execute", "actions.invoke", "events.subscribe"]},
        permissions: {actions_invoke: true, events_subscribe: true},
      })
    )

    const onEvents = vi.fn()
    api.events.subscribe({log_provider: "plugin:demo"}, onEvents)
    hook._eventsApi.handleBatch({subscription_id: "sub-1", events: [{id: "e1"}]})
    expect(onEvents).toHaveBeenCalledWith([{id: "e1"}])

    const result = api.actions.invoke({actionId: "northbound:1", targets: [{deviceUid: "d1"}]})
    await Promise.resolve()
    hook._actionsApi.handleProgress({invocation_id: "inv-1", state: "succeeded"})
    await expect(result).resolves.toMatchObject({state: "succeeded"})

    await expect(api.refreshFrames()).resolves.toEqual({refreshed: true})
    expect(pushes.map((push) => push.event)).toEqual(["events:subscribe", "actions:invoke", "frames:refresh"])
  })

  test("closes camera sessions when the dashboard is destroyed", () => {
    globalThis.fetch = vi.fn(() => new Promise(() => {}))
    globalThis.document.addEventListener = vi.fn()
    globalThis.document.removeEventListener = vi.fn()
    globalThis.window.removeEventListener = vi.fn()
    const hook = hookContext({disconnectFrameStream: vi.fn(), teardownMap: vi.fn()})
    const api = hook.browserModuleApi(
      baseHost({
        package: {...baseHost().package, capabilities: ["camera.stream.view"]},
        permissions: {camera_stream_view: true},
      })
    )

    const handle = api.camera.open({
      camera_source_id: "11111111-1111-4111-8111-111111111111",
      stream_profile_id: "22222222-2222-4222-8222-222222222222",
    })
    expect(api.camera.activeCount()).toBe(1)

    hook.destroyed()

    expect(handle.state).toBe("closed")
    expect(api.camera.activeCount()).toBe(0)
    delete globalThis.fetch
  })

  test("enforces popup and detail host actions", () => {
    const hook = hookContext()
    const denied = hook.browserModuleApi(baseHost())

    expect(() => denied.popup.open({title: "Denied"})).toThrow("dashboard capability is not approved: popup.open")
    expect(() => denied.details.open({type: "site", site_code: "ZZC"})).toThrow("dashboard capability is not approved: details.open")

    const allowed = hook.browserModuleApi(
      baseHost({
        package: {
          ...baseHost().package,
          capabilities: ["popup.open", "details.open"],
        },
      }),
    )

    const popup = allowed.popup.open({title: "ZZC", fields: [{label: "APs", value: 42}]}, {x: 24, y: 36})
    allowed.details.open({type: "site", site_code: "ZZC"})

    expect(hook.el.appendChild).toHaveBeenCalled()
    expect(hook._children[0].innerHTML).toContain("ZZC")
    expect(hook._children[0].style.left).toEqual("24px")
    expect(hook._children[0].style.top).toEqual("36px")
    expect(hook.pushEvent).toHaveBeenCalledWith("dashboard_detail_request", {type: "site", site_code: "ZZC"})

    popup.close()
    expect(hook._children[0].remove).toHaveBeenCalled()
  })

  test("filters non-mappable rows before creating map layer data", () => {
    const hook = hookContext({
      _host: {
        package: {
          frames: [
            {
              id: "sites",
              results: [
                {site_code: "ZZC", longitude: -21.0000, latitude: 11.0000},
                {site_code: "NO_LAT", longitude: -21.0000},
                {site_code: "BAD_LNG", longitude: 230, latitude: 11.0000},
              ],
            },
            {
              id: "links",
              results: [
                {id: "valid", source_lng: -21.0000, source_lat: 11.0000, target_lng: -20.0000, target_lat: 10.0000},
                {id: "bad_target", source_lng: -21.0000, source_lat: 11.0000, target_lng: -20.0000},
              ],
            },
          ],
        },
      },
    })

    expect(
      hook.layerData({
        type: "scatterplot",
        data_frame: "sites",
        position: ["longitude", "latitude"],
      }),
    ).toEqual([{site_code: "ZZC", longitude: -21.0000, latitude: 11.0000}])

    expect(
      hook.layerData({
        type: "line",
        data_frame: "links",
        source_position: ["source_lng", "source_lat"],
        target_position: ["target_lng", "target_lat"],
      }),
    ).toEqual([{id: "valid", source_lng: -21.0000, source_lat: 11.0000, target_lng: -20.0000, target_lat: 10.0000}])
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

  // These two are the only tests here that actually dynamic-import() a data: URL renderer and
  // await the mount, so they pay for compiling that module. Vitest's 5s default is ample once
  // the module graph is warm (~230ms and ~101ms), but on a COLD cache -- which is every CI run,
  // right after `bun install` -- transforming 57 test files concurrently pushed both past 5s and
  // they failed as "Test timed out in 5000ms". Neither asserts anything about wall-clock speed:
  // one asserts the error state renders, the other that a 100ms renderer timeout fires. Give
  // them room so a cold cache is not a red build.
  const COLD_IMPORT_TIMEOUT_MS = 30_000

  test("renders a native error state when a browser module crashes during mount", async () => {
    const hook = hookContext()
    const rendererUrl = "data:text/javascript,export function mountDashboard() { throw new Error('renderer boom') }"

    hook.el.dataset.host = JSON.stringify(
      baseHost({
        package: {
          ...baseHost().package,
          renderer_url: rendererUrl,
        },
      }),
    )

    await hook.boot()

    expect(hook.el.innerHTML).toContain("Dashboard renderer failed")
    expect(hook.el.innerHTML).toContain("renderer boom")
  }, COLD_IMPORT_TIMEOUT_MS)

  test("times out slow browser module renderers", async () => {
    const hook = hookContext()
    const rendererUrl = "data:text/javascript,export function mountDashboard() { return new Promise(() => {}) }"

    const boot = hook.bootBrowserModule(
      baseHost({
        package: {
          ...baseHost().package,
          renderer_url: rendererUrl,
          renderer: {
            ...baseHost().package.renderer,
            timeout_ms: 100,
          },
        },
      }),
    )

    await expect(boot).rejects.toThrow("dashboard renderer timed out after 100ms")
    expect(hook.connectFrameStream).not.toHaveBeenCalled()
  }, COLD_IMPORT_TIMEOUT_MS)

  test("reconnects the frame stream when a browser module host update changes the stream token", () => {
    const rendererUrl = "data:text/javascript,export function mountDashboard() {}"
    const frames = [
      {
        id: "sites",
        query: "in:wifi_sites limit:500",
        status: "ok",
        results: [{site_code: "ZZC"}],
      },
    ]
    const hook = hookContext({disconnectFrameStream: vi.fn()})
    hook._host = baseHost({
      data_provider: {
        stream_topic: "dashboards:wifi-network-map",
        stream_token: "required-only",
        refresh_interval_ms: 15_000,
      },
      package: {
        ...baseHost().package,
        renderer_url: rendererUrl,
        frames,
      },
    })

    const nextHost = baseHost({
      data_provider: {
        stream_topic: "dashboards:wifi-network-map",
        stream_token: "devices-active",
        refresh_interval_ms: 15_000,
      },
      package: {
        ...baseHost().package,
        renderer_url: rendererUrl,
        frames: [
          frames[0],
          {
            id: "devices",
            query: "in:wifi_aps site_code:(ZZC) limit:20000",
            status: "ok",
            results: [{site_code: "ZZC", name: "ZZC-AP-001"}],
          },
        ],
      },
    })

    expect(hook.updateBrowserModuleHost(nextHost, "host-payload-v2")).toEqual(true)
    expect(hook.disconnectFrameStream).toHaveBeenCalledTimes(1)
    expect(hook.connectFrameStream).toHaveBeenCalledWith(hook._host)
    expect(hook._host.package.frames.map((frame) => frame.id)).toEqual(["sites", "devices"])
  })

  test("mounts trusted browser modules with the bounded host API", async () => {
    const hook = hookContext()
    const rendererUrl = new URL("./__fixtures__/trusted_dashboard_module.js", import.meta.url).href

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

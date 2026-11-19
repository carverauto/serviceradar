import {afterEach, beforeEach, describe, expect, test, vi} from "vitest"
import React, {useEffect} from "react"
import {Card} from "@blueprintjs/core"
import {Window} from "happy-dom"
import {mountBlueprintDashboard} from "@carverauto/serviceradar-dashboard-sdk/blueprint"

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

  test("a partial refresh keeps previous arrow bytes for frames it did not re-query", () => {
    const previous = new Uint8Array([1, 2, 3])
    const hook = hookContext()
    hook._host = baseHost({
      package: {
        ...baseHost().package,
        frames: [
          {
            id: "slow-arrow",
            encoding: "arrow_ipc",
            payload_transport: "channel_binary",
            payload: previous,
            payload_encoding: "arraybuffer",
          },
          {id: "fast-rows", encoding: "json_rows", results: [{id: "row-1"}]},
        ],
      },
    })

    const notified = []
    hook._frameUpdateCallbacks.push((update) => notified.push(update))

    // The server re-queried only fast-rows: slow-arrow arrives metadata-only
    // with no pending binary, so its previous bytes stay in place.
    hook.replaceFramePayload({
      frames: [
        {id: "slow-arrow", encoding: "arrow_ipc", payload_transport: "channel_binary"},
        {id: "fast-rows", encoding: "json_rows", results: [{id: "row-2"}]},
      ],
      pending_binary_frame_ids: [],
    })

    const frames = hook._host.package.frames
    expect(frames.find((frame) => frame.id === "slow-arrow").payload).toBe(previous)
    expect(frames.find((frame) => frame.id === "fast-rows").results).toEqual([{id: "row-2"}])
    expect(notified).toHaveLength(1)
  })

  test("an arrow frame with a pending binary waits for its bytes", () => {
    const previous = new Uint8Array([1, 2, 3])
    const hook = hookContext()
    hook._host = baseHost({
      package: {
        ...baseHost().package,
        frames: [
          {
            id: "slow-arrow",
            encoding: "arrow_ipc",
            payload_transport: "channel_binary",
            payload: previous,
            payload_encoding: "arraybuffer",
          },
        ],
      },
    })

    const notified = []
    hook._frameUpdateCallbacks.push((update) => notified.push(update))

    hook.replaceFramePayload({
      frames: [{id: "slow-arrow", encoding: "arrow_ipc", payload_transport: "channel_binary"}],
      pending_binary_frame_ids: ["slow-arrow"],
    })

    expect(hook._host.package.frames.find((frame) => frame.id === "slow-arrow").payload).toBeUndefined()
    expect(notified).toHaveLength(0)
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

  test("a superseded boot's mount failure leaves the newer boot's host state intact", async () => {
    const hook = hookContext()
    hook._bootGen = 1
    let rejectStaleMount
    const staleMount = vi.fn(
      () =>
        new Promise((_resolve, reject) => {
          rejectStaleMount = reject
        }),
    )

    const staleBoot = hook.mountExternalRenderer(baseHost(), 1, {}, staleMount)
    await vi.waitFor(() => expect(staleMount).toHaveBeenCalled())

    hook._bootGen = 2
    const liveCallback = vi.fn()
    const liveEvents = {clear: vi.fn()}
    const liveActions = {}
    hook._frameUpdateCallbacks = [liveCallback]
    hook._eventsApi = liveEvents
    hook._actionsApi = liveActions
    const liveCamera = {closeAll: vi.fn()}
    hook._cameraApi = liveCamera

    rejectStaleMount(new Error("stale mount failed"))
    await expect(staleBoot).rejects.toThrow("stale mount failed")

    expect(hook._frameUpdateCallbacks).toEqual([liveCallback])
    expect(hook._eventsApi).toBe(liveEvents)
    expect(liveEvents.clear).not.toHaveBeenCalled()
    expect(hook._actionsApi).toBe(liveActions)
    expect(hook._cameraApi).toBe(liveCamera)
    expect(liveCamera.closeAll).not.toHaveBeenCalled()
  })

  test("a current boot's mount failure clears the host state it registered", async () => {
    const hook = hookContext()
    hook._bootGen = 1
    const events = {clear: vi.fn()}
    hook._frameUpdateCallbacks = [vi.fn()]
    hook._eventsApi = events
    hook._actionsApi = {}

    await expect(
      hook.mountExternalRenderer(baseHost(), 1, {}, () => {
        throw new Error("mount failed")
      }),
    ).rejects.toThrow("mount failed")

    expect(hook._frameUpdateCallbacks).toEqual([])
    expect(hook._eventsApi).toBeNull()
    expect(events.clear).toHaveBeenCalled()
    expect(hook._actionsApi).toBeNull()
    expect(hook._cameraApi).toBeNull()
  })

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

  test("updates built-in first-party dashboards incrementally when entrypoint matches", () => {
    const frames = [
      {
        id: "netperf_recent_samples",
        query: "in:rperf_metrics time:last_24h sort:timestamp:desc limit:500",
        status: "ok",
        results: [{agent_id: "agent-spoke-1", metric_name: "rperf.bits_per_second", value: 940_000_000}],
      },
    ]
    const hook = hookContext({disconnectFrameStream: vi.fn()})
    hook._host = baseHost({
      data_provider: {
        stream_topic: "dashboards:network-performance",
        stream_token: "token-v1",
        refresh_interval_ms: 30_000,
      },
      package: {
        name: "Network Performance",
        source_type: "first_party",
        capabilities: ["srql.execute", "navigation.open"],
        renderer: {
          kind: "built_in",
          interface_version: "dashboard-built-in-v1",
          trust: "first_party",
          artifact: "network-performance",
          entrypoint: "network_performance",
        },
        frames,
      },
    })
    hook._hostPayloadSignature = "built-in-v1"
    const notified = []
    hook._frameUpdateCallbacks.push((update) => notified.push(update))

    const nextHost = baseHost({
      data_provider: {
        stream_topic: "dashboards:network-performance",
        stream_token: "token-v1",
        refresh_interval_ms: 30_000,
      },
      package: {
        name: "Network Performance",
        source_type: "first_party",
        capabilities: ["srql.execute", "navigation.open"],
        renderer: {
          kind: "built_in",
          interface_version: "dashboard-built-in-v1",
          trust: "first_party",
          artifact: "network-performance",
          entrypoint: "network_performance",
        },
        frames: [
          {
            id: "netperf_recent_samples",
            query: "in:rperf_metrics time:last_24h sort:timestamp:desc limit:500",
            status: "ok",
            results: [{agent_id: "agent-spoke-2", metric_name: "rperf.bits_per_second", value: 420_000_000}],
          },
          {
            id: "spoke_history",
            query: "in:rperf_metrics agent_id:\"agent-spoke-2\" time:last_24h sort:timestamp:desc limit:200",
            status: "ok",
            results: [{agent_id: "agent-spoke-2", metric_name: "rperf.loss_percent", value: 0.4}],
          },
        ],
      },
    })

    expect(hook.updateBrowserModuleHost(nextHost, "built-in-v2")).toEqual(true)
    expect(hook._hostPayloadSignature).toEqual("built-in-v2")
    expect(hook._host.package.frames).toBe(frames)
    expect(frames.map((frame) => frame.id)).toEqual(["netperf_recent_samples", "spoke_history"])
    expect(notified).toHaveLength(1)
    expect(notified[0].payload.host_update).toBe(true)
    expect(hook.disconnectFrameStream).not.toHaveBeenCalled()

    const mismatchedEntrypointHost = baseHost({
      package: {
        ...nextHost.package,
        renderer: {
          ...nextHost.package.renderer,
          entrypoint: "security_findings",
          artifact: "security-findings",
        },
      },
    })
    expect(hook.updateBrowserModuleHost(mismatchedEntrypointHost, "built-in-v3")).toEqual(false)
  })

  test("preserves loaded frames and optional frames across pending_frames host updates", () => {
    const arrowPayload = new Uint8Array([9, 8, 7])
    const frames = [
      {
        id: "netperf_recent_samples",
        query: "in:rperf_metrics time:last_24h sort:timestamp:desc limit:500",
        encoding: "json_rows",
        status: "ok",
        row_count: 1,
        truncated: false,
        refreshed_at: "2026-11-18T04:00:00Z",
        results: [{agent_id: "agent-spoke-1", metric_name: "rperf.bits_per_second", value: 940_000_000}],
      },
      {
        id: "netperf_arrow_summary",
        query: "in:rperf_metrics limit:10",
        encoding: "arrow_ipc",
        payload_transport: "channel_binary",
        payload: arrowPayload,
        payload_encoding: "arraybuffer",
        status: "ok",
        row_count: 4,
        truncated: true,
      },
      {
        id: "netperf_responder_capacity",
        required: false,
        status: "ok",
        results: [{agent_id: "agent-hub-east-01", metric_name: "rperf.responder_active_sessions", value: 2}],
      },
      {
        id: "netperf_agents",
        required: false,
        status: "ok",
        results: [{uid: "agent-hub-east-01", name: "hub-east-01"}],
      },
      {
        id: "spoke_history",
        required: false,
        status: "ok",
        results: [{agent_id: "agent-spoke-1", metric_name: "rperf.bits_per_second", value: 910_000_000}],
      },
    ]

    const hook = hookContext({disconnectFrameStream: vi.fn()})
    hook._host = baseHost({
      data_provider: {
        stream_topic: "dashboards:network-performance",
        stream_token: "token-v1",
        refresh_interval_ms: 30_000,
      },
      package: {
        name: "Network Performance",
        source_type: "first_party",
        capabilities: ["srql.execute", "navigation.open"],
        renderer: {
          kind: "built_in",
          interface_version: "dashboard-built-in-v1",
          trust: "first_party",
          artifact: "network-performance",
          entrypoint: "network_performance",
        },
        frames,
      },
    })
    hook._hostPayloadSignature = "built-in-v1"
    const notified = []
    hook._frameUpdateCallbacks.push((update) => notified.push(update))

    const pendingHost = baseHost({
      data_provider: {
        stream_topic: "dashboards:network-performance",
        stream_token: "token-v2",
        refresh_interval_ms: 30_000,
      },
      package: {
        name: "Network Performance",
        source_type: "first_party",
        capabilities: ["srql.execute", "navigation.open"],
        renderer: {
          kind: "built_in",
          interface_version: "dashboard-built-in-v1",
          trust: "first_party",
          artifact: "network-performance",
          entrypoint: "network_performance",
        },
        // LiveView push_patch sends only required frames in loading state and omits optional frames
        frames: [
          {
            id: "netperf_recent_samples",
            query: "in:rperf_metrics time:last_24h sort:timestamp:desc limit:500",
            encoding: "json_rows",
            required: true,
            status: "loading",
            results: [],
          },
          {
            id: "netperf_arrow_summary",
            query: "in:rperf_metrics limit:10",
            encoding: "json_rows",
            required: true,
            status: "loading",
            results: [],
          },
        ],
      },
    })

    expect(hook.updateBrowserModuleHost(pendingHost, "built-in-v2")).toEqual(true)
    expect(notified).toHaveLength(1)
    expect(hook.disconnectFrameStream).toHaveBeenCalledTimes(1)
    expect(hook.connectFrameStream).toHaveBeenCalledWith(hook._host)

    const updatedFrames = hook._host.package.frames
    expect(updatedFrames.map((f) => f.id)).toEqual([
      "netperf_recent_samples",
      "netperf_arrow_summary",
      "netperf_responder_capacity",
      "netperf_agents",
      "spoke_history",
    ])
    const samplesFrame = updatedFrames.find((f) => f.id === "netperf_recent_samples")
    expect(samplesFrame.status).toBe("loading")
    expect(samplesFrame.results).toEqual([
      {agent_id: "agent-spoke-1", metric_name: "rperf.bits_per_second", value: 940_000_000},
    ])
    expect(samplesFrame.row_count).toBe(1)
    expect(samplesFrame.truncated).toBe(false)

    const arrowFrame = updatedFrames.find((f) => f.id === "netperf_arrow_summary")
    expect(arrowFrame.encoding).toBe("arrow_ipc")
    expect(arrowFrame.payload).toBe(arrowPayload)
    expect(arrowFrame.row_count).toBe(4)
    expect(arrowFrame.truncated).toBe(true)
  })

  test("drops previous frame rows when a pending host update changes the frame query", () => {
    const renderer = {
      kind: "built_in",
      interface_version: "dashboard-built-in-v1",
      trust: "first_party",
      artifact: "network-performance",
      entrypoint: "network_performance",
    }
    const hook = hookContext({disconnectFrameStream: vi.fn()})
    hook._host = baseHost({
      package: {
        name: "Network Performance",
        source_type: "first_party",
        capabilities: ["srql.execute"],
        renderer,
        frames: [
          {
            id: "netperf_recent_samples",
            query: "in:rperf_metrics time:last_24h limit:500",
            status: "ok",
            results: [{agent_id: "agent-spoke-1", value: 1}],
          },
          {
            id: "spoke_history",
            required: false,
            query: "in:rperf_metrics agent_id:agent-spoke-1",
            status: "ok",
            results: [{agent_id: "agent-spoke-1", value: 2}],
          },
          {
            id: "netperf_agents",
            required: false,
            query: "in:agents",
            status: "ok",
            results: [{uid: "agent-hub-east-01"}],
          },
        ],
      },
    })
    hook._hostPayloadSignature = "built-in-v1"

    const pendingHost = baseHost({
      package: {
        name: "Network Performance",
        source_type: "first_party",
        capabilities: ["srql.execute"],
        renderer,
        data_frames: [
          {id: "netperf_recent_samples", query: "in:rperf_metrics agent_id:agent-spoke-2 time:last_24h limit:500"},
          {id: "spoke_history", query: "in:rperf_metrics agent_id:agent-spoke-2"},
          {id: "netperf_agents", query: "in:agents"},
        ],
        frames: [
          {
            id: "netperf_recent_samples",
            query: "in:rperf_metrics agent_id:agent-spoke-2 time:last_24h limit:500",
            status: "loading",
            results: [],
          },
        ],
      },
    })

    expect(hook.updateBrowserModuleHost(pendingHost, "built-in-v2")).toEqual(true)
    const updatedFrames = hook._host.package.frames
    expect(updatedFrames.map((f) => f.id)).toEqual(["netperf_recent_samples", "netperf_agents"])
    expect(updatedFrames[0].status).toBe("loading")
    expect(updatedFrames[0].results).toEqual([])
    expect(updatedFrames[1].results).toEqual([{uid: "agent-hub-east-01"}])
  })

  test("reboots built-in and browser-module hosts when settings, capabilities, or permissions change", () => {
    const baseBuiltIn = () =>
      baseHost({
        instance: {
          settings: {lossAlertThresholdPct: 1.0},
        },
        permissions: {actions_invoke: false},
        package: {
          name: "Network Performance",
          source_type: "first_party",
          capabilities: ["srql.execute"],
          renderer: {
            kind: "built_in",
            interface_version: "dashboard-built-in-v1",
            trust: "first_party",
            artifact: "network-performance",
            entrypoint: "network_performance",
          },
          frames: [{id: "netperf_recent_samples", status: "ok", results: []}],
        },
      })

    const hook = hookContext({disconnectFrameStream: vi.fn()})
    hook._host = baseBuiltIn()
    hook._hostPayloadSignature = "v1"

    const changedSettings = baseBuiltIn()
    changedSettings.instance.settings = {lossAlertThresholdPct: 2.5}
    expect(hook.updateBrowserModuleHost(changedSettings, "v2")).toBe(false)

    const changedCapabilities = baseBuiltIn()
    changedCapabilities.package.capabilities = ["srql.execute", "navigation.open"]
    expect(hook.updateBrowserModuleHost(changedCapabilities, "v3")).toBe(false)

    const changedPermissions = baseBuiltIn()
    changedPermissions.permissions = {actions_invoke: true}
    expect(hook.updateBrowserModuleHost(changedPermissions, "v4")).toBe(false)
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

describe("DashboardWasmHost async boot/updated/destroyed race hardening", () => {
  function createLifecycleHookContext() {
    const children = []
    let innerHtmlValue = ""
    const el = {
      dataset: {},
      classList: {add: vi.fn()},
      children,
      appendChild: vi.fn((node) => {
        children.push(node)
        return node
      }),
      removeChild: vi.fn((node) => {
        const index = children.indexOf(node)
        if (index >= 0) children.splice(index, 1)
      }),
      get innerHTML() {
        return innerHtmlValue
      },
      set innerHTML(value) {
        innerHtmlValue = String(value)
        children.length = 0
      },
    }

    globalThis.window = {
      ...globalThis.window,
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
    }
    globalThis.document = {
      ...globalThis.document,
      visibilityState: "visible",
      documentElement: {},
      body: {},
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
      querySelector: vi.fn(() => null),
    }
    globalThis.MutationObserver = class {
      observe() {}
      disconnect() {}
    }

    return hookContext({
      el,
      teardownMap: vi.fn(),
      disconnectFrameStream: vi.fn(),
      applyThemeStyle: vi.fn(),
      resizeMap: vi.fn(),
    })
  }

  function deferred() {
    let resolve
    let reject
    const promise = new Promise((res, rej) => {
      resolve = res
      reject = rej
    })
    return {promise, resolve, reject}
  }

  async function flushMicrotasks(turns = 12) {
    for (let i = 0; i < turns; i += 1) {
      await Promise.resolve()
    }
  }

  test("updated() mid-import() cancels stale boot without mounting stale module", async () => {
    const mountCalls = []
    const destroyCalls = []
    const hook = createLifecycleHookContext()

    globalThis.__t5RaceHooks = {
      mod1(el) {
        mountCalls.push("mod1")
        const node = {id: "child-1"}
        el.appendChild(node)
        return {
          destroy() {
            destroyCalls.push("mod1")
            el.removeChild(node)
          },
        }
      },
      mod2(el) {
        mountCalls.push("mod2")
        const node = {id: "child-2"}
        el.appendChild(node)
        return {
          destroy() {
            destroyCalls.push("mod2")
            el.removeChild(node)
          },
        }
      },
    }

    const url1 =
      "data:text/javascript,export function mountDashboard(el, host){return globalThis.__t5RaceHooks.mod1(el,host)}"
    const url2 =
      "data:text/javascript,export function mountDashboard(el, host){return globalThis.__t5RaceHooks.mod2(el,host)}"

    try {
      hook.el.dataset.host = JSON.stringify(
        baseHost({package: {...baseHost().package, renderer_url: url1}}),
      )
      hook.mounted()

      // Immediately trigger updated() while boot1 is suspended at await import(url1)
      hook.el.dataset.host = JSON.stringify(
        baseHost({package: {...baseHost().package, renderer_url: url2}}),
      )
      hook.updated()

      await new Promise((resolve) => setTimeout(resolve, 40))
      await flushMicrotasks()

      expect(mountCalls).toEqual(["mod2"])
      expect(hook.el.children).toEqual([{id: "child-2"}])
      expect(hook.connectFrameStream).toHaveBeenCalledTimes(1)

      hook.destroyed()
      expect(destroyCalls).toEqual(["mod2"])
      expect(hook.el.children).toEqual([])
    } finally {
      delete globalThis.__t5RaceHooks
    }
  }, 30_000)

  test("updated() mid-mountDashboard() destroys out-of-order stale handle without overwriting live handle", async () => {
    const d1 = deferred()
    const d2 = deferred()
    const entered1 = deferred()
    const entered2 = deferred()
    const mountCalls = []
    const destroyCalls = []
    const hook = createLifecycleHookContext()

    globalThis.__t5RaceMount = {
      async slow1(el) {
        mountCalls.push("slow1")
        entered1.resolve()
        const handle = await d1.promise
        const node = {id: "slow-node-1"}
        el.appendChild(node)
        return {
          destroy() {
            destroyCalls.push("slow1")
            el.removeChild(node)
            handle?.onDestroy?.()
          },
        }
      },
      async slow2(el) {
        mountCalls.push("slow2")
        entered2.resolve()
        const handle = await d2.promise
        const node = {id: "slow-node-2"}
        el.appendChild(node)
        return {
          destroy() {
            destroyCalls.push("slow2")
            el.removeChild(node)
            handle?.onDestroy?.()
          },
        }
      },
    }

    const url1 =
      "data:text/javascript,export function mountDashboard(el, host){return globalThis.__t5RaceMount.slow1(el,host)}"
    const url2 =
      "data:text/javascript,export function mountDashboard(el, host){return globalThis.__t5RaceMount.slow2(el,host)}"

    try {
      hook.el.dataset.host = JSON.stringify(
        baseHost({package: {...baseHost().package, renderer_url: url1}}),
      )
      hook.mounted()
      await entered1.promise

      // Trigger updated() while slow1's mountDashboard() is still pending
      hook.el.dataset.host = JSON.stringify(
        baseHost({package: {...baseHost().package, renderer_url: url2}}),
      )
      hook.updated()
      await entered2.promise

      // Resolve slow2 BEFORE slow1 (out-of-order)
      d2.resolve({})
      await flushMicrotasks()
      expect(hook.el.children).toEqual([{id: "slow-node-2"}])
      expect(destroyCalls).toEqual([])

      // Now slow1 settles late: must immediately destroy its stale handle and leave slow2 intact
      d1.resolve({})
      await flushMicrotasks()

      expect(mountCalls).toEqual(["slow1", "slow2"])
      expect(destroyCalls).toEqual(["slow1"])
      expect(hook.el.children).toEqual([{id: "slow-node-2"}])
      expect(hook.connectFrameStream).toHaveBeenCalledTimes(1)

      hook.destroyed()
      expect(destroyCalls).toEqual(["slow1", "slow2"])
      expect(hook.el.children).toEqual([])
    } finally {
      delete globalThis.__t5RaceMount
    }
  }, 30_000)

  test("destroyed() mid-import() and mid-mountDashboard() prevents late mount or leaks", async () => {
    const mountCalls = []
    const destroyCalls = []

    // Case A: destroyed() mid-import()
    const hookA = createLifecycleHookContext()
    globalThis.__t5DestroyImport = {
      mount() {
        mountCalls.push("import-mount")
        return {destroy: () => destroyCalls.push("import-destroy")}
      },
    }
    const urlA =
      "data:text/javascript,export function mountDashboard(){return globalThis.__t5DestroyImport.mount()}"

    try {
      hookA.el.dataset.host = JSON.stringify(
        baseHost({package: {...baseHost().package, renderer_url: urlA}}),
      )
      hookA.mounted()
      hookA.destroyed()

      await new Promise((resolve) => setTimeout(resolve, 40))
      await flushMicrotasks()

      expect(mountCalls).toEqual([])
      expect(hookA.connectFrameStream).not.toHaveBeenCalled()
    } finally {
      delete globalThis.__t5DestroyImport
    }

    // Case B: destroyed() mid-mountDashboard()
    const dPending = deferred()
    const entered = deferred()
    const hookB = createLifecycleHookContext()
    globalThis.__t5DestroyMount = {
      async mount(el) {
        mountCalls.push("pending-mount")
        entered.resolve()
        await dPending.promise
        const node = {id: "zombie-node"}
        el.appendChild(node)
        return {
          destroy() {
            destroyCalls.push("pending-destroy")
            el.removeChild(node)
          },
        }
      },
    }
    const urlB =
      "data:text/javascript,export function mountDashboard(el){return globalThis.__t5DestroyMount.mount(el)}"

    try {
      hookB.el.dataset.host = JSON.stringify(
        baseHost({package: {...baseHost().package, renderer_url: urlB}}),
      )
      hookB.mounted()
      await entered.promise

      hookB.destroyed()
      dPending.resolve()
      await flushMicrotasks()

      expect(mountCalls).toEqual(["pending-mount"])
      expect(destroyCalls).toEqual(["pending-destroy"])
      expect(hookB.el.children).toEqual([])
      expect(hookB._moduleDestroy).toBeUndefined()
      expect(hookB.connectFrameStream).not.toHaveBeenCalled()
    } finally {
      delete globalThis.__t5DestroyMount
    }
  }, 30_000)

  test("same-renderer updated() mid-mount() with updated frames and rotated/cleared stream_token reboots cleanly", async () => {
    const d1 = deferred()
    const d2 = deferred()
    const entered1 = deferred()
    const entered2 = deferred()
    const mountRecords = []
    const destroyCalls = []
    const hook = createLifecycleHookContext()

    globalThis.__t5SameRendererUpdate = {
      async mount(el, host, api) {
        const callId = host.data_provider?.stream_token ?? "cleared"
        const record = {
          callId,
          initialFrames: api.frames(),
          receivedUpdates: [],
          abortedAtMount: Boolean(api.signal?.aborted),
        }
        mountRecords.push(record)
        api.onFrameUpdate?.((upd) => record.receivedUpdates.push(upd))

        if (mountRecords.length === 1) {
          entered1.resolve()
          await d1.promise
        } else {
          entered2.resolve()
          await d2.promise
        }

        const node = {id: `node-${callId}`}
        el.appendChild(node)
        return {
          destroy() {
            destroyCalls.push(callId)
            el.removeChild(node)
          },
        }
      },
    }

    const sameRendererUrl =
      "data:text/javascript,export function mountDashboard(el, host, api){return globalThis.__t5SameRendererUpdate.mount(el, host, api)}"

    try {
      // host1 omits package.frames and sets initial stream_token: "tok-1"
      const host1 = baseHost({
        data_provider: {
          stream_topic: "dashboards:test",
          stream_token: "tok-1",
          refresh_interval_ms: 10_000,
        },
        package: {
          name: "Test Dashboard",
          capabilities: [],
          renderer_url: sameRendererUrl,
          renderer: {
            kind: "browser_module",
            interface_version: "dashboard-browser-module-v1",
            trust: "trusted",
          },
        },
      })

      hook.el.dataset.host = JSON.stringify(host1)
      hook.mounted()
      await entered1.promise

      // host._host must NOT be prematurely assigned while mount() #1 is pending
      expect(hook._host).toBeUndefined()

      // Same-renderer updated() arrives mid-mount() with frames and rotated stream_token: "tok-2"
      const host2 = baseHost({
        data_provider: {
          stream_topic: "dashboards:test",
          stream_token: "tok-2",
          refresh_interval_ms: 10_000,
        },
        package: {
          ...host1.package,
          frames: [{id: "f1", status: "ok", results: [{v: 42}]}],
        },
      })
      hook.el.dataset.host = JSON.stringify(host2)
      hook.updated()
      await entered2.promise

      // Resolve mount #2 first, then let stale mount #1 settle late
      d2.resolve()
      await flushMicrotasks()
      d1.resolve()
      await flushMicrotasks()

      expect(mountRecords).toHaveLength(2)
      expect(mountRecords[0].initialFrames).toEqual([])
      expect(mountRecords[0].receivedUpdates).toEqual([])
      expect(mountRecords[1].initialFrames).toEqual([{id: "f1", status: "ok", results: [{v: 42}]}])
      expect(destroyCalls).toEqual(["tok-1"])
      expect(hook.connectFrameStream).toHaveBeenCalledTimes(1)
      expect(hook.connectFrameStream.mock.calls[0][0].data_provider.stream_token).toBe("tok-2")
      expect(hook._host.package.frames).toEqual([{id: "f1", status: "ok", results: [{v: 42}]}])

      // Also verify cleared stream_token mid-mount() prevents connectFrameStream on stale token
      const d3 = deferred()
      const d4 = deferred()
      const entered3 = deferred()
      const entered4 = deferred()
      const hookCleared = createLifecycleHookContext()
      let clearedSeq = 0
      globalThis.__t5SameRendererUpdate.mount = async (el) => {
        clearedSeq += 1
        const seq = clearedSeq
        if (seq === 1) {
          entered3.resolve()
          await d3.promise
        } else {
          entered4.resolve()
          await d4.promise
        }
        const node = {id: `cleared-${seq}`}
        el.appendChild(node)
        return {
          destroy() {
            destroyCalls.push(`cleared-${seq}`)
            el.removeChild(node)
          },
        }
      }

      const hostWithTok = baseHost({
        data_provider: {stream_topic: "dashboards:test", stream_token: "stale-tok"},
        package: {...host1.package},
      })
      const hostClearedTok = baseHost({
        data_provider: {stream_topic: "dashboards:test"},
        package: {...host1.package, frames: [{id: "f2", status: "ok", results: [{v: 99}]}]},
      })

      hookCleared.el.dataset.host = JSON.stringify(hostWithTok)
      hookCleared.mounted()
      await entered3.promise

      hookCleared.el.dataset.host = JSON.stringify(hostClearedTok)
      hookCleared.updated()
      await entered4.promise

      d4.resolve()
      await flushMicrotasks()
      d3.resolve()
      await flushMicrotasks()

      expect(hookCleared.connectFrameStream).toHaveBeenCalledTimes(1)
      expect(hookCleared.connectFrameStream.mock.calls[0][0].data_provider.stream_token).toBeUndefined()
      expect(hookCleared._host.package.frames).toEqual([{id: "f2", status: "ok", results: [{v: 99}]}])

      hook.destroyed()
      hookCleared.destroyed()
    } finally {
      delete globalThis.__t5SameRendererUpdate
    }
  }, 30_000)

  test("withTimeout rejection aborts pending waitForReady mountBlueprintDashboard and leaks zero MutationObservers after destroyed()", async () => {
    const win = new Window({url: "https://dashboard.serviceradar.test/"})
    const keys = [
      "window",
      "document",
      "HTMLElement",
      "HTMLDivElement",
      "Element",
      "Node",
      "Text",
      "SVGElement",
      "DocumentFragment",
      "MutationObserver",
      "ResizeObserver",
      "IntersectionObserver",
      "Event",
      "CustomEvent",
      "MouseEvent",
      "KeyboardEvent",
      "FocusEvent",
      "getComputedStyle",
      "requestAnimationFrame",
      "cancelAnimationFrame",
      "matchMedia",
    ]
    const previous = new Map()
    for (const key of keys) {
      previous.set(key, Object.getOwnPropertyDescriptor(globalThis, key))
      const value = key === "window" ? win : win[key]
      if (value !== undefined) {
        Object.defineProperty(globalThis, key, {
          configurable: true,
          writable: true,
          value:
            typeof value === "function" &&
            key !== "MutationObserver" &&
            key !== "ResizeObserver" &&
            key !== "IntersectionObserver" &&
            !/^[A-Z]/.test(key)
              ? value.bind(win)
              : value,
        })
      }
    }

    const activeObservers = new Set()
    const NativeMutationObserver = win.MutationObserver
    globalThis.MutationObserver = class TrackedMutationObserver extends NativeMutationObserver {
      constructor(cb) {
        super(cb)
        this._observing = false
      }
      observe(target, opts) {
        this._observing = true
        activeObservers.add(this)
        return super.observe(target, opts)
      }
      disconnect() {
        this._observing = false
        activeObservers.delete(this)
        return super.disconnect()
      }
    }

    let effectCleanups = 0
    function NeverReadyDashboard() {
      useEffect(() => () => {
        effectCleanups += 1
      }, [])
      return React.createElement(Card, null, "never-ready")
    }

    globalThis.__t5TimeoutBlueprintMount = (el, host, api) =>
      mountBlueprintDashboard(NeverReadyDashboard, {waitForReady: true})(el, host, api)

    const rendererUrl =
      "data:text/javascript,export function mountDashboard(el, host, api){return globalThis.__t5TimeoutBlueprintMount(el, host, api)}"

    try {
      const root = win.document.createElement("div")
      win.document.body.appendChild(root)

      const hook = {
        ...DashboardWasmHost,
        el: root,
        _frameUpdateCallbacks: [],
        connectFrameStream: vi.fn(),
        disconnectFrameStream: vi.fn(),
        pushEvent: vi.fn(),
        isDarkMode: vi.fn(() => false),
      }
      root.dataset.host = JSON.stringify(
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

      hook.mounted()

      // Wait for the 100ms timeout to fire and React passive cleanups to run
      await new Promise((resolve) => setTimeout(resolve, 260))
      await flushMicrotasks()

      expect(hook.el.innerHTML).toContain("Dashboard renderer failed")
      expect(hook.el.innerHTML).toContain("dashboard renderer timed out after 100ms")
      expect(hook._host).toBeUndefined()
      expect(hook.connectFrameStream).not.toHaveBeenCalled()
      expect(effectCleanups).toBe(1)
      // Only hook._themeObserver remains active while the hook is still mounted
      expect(activeObservers.size).toBe(1)

      hook.destroyed()
      await flushMicrotasks()
      expect(activeObservers.size).toBe(0)
    } finally {
      delete globalThis.__t5TimeoutBlueprintMount
      await win.happyDOM.close()
      for (const [key, desc] of previous.entries()) {
        if (desc) Object.defineProperty(globalThis, key, desc)
        else delete globalThis[key]
      }
    }
  }, 30_000)

  test("api.frames(), api.frame(), and api.srql.query() reflect updated() and replaceBinaryFramePayload() when initial package.frames is omitted", async () => {
    const hook = createLifecycleHookContext()
    let capturedApi = null
    const updates = []

    globalThis.__t5OmittedFramesMount = (_el, _host, api) => {
      capturedApi = api
      api.onFrameUpdate((upd) => updates.push(upd))
      return {destroy() {}}
    }

    const rendererUrl =
      "data:text/javascript,export function mountDashboard(el, host, api){return globalThis.__t5OmittedFramesMount(el, host, api)}"

    try {
      const initialHost = baseHost({
        package: {
          name: "Test Dashboard",
          capabilities: [],
          renderer_url: rendererUrl,
          renderer: {
            kind: "browser_module",
            interface_version: "dashboard-browser-module-v1",
            trust: "trusted",
          },
        },
      })

      hook.el.dataset.host = JSON.stringify(initialHost)
      hook.mounted()
      await new Promise((resolve) => setTimeout(resolve, 40))
      await flushMicrotasks()

      expect(capturedApi).not.toBeNull()
      expect(capturedApi.frames()).toEqual([])
      expect(capturedApi.frame("f1")).toBeUndefined()
      expect(capturedApi.srql.query("f1")).toBe("")

      const updatedFrames = [{id: "f1", query: "in:devices", status: "ok", results: [{v: 99}]}]
      hook.el.dataset.host = JSON.stringify(
        baseHost({
          package: {
            ...initialHost.package,
            frames: updatedFrames,
          },
        }),
      )
      hook.updated()

      expect(capturedApi.frames()).toEqual(updatedFrames)
      expect(capturedApi.frame("f1")).toEqual(updatedFrames[0])
      expect(capturedApi.srql.query("f1")).toBe("in:devices")
      expect(updates).toHaveLength(1)

      // Also verify replaceBinaryFramePayload updates this._host.package.frames when frames were initially omitted
      const binHook = hookContext({
        _host: baseHost({
          package: {
            name: "Test Dashboard",
            capabilities: [],
            renderer: {
              kind: "browser_module",
              interface_version: "dashboard-browser-module-v1",
              trust: "trusted",
            },
          },
        }),
      })
      const binApi = binHook.browserModuleApi(binHook._host)
      expect(binApi.frames()).toEqual([])

      const enc = new TextEncoder()
      const idBytes = enc.encode("f2")
      const metaBytes = enc.encode(JSON.stringify({query: "in:flows limit:5", encoding: "arrow_ipc", status: "ok"}))
      const payloadBytes = new Uint8Array([10, 20, 30])
      const buf = new Uint8Array(10 + idBytes.length + metaBytes.length + payloadBytes.length)
      buf.set(enc.encode("DFB1"), 0)
      const dv = new DataView(buf.buffer)
      dv.setUint16(4, idBytes.length, false)
      dv.setUint32(6, metaBytes.length, false)
      buf.set(idBytes, 10)
      buf.set(metaBytes, 10 + idBytes.length)
      buf.set(payloadBytes, 10 + idBytes.length + metaBytes.length)

      binHook.replaceBinaryFramePayload(buf.buffer)

      expect(Array.isArray(binHook._host.package.frames)).toBe(true)
      expect(binApi.frames()).toHaveLength(1)
      expect(binApi.frame("f2")).toMatchObject({id: "f2", query: "in:flows limit:5", encoding: "arrow_ipc"})
      expect(binApi.srql.query("f2")).toBe("in:flows limit:5")
      expect(Array.from(binApi.arrow.frameBytes("f2"))).toEqual([10, 20, 30])

      hook.destroyed()
    } finally {
      delete globalThis.__t5OmittedFramesMount
    }
  }, 30_000)
})

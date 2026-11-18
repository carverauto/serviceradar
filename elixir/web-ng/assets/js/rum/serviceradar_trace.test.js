// @vitest-environment happy-dom
import fs from "node:fs"
import path from "node:path"
import vm from "node:vm"
import {afterEach, describe, expect, test, vi} from "vitest"
import {
  generateTraceparent,
  patchFetch,
  patchXMLHttpRequest,
  shouldPropagateTrace,
} from "./serviceradar_trace.js"
import {
  buildBeaconUrl,
  ensureServiceRadarBoomerangInit,
  initServiceRadarBoomerang,
} from "./boomerang_init.js"

const BUNDLE_CANDIDATES = [
  path.resolve("static/assets/rum/boomerang-sr.min.js"),
  path.resolve("../priv/static/assets/rum/boomerang-sr.min.js"),
]

afterEach(() => {
  vi.restoreAllMocks()
})

describe("ServiceRadarTrace W3C traceparent plugin", () => {
  test("generateTraceparent produces valid W3C 00-<32hex>-<16hex>-01 non-zero IDs", () => {
    const first = generateTraceparent(window.crypto)
    const second = generateTraceparent(window.crypto)

    expect(first.traceId).toMatch(/^[0-9a-f]{32}$/)
    expect(first.spanId).toMatch(/^[0-9a-f]{16}$/)
    expect(first.traceId).not.toMatch(/^0+$/)
    expect(first.spanId).not.toMatch(/^0+$/)
    expect(first.traceparent).toBe(`00-${first.traceId}-${first.spanId}-01`)
    expect(second.traceparent).not.toBe(first.traceparent)

    // Zero-filled crypto mock still produces non-zero fallback IDs
    const zeroed = generateTraceparent({
      getRandomValues(arr) {
        arr.fill(0)
        return arr
      },
    })
    expect(zeroed.traceparent).toMatch(/^00-[0-9a-f]{32}-[0-9a-f]{16}-01$/)
    expect(zeroed.traceId).not.toMatch(/^0+$/)
    expect(zeroed.spanId).not.toMatch(/^0+$/)
  })

  test("shouldPropagateTrace allows same-origin and allowlisted origins, excluding beacon and third parties", () => {
    const pageOrigin = "https://portal.example.com"
    const allowed = ["https://api.example.com", "https://cdn-api.example.com:8443/v1"]

    expect(shouldPropagateTrace("/api/orders", pageOrigin, allowed)).toBe(true)
    expect(shouldPropagateTrace("https://portal.example.com/graphql", pageOrigin, allowed)).toBe(true)
    expect(shouldPropagateTrace("https://api.example.com/v1/cart", pageOrigin, allowed)).toBe(true)
    expect(shouldPropagateTrace("https://cdn-api.example.com:8443/health", pageOrigin, allowed)).toBe(true)

    // Cross-origin not in allowlist -> false
    expect(shouldPropagateTrace("https://analytics.thirdparty.example/collect", pageOrigin, allowed)).toBe(false)
    // Scheme downgrade or non-http(s) -> false
    expect(shouldPropagateTrace("http://portal.example.com/api", pageOrigin, allowed)).toBe(false)
    expect(shouldPropagateTrace("data:text/plain,hello", pageOrigin, allowed)).toBe(false)
    // Beacon endpoint itself -> false
    expect(shouldPropagateTrace("/rum/v1/beacon?key=sr_rum_123", pageOrigin, allowed, "/rum/v1/beacon")).toBe(false)
    expect(
      shouldPropagateTrace("https://api.example.com/rum/v1/beacon", pageOrigin, allowed, "https://api.example.com/rum/v1/beacon"),
    ).toBe(false)
  })

  test("patchFetch injects traceparent on allowed origins and preserves caller-supplied traceparent", async () => {
    const calls = []
    const addedVars = []

    const fakeWin = {
      location: {origin: "https://portal.example.com"},
      crypto: window.crypto,
      Headers: window.Headers,
      Request: window.Request,
      BOOMR: {
        addVar(vars) {
          addedVars.push(vars)
        },
      },
      fetch: async (input, init) => {
        calls.push({input, init})
        return {ok: true, status: 200}
      },
    }

    const state = {
      tracePropagateOrigins: ["https://api.example.com"],
      beaconUrl: "/rum/v1/beacon",
    }
    patchFetch(fakeWin, state)

    // 1. Same-origin gets traceparent
    await fakeWin.fetch("/api/session", {method: "GET"})
    expect(calls).toHaveLength(1)
    expect(calls[0].init.headers.traceparent).toMatch(/^00-[0-9a-f]{32}-[0-9a-f]{16}-01$/)
    expect(addedVars).toHaveLength(1)
    expect(addedVars[0]["sr.trace_id"]).toMatch(/^[0-9a-f]{32}$/)
    expect(addedVars[0]["sr.span_id"]).toMatch(/^[0-9a-f]{16}$/)

    // 2. Allowlisted cross-origin gets traceparent
    await fakeWin.fetch("https://api.example.com/v1/items", {headers: {"x-app": "1"}})
    expect(calls[1].init.headers.traceparent).toMatch(/^00-[0-9a-f]{32}-[0-9a-f]{16}-01$/)
    expect(calls[1].init.headers["x-app"]).toBe("1")

    // 3. Disallowed third-party origin does NOT receive traceparent
    await fakeWin.fetch("https://thirdparty.example/pixel", {headers: {"x-other": "yes"}})
    expect(calls[2].init.headers.traceparent).toBeUndefined()
    expect(calls[2].init.headers["x-other"]).toBe("yes")

    // 4. Beacon target does NOT receive traceparent
    await fakeWin.fetch("/rum/v1/beacon?key=sr_rum_123", {method: "POST", body: "u=/"})
    expect(calls[3].init.headers).toBeUndefined()

    // 5. Caller-supplied traceparent is never overwritten
    const callerTp = "00-11111111111111111111111111111111-2222222222222222-01"
    await fakeWin.fetch("/api/custom", {headers: {Traceparent: callerTp}})
    expect(calls[4].init.headers.Traceparent).toBe(callerTp)
    expect(calls[4].init.headers.traceparent).toBeUndefined()

    // 6. URL instance input gets traceparent when origin is allowlisted
    await fakeWin.fetch(new URL("https://api.example.com/v1/url-object"))
    expect(calls[5].input).toBeInstanceOf(URL)
    expect(calls[5].init.headers.traceparent).toMatch(/^00-[0-9a-f]{32}-[0-9a-f]{16}-01$/)
  })

  test("patchXMLHttpRequest injects traceparent only on allowed origins and preserves explicit headers", () => {
    const sent = []
    class MockXHR {
      open(_method, _url) {
        this._headers = {}
      }
      setRequestHeader(k, v) {
        this._headers[k] = v
      }
      send(_body) {
        sent.push(this._headers)
      }
    }

    const fakeWin = {
      location: {origin: "https://portal.example.com"},
      crypto: window.crypto,
      XMLHttpRequest: MockXHR,
      BOOMR: {addVar: vi.fn()},
    }

    patchXMLHttpRequest(fakeWin, {
      tracePropagateOrigins: ["https://api.example.com"],
      beaconUrl: "/rum/v1/beacon",
    })

    // Same-origin XHR
    const xhr1 = new fakeWin.XMLHttpRequest()
    xhr1.open("GET", "/api/profile")
    xhr1.send()
    expect(sent[0].traceparent).toMatch(/^00-[0-9a-f]{32}-[0-9a-f]{16}-01$/)

    // Disallowed third-party XHR
    const xhr2 = new fakeWin.XMLHttpRequest()
    xhr2.open("POST", "https://metrics.thirdparty.example/ingest")
    xhr2.send("{}")
    expect(sent[1].traceparent).toBeUndefined()

    // Caller-provided traceparent preserved
    const callerTp = "00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-01"
    const xhr3 = new fakeWin.XMLHttpRequest()
    xhr3.open("GET", "/api/orders")
    xhr3.setRequestHeader("Traceparent", callerTp)
    xhr3.send()
    expect(sent[2].Traceparent).toBe(callerTp)
    expect(sent[2].traceparent).toBeUndefined()
  })

  test("boomerang_init configures sr.key, ?key= query param, and respects sampleRate", () => {
    expect(buildBeaconUrl("/rum/v1/beacon", "sr_rum_abc123")).toBe(
      "/rum/v1/beacon?key=sr_rum_abc123",
    )
    expect(buildBeaconUrl("/rum/v1/beacon?env=prod", "sr_rum_abc123")).toBe(
      "/rum/v1/beacon?env=prod&key=sr_rum_abc123",
    )

    const addVar = vi.fn()
    const init = vi.fn()
    const fakeWin = {
      location: {origin: "https://portal.example.com"},
      crypto: window.crypto,
      BOOMR: {addVar, init, subscribe: vi.fn(), plugins: {}},
      BOOMR_config: {
        ServiceRadar: {
          siteKey: "sr_rum_testkey",
          beaconUrl: "/rum/v1/beacon",
          sampleRate: 1.0,
          tracePropagateOrigins: ["https://api.example.com"],
        },
      },
    }

    expect(initServiceRadarBoomerang(fakeWin)).toBe(true)
    expect(addVar).toHaveBeenCalledWith("sr.key", "sr_rum_testkey")
    expect(init).toHaveBeenCalledWith(
      expect.objectContaining({
        beacon_url: "/rum/v1/beacon?key=sr_rum_testkey",
        beacon_type: "POST",
        ServiceRadarTrace: {
          tracePropagateOrigins: ["https://api.example.com"],
          beaconUrl: "/rum/v1/beacon?key=sr_rum_testkey",
        },
      }),
    )

    // Sample rate 0 drops initialization cleanly
    const droppedInit = vi.fn()
    const droppedWin = {
      BOOMR: {addVar: vi.fn(), init: droppedInit, plugins: {}},
      BOOMR_config: {
        ServiceRadar: {
          siteKey: "sr_rum_drop",
          sampleRate: 0,
        },
      },
    }
    expect(initServiceRadarBoomerang(droppedWin)).toBe(false)
    expect(droppedInit).not.toHaveBeenCalled()
    expect(droppedWin.BOOMR_config.ServiceRadar.sampledOut).toBe(true)

    // Late BOOMR_config.ServiceRadar initialization via DOMContentLoaded/load retry
    const docListeners = new Map()
    const winListeners = new Map()
    const lateAddVar = vi.fn()
    const lateInit = vi.fn()
    const lateWin = {
      location: {origin: "https://portal.example.com"},
      crypto: window.crypto,
      document: {
        readyState: "loading",
        addEventListener(type, fn) {
          docListeners.set(type, fn)
        },
        removeEventListener(type) {
          docListeners.delete(type)
        },
      },
      addEventListener(type, fn) {
        winListeners.set(type, fn)
      },
      removeEventListener(type) {
        winListeners.delete(type)
      },
      BOOMR: {addVar: lateAddVar, init: lateInit, subscribe: vi.fn(), plugins: {}},
    }

    expect(ensureServiceRadarBoomerangInit(lateWin)).toBe(false)
    expect(lateInit).not.toHaveBeenCalled()

    lateWin.BOOMR_config = {
      ServiceRadar: {
        siteKey: "sr_rum_late_key",
        beaconUrl: "/rum/v1/beacon",
      },
    }
    docListeners.get("DOMContentLoaded")?.()
    expect(lateInit).toHaveBeenCalledTimes(1)
    expect(lateInit).toHaveBeenCalledWith(
      expect.objectContaining({
        beacon_url: "/rum/v1/beacon?key=sr_rum_late_key",
      }),
    )

    // Subsequent load firing does not double-initialize BOOMR
    winListeners.get("load")?.()
    expect(lateInit).toHaveBeenCalledTimes(1)
  })

  function createVmContext({withConfig = true} = {}) {
    const beaconCalls = []
    const fetchCalls = []
    const consoleLogs = []
    const windowListeners = new Map()
    const documentListeners = new Map()

    const context = {
      window: null,
      document: {
        URL: "https://portal.example.com/overview",
        referrer: "https://portal.example.com/",
        readyState: "complete",
        visibilityState: "visible",
        domain: "portal.example.com",
        cookie: "",
        documentElement: {},
        head: {},
        body: {},
        getElementById: () => null,
        querySelector: () => null,
        querySelectorAll: () => [],
        createElement: () => ({style: {}, setAttribute: () => {}}),
        getElementsByTagName: () => [{parentNode: {insertBefore: () => {}}}],
        addEventListener: (type, fn) => {
          const list = documentListeners.get(type) || []
          list.push(fn)
          documentListeners.set(type, list)
        },
        removeEventListener: () => {},
      },
      navigator: {
        sendBeacon: (url, body) => {
          beaconCalls.push({url, body})
          return true
        },
        userAgent: "ServiceRadarTest/1.0",
        platform: "MacIntel",
        vendor: "ServiceRadar",
      },
      location: {
        href: "https://portal.example.com/overview",
        origin: "https://portal.example.com",
        protocol: "https:",
        hostname: "portal.example.com",
        pathname: "/overview",
        search: "",
      },
      history: {
        pushState: () => {},
        replaceState: () => {},
        go: () => {},
        back: () => {},
        forward: () => {},
      },
      performance: {
        now: () => 42,
        timing: {
          navigationStart: 1_700_000_000_000,
          domainLookupStart: 1_700_000_000_005,
          domainLookupEnd: 1_700_000_000_015,
          connectStart: 1_700_000_000_015,
          connectEnd: 1_700_000_000_045,
          requestStart: 1_700_000_000_045,
          responseStart: 1_700_000_000_120,
          domContentLoadedEventEnd: 1_700_000_000_420,
          loadEventEnd: 1_700_000_000_650,
        },
        getEntriesByType: (type) =>
          type === "navigation"
            ? [
                {
                  serverTiming: [
                    {name: "cdn-cache", duration: 0, description: "HIT"},
                    {name: "edge", duration: 18, description: ""},
                    {name: "origin", duration: 112, description: ""},
                    {name: "ak_p", duration: 0, description: "iad"},
                  ],
                },
              ]
            : [],
      },
      fetch: async (url, init) => {
        fetchCalls.push({url, init})
        return {ok: true, status: 200}
      },
      Image: function MockImage() {},
      Blob,
      crypto: window.crypto,
      Headers: window.Headers,
      Request: window.Request,
      XMLHttpRequest: class MockXMLHttpRequest {
        constructor() {
          this._headers = {}
          this.readyState = 0
          this.status = 200
        }
        open(_method, _url) {
          this._headers = {}
          this.readyState = 1
        }
        setRequestHeader(k, v) {
          this._headers[k] = v
        }
        addEventListener() {}
        removeEventListener() {}
        send(_body) {
          this.readyState = 4
        }
      },
      MutationObserver: class MockMutationObserver {
        observe() {}
        disconnect() {}
        takeRecords() {
          return []
        }
      },
      URL,
      URLSearchParams,
      Uint8Array,
      Math,
      Date,
      RegExp,
      Set,
      Map,
      JSON,
      Object,
      Array,
      String,
      Number,
      Boolean,
      Error,
      TypeError,
      SyntaxError,
      ReferenceError,
      Promise,
      encodeURIComponent,
      decodeURIComponent,
      isNaN,
      isFinite,
      parseInt,
      parseFloat,
      requestAnimationFrame: () => 1,
      cancelAnimationFrame: () => {},
      console: {
        log: (...args) => consoleLogs.push(args.join(" ")),
        warn: (...args) => consoleLogs.push(args.join(" ")),
        error: (...args) => consoleLogs.push(args.join(" ")),
      },
      setTimeout,
      clearTimeout,
      setInterval,
      clearInterval,
      addEventListener: (type, fn) => {
        const list = windowListeners.get(type) || []
        list.push(fn)
        windowListeners.set(type, list)
      },
      removeEventListener: () => {},
    }

    if (withConfig) {
      context.BOOMR_config = {
        ServiceRadar: {
          siteKey: "sr_rum_vm_test",
          beaconUrl: "/rum/v1/beacon",
          sampleRate: 1.0,
          tracePropagateOrigins: ["https://api.example.com"],
          autorun: false,
        },
      }
    }

    context.window = context
    context.self = context
    context.globalThis = context

    return {context, beaconCalls, fetchCalls, consoleLogs, windowListeners, documentListeners}
  }

  test("built boomerang-sr.min.js evaluates cleanly in strict mode with zero debugLog ReferenceErrors", () => {
    const bundlePath = BUNDLE_CANDIDATES.find((p) => fs.existsSync(p))
    expect(bundlePath).toBeDefined()

    const bundleSource = fs.readFileSync(bundlePath, "utf8")
    expect(bundleSource).not.toContain("%boomerang_version%")
    expect(bundleSource).not.toContain("BEGIN_DEBUG")

    const {context, consoleLogs, windowListeners} = createVmContext()

    // Must parse and execute under strict mode without SyntaxError or ReferenceError
    vm.runInNewContext(`"use strict";\n${bundleSource}`, context, {
      filename: "boomerang-sr.min.js",
    })

    expect(context.BOOMR).toBeDefined()
    expect(context.BOOMR.version).toBe("1.815.1")
    expect(context.BOOMR.plugins.ServiceRadarTrace).toBeDefined()
    expect(context.BOOMR.plugins.RT).toBeDefined()
    expect(context.BOOMR.plugins.AutoXHR).toBeDefined()
    expect(context.BOOMR.plugins.SPA).toBeDefined()
    expect(context.BOOMR.plugins.History).toBeDefined()
    expect(context.BOOMR.plugins.BFCache).toBeDefined()
    expect(context.BOOMR.plugins.Continuity).toBeDefined()
    expect(context.BOOMR.plugins.Errors).toBeDefined()

    // Exercise SPA.hook, History, AutoXHR, and BFCache pageshow paths that call debugLog
    expect(() => context.BOOMR.plugins.SPA.hook(false, {})).not.toThrow()
    const pageshowHandlers = windowListeners.get("pageshow") || []
    for (const fn of pageshowHandlers) {
      expect(() => fn({persisted: true, timeStamp: 100})).not.toThrow()
    }
    const xhr = new context.window.XMLHttpRequest()
    xhr.open("GET", "/api/autoxhr-check")

    const caughtErrors = consoleLogs.filter(
      (line) => line.includes("Boomerang caught error") || line.includes("ReferenceError"),
    )
    expect(caughtErrors).toEqual([])
  })

  test("built boomerang-sr.min.js overrides restiming servertiming array, isolates singleBeacon vars, and handles late config", () => {
    const bundlePath = BUNDLE_CANDIDATES.find((p) => fs.existsSync(p))
    expect(bundlePath).toBeDefined()
    const bundleSource = fs.readFileSync(bundlePath, "utf8")

    const {context, fetchCalls} = createVmContext({withConfig: true})
    vm.runInNewContext(`"use strict";\n${bundleSource}`, context, {
      filename: "boomerang-sr.min.js",
    })

    // Trigger traceparent via fetch
    context.window.fetch("https://api.example.com/v1/checkout", {method: "GET"})
    expect(fetchCalls).toHaveLength(1)
    expect(fetchCalls[0].init.headers.traceparent).toMatch(/^00-[0-9a-f]{32}-[0-9a-f]{16}-01$/)

    // Capture full beacon payloads sent via real_sendBeacon across two sequential beacons
    const sentPayloads = []
    context.BOOMR.subscribe("beacon", (data) => {
      sentPayloads.push({...data})
    })
    // Ensure all plugins report complete for direct real_sendBeacon invocation in VM
    for (const pluginName of Object.keys(context.BOOMR.plugins)) {
      context.BOOMR.plugins[pluginName].is_complete = () => true
    }

    // Beacon 1: Page load with CWV, HTTP 503, and restiming JSON lookup array in servertiming
    context.BOOMR.addVar(
      {
        u: "https://portal.example.com/overview",
        "pt.lcp": 1850,
        "pt.fcp": 910,
        "et.inp": 132,
        "c.cls": 0.05,
        "http.errno": 503,
        servertiming: '[["cdn-cache","HIT"],["edge",""]]',
        "rt.tstart": 1_700_000_000_000,
      },
      true,
    )
    context.BOOMR.sendBeacon()
    context.BOOMR.real_sendBeacon()

    expect(sentPayloads).toHaveLength(1)
    expect(sentPayloads[0]["c.lcp"]).toBe(1850)
    expect(sentPayloads[0]["c.fcp"]).toBe(910)
    expect(sentPayloads[0]["c.inp"]).toBe(132)
    expect(sentPayloads[0]["http.status_code"]).toBe(503)
    expect(sentPayloads[0].st).toContain('cdn-cache;dur=0;desc="HIT"')
    expect(sentPayloads[0].st).toContain("edge;dur=18")
    expect(sentPayloads[0].servertiming).toContain('cdn-cache;dur=0;desc="HIT"')
    expect(sentPayloads[0].servertiming.startsWith("[")).toBe(false)

    // Beacon 2: Subsequent XHR beacon must NOT inherit beacon 1's normalized single-beacon vars
    context.BOOMR.addVar(
      {
        u: "https://portal.example.com/api/ok",
        "http.initiator": "xhr",
        "rt.tstart": 1_700_000_005_000,
      },
      true,
    )
    context.BOOMR.sendBeacon()
    context.BOOMR.real_sendBeacon()

    expect(sentPayloads).toHaveLength(2)
    expect(sentPayloads[1].u).toBe("https://portal.example.com/api/ok")
    expect(sentPayloads[1]["http.status_code"]).toBeUndefined()
    expect(sentPayloads[1]["c.lcp"]).toBeUndefined()
    expect(sentPayloads[1]["c.fcp"]).toBeUndefined()
    expect(sentPayloads[1]["c.inp"]).toBeUndefined()
    expect(sentPayloads[1]["c.e.rage"]).toBeUndefined()
    expect(sentPayloads[1].st).toBeUndefined()
    expect(sentPayloads[1].servertiming).toBeUndefined()

    // Exercise c.c.r -> c.e.rage mapping directly (Continuity clears c.c.r when 0 DOM rage clicks occurred)
    const directVars = {"c.c.r": 2}
    context.BOOMR.fireEvent("before_beacon", directVars)
    expect(directVars["c.e.rage"]).toBe(2)

    // Late config initialization when bundle executes before BOOMR_config.ServiceRadar
    const lateSetup = createVmContext({withConfig: false})
    vm.runInNewContext(`"use strict";\n${bundleSource}`, lateSetup.context, {
      filename: "boomerang-sr.min.js",
    })
    lateSetup.context.BOOMR_config = {
      ServiceRadar: {
        siteKey: "sr_rum_late_vm",
        beaconUrl: "/rum/v1/beacon",
        tracePropagateOrigins: ["https://api.example.com"],
        autorun: false,
      },
    }
    const domReadyHandlers = lateSetup.documentListeners.get("DOMContentLoaded") || []
    for (const fn of domReadyHandlers) fn()
    lateSetup.context.window.fetch("https://api.example.com/v1/late", {method: "GET"})
    expect(lateSetup.fetchCalls).toHaveLength(1)
    expect(lateSetup.fetchCalls[0].init.headers.traceparent).toMatch(
      /^00-[0-9a-f]{32}-[0-9a-f]{16}-01$/,
    )
  })
})

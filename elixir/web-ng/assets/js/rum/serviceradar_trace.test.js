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
import {buildBeaconUrl, initServiceRadarBoomerang} from "./boomerang_init.js"

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
  })

  test("built boomerang-sr.min.js executes cleanly in a VM context and normalizes CWV + trace vars", () => {
    const bundlePath = BUNDLE_CANDIDATES.find((p) => fs.existsSync(p))
    expect(bundlePath).toBeDefined()

    const bundleSource = fs.readFileSync(bundlePath, "utf8")
    expect(bundleSource).not.toContain("%boomerang_version%")
    expect(bundleSource).not.toContain("BEGIN_DEBUG")

    const beaconCalls = []
    const fetchCalls = []
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
        createElement: () => ({style: {}}),
        getElementsByTagName: () => [{parentNode: {insertBefore: () => {}}}],
        addEventListener: () => {},
        removeEventListener: () => {},
      },
      navigator: {
        sendBeacon: (url, body) => {
          beaconCalls.push({url, body})
          return true
        },
        userAgent: "ServiceRadarTest/1.0",
      },
      location: {
        href: "https://portal.example.com/overview",
        origin: "https://portal.example.com",
        protocol: "https:",
        hostname: "portal.example.com",
        pathname: "/overview",
        search: "",
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
      crypto: window.crypto,
      Headers: window.Headers,
      Request: window.Request,
      XMLHttpRequest: window.XMLHttpRequest,
      MutationObserver: window.MutationObserver,
      URL,
      URLSearchParams,
      Uint8Array,
      Math,
      Date,
      RegExp,
      Set,
      JSON,
      Object,
      Array,
      String,
      Number,
      Boolean,
      Error,
      Promise,
      console,
      setTimeout,
      clearTimeout,
      setInterval,
      clearInterval,
      addEventListener: () => {},
      removeEventListener: () => {},
      BOOMR_config: {
        ServiceRadar: {
          siteKey: "sr_rum_vm_test",
          beaconUrl: "/rum/v1/beacon",
          sampleRate: 1.0,
          tracePropagateOrigins: ["https://api.example.com"],
          autorun: false,
        },
      },
    }
    context.window = context
    context.self = context
    context.globalThis = context

    vm.runInNewContext(bundleSource, context, {filename: "boomerang-sr.min.js"})

    expect(context.BOOMR).toBeDefined()
    expect(context.BOOMR.version).toBe("1.815.1")
    expect(context.BOOMR.plugins.ServiceRadarTrace).toBeDefined()
    expect(context.BOOMR.plugins.RT).toBeDefined()
    expect(context.BOOMR.plugins.AutoXHR).toBeDefined()
    expect(context.BOOMR.plugins.Continuity).toBeDefined()
    expect(context.BOOMR.plugins.Errors).toBeDefined()

    // Trigger traceparent via fetch
    context.window.fetch("https://api.example.com/v1/checkout", {method: "GET"})
    expect(fetchCalls).toHaveLength(1)
    expect(fetchCalls[0].init.headers.traceparent).toMatch(/^00-[0-9a-f]{32}-[0-9a-f]{16}-01$/)

    // Exercise before_beacon normalization hook directly with native Boomerang vars
    const vars = {
      u: "https://portal.example.com/overview",
      "sr.key": "sr_rum_vm_test",
      "pt.lcp": 1850,
      "pt.fcp": 910,
      "et.inp": 132,
      "c.cls": 0.05,
      "c.c.r": 2,
      "http.errno": 503,
    }
    context.BOOMR.fireEvent("before_beacon", vars)

    expect(vars["c.lcp"]).toBe(1850)
    expect(vars["c.fcp"]).toBe(910)
    expect(vars["c.inp"]).toBe(132)
    expect(vars["c.e.rage"]).toBe(2)
    expect(vars["http.status_code"]).toBe(503)
    expect(vars.st).toContain('cdn-cache;dur=0;desc="HIT"')
    expect(vars.st).toContain("edge;dur=18")
    expect(vars.st).toContain("origin;dur=112")
    expect(vars.st).toContain('ak_p;dur=0;desc="iad"')
  })
})

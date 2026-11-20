// @vitest-environment happy-dom
import {afterEach, describe, expect, test, vi} from "vitest"
import {mountWebRum} from "../../js/dashboards/web_rum"
import {
  buildRumFrameQueries,
  deriveLatencyBreakdown,
  evaluateCwvThreshold,
  numericValue,
} from "../src/WebRumDashboard.jsx"
import sampleFrames from "../../../priv/dashboard-packages/web-rum/sample-frames.json"
import sampleSettings from "../../../priv/dashboard-packages/web-rum/sample-settings.json"
import {formatUserTime} from "../../js/utils/user_time"

async function flushUi(ticks = 6) {
  for (let i = 0; i < ticks; i += 1) {
    await new Promise((resolve) => setTimeout(resolve, 15))
  }
}

function createHostApi({
  frames = structuredClone(sampleFrames),
  settings = structuredClone(sampleSettings),
  capabilities = [
    "srql.execute",
    "dashboard.preferences.read",
    "dashboard.preferences.write",
    "navigation.open",
  ],
  initialTheme = "light",
  srqlUpdateImpl = null,
  refreshFramesImpl = null,
} = {}) {
  let theme = initialTheme
  const themeListeners = new Set()
  const frameListeners = new Set()
  const srqlUpdates = []
  const navigations = []
  const refreshes = []
  let currentFrames = frames

  const api = {
    theme: () => theme,
    isDarkMode: () => theme === "dark",
    frames: () => currentFrames,
    frame: (id) => currentFrames.find((f) => String(f?.id) === String(id)),
    capabilityAllowed: (cap) => capabilities.includes(String(cap)),
    srql: {
      query: (id) => currentFrames.find((f) => String(f?.id) === String(id))?.query || "",
      escapeValue: (val) => JSON.stringify(String(val ?? "")),
      update: (q, frameQueries) => {
        srqlUpdates.push({q, frameQueries})
        if (typeof srqlUpdateImpl === "function") {
          return srqlUpdateImpl(q, frameQueries)
        }
        return undefined
      },
    },
    navigate: (target) => {
      navigations.push(target)
    },
    refreshFrames: () => {
      refreshes.push(true)
      if (typeof refreshFramesImpl === "function") {
        return refreshFramesImpl()
      }
      return Promise.resolve({refreshed: true})
    },
    onFrameUpdate: (cb) => {
      frameListeners.add(cb)
      return () => frameListeners.delete(cb)
    },
    onThemeChange: (cb) => {
      themeListeners.add(cb)
      return () => themeListeners.delete(cb)
    },
  }

  const host = {
    instance: {
      route_slug: "web-rum",
      settings,
    },
    package: {
      dashboard_id: "cloud.serviceradar.web-rum",
      capabilities,
      frames: currentFrames,
    },
  }

  return {
    host,
    api,
    srqlUpdates,
    navigations,
    refreshes,
    setTheme(nextTheme) {
      theme = nextTheme
      for (const cb of [...themeListeners]) cb(nextTheme)
    },
    pushFrames(nextFrames) {
      currentFrames = nextFrames
      host.package.frames = nextFrames
      for (const cb of [...frameListeners]) cb({frames: nextFrames})
    },
  }
}

const activeMounts = []

function createMountRoot(timezone = "America/Chicago") {
  const root = document.createElement("div")
  root.dataset.timezone = timezone
  document.body.appendChild(root)
  return root
}

afterEach(() => {
  while (activeMounts.length > 0) {
    const {mounted, root} = activeMounts.pop()
    mounted?.destroy?.()
    root?.remove()
  }
  document.body.innerHTML = ""
})

describe("cloud.serviceradar.web-rum Blueprint dashboard", () => {
  test("evaluates CWV thresholds and derives Edge/Origin/Browser Render split safely", () => {
    expect(evaluateCwvThreshold(2180, 2500, 4000)).toEqual({label: "Good", intent: "success"})
    expect(evaluateCwvThreshold(3200, 2500, 4000)).toEqual({
      label: "Needs Improvement",
      intent: "warning",
    })
    expect(evaluateCwvThreshold(4350, 2500, 4000)).toEqual({label: "Poor", intent: "danger"})
    expect(evaluateCwvThreshold(null, 2500, 4000)).toEqual({label: "No Data", intent: "none"})

    expect(numericValue("   ")).toBeNull()
    expect(numericValue(false)).toBeNull()
    expect(numericValue([])).toBeNull()

    expect(
      deriveLatencyBreakdown({
        p75_edge_rtt_ms: 28,
        p75_origin_rtt_ms: 245,
        p75_ttfb_ms: 310,
        p75_page_load_ms: 2480,
      }),
    ).toEqual({
      edgeRttMs: 28,
      originRttMs: 245,
      ttfbMs: 310,
      browserRenderMs: 2170,
      totalMs: 2480,
    })

    expect(
      deriveLatencyBreakdown({
        p75_edge_rtt_ms: 28,
        p75_origin_rtt_ms: 245,
        p75_ttfb_ms: null,
        p75_page_load_ms: 2480,
      }),
    ).toEqual({
      edgeRttMs: 28,
      originRttMs: 245,
      ttfbMs: null,
      browserRenderMs: null,
      totalMs: 2480,
    })

    // Build scalar-only stats queries (no bucket:, no :(...) list filters)
    const built = buildRumFrameQueries({
      timeWindow: "last_6h",
      webPropertyId: "01J00000000000000000000001",
      prefixTag: "branch-east",
    })
    expect(built.primary).toContain("in:rum time:last_6h")
    expect(built.primary).toContain('web_property_id:"01J00000000000000000000001"')
    expect(built.primary).toContain('prefix_tag:"branch-east"')
    expect(built.frames.rum_latency_breakdown).toContain("by time:1h")
    expect(built.frames.rum_latency_breakdown).not.toContain("bucket:")
  })

  test("renders CWV p75 cards, Edge/Origin/Browser Render breakdown, Akamai CDN table, and branch ASNs", async () => {
    const root = createMountRoot("America/Chicago")
    const {host, api} = createHostApi()

    const mounted = await mountWebRum(root, host, api)
    activeMounts.push({mounted, root})
    await flushUi()

    expect(root.querySelector(".sr-dashboard-blueprint")).not.toBeNull()
    expect(root.querySelector("style[data-sr-blueprint-sdk='true']")).not.toBeNull()
    expect(document.head.querySelector("style[data-sr-blueprint-sdk='true']")).toBeNull()

    const text = root.textContent || ""
    expect(text).toContain("Web RUM")
    expect(text).toContain("LCP (p75)")
    expect(text).toContain("2.18 s")
    expect(text).toContain("INP (p75)")
    expect(text).toContain("145 ms")
    expect(text).toContain("CLS (p75)")
    expect(text).toContain("0.08")
    expect(text).toContain("Edge vs Origin RTT vs Browser Render (p75)")
    expect(text).toContain("Akamai CDN Cache Status")
    expect(text).toContain("branch-east")
    expect(text).toContain("Example Branch ISP A")
    expect(text).toContain("AS64512")
    expect(text).toContain("https://portal.example.com")
    expect(text).toContain("/cart/:id")

    // Timestamps rendered via user_time.js in America/Chicago
    const timeEls = root.querySelectorAll("time[data-user-time-zone='America/Chicago']")
    expect(timeEls.length).toBeGreaterThan(0)
    for (const timeEl of timeEls) {
      expect(timeEl.textContent?.trim().length).toBeGreaterThan(0)
    }
    const expectedTime = formatUserTime("2026-11-18T03:58:00Z", {
      timeZone: "America/Chicago",
      style: "compact",
    })
    expect(expectedTime?.text).toBeTruthy()
    expect(Array.from(timeEls).some((el) => el.textContent === expectedTime.text)).toBe(true)
  })

  test("syncs .bp6-dark theme and cleans up on destroy()", async () => {
    const root = createMountRoot()
    const {host, api, setTheme} = createHostApi({initialTheme: "dark"})

    const mounted = await mountWebRum(root, host, api)
    activeMounts.push({mounted, root})
    await flushUi()

    const bpRoot = root.querySelector(".sr-dashboard-blueprint")
    expect(bpRoot?.classList.contains("bp6-dark")).toBe(true)

    setTheme("light")
    await flushUi()
    expect(bpRoot?.classList.contains("bp6-dark")).toBe(false)

    mounted.destroy()
    expect(root.querySelector(".sr-dashboard-blueprint")).toBeNull()
    expect(root.querySelector("style[data-sr-blueprint-sdk='true']")).toBeNull()
  })

  test("filters by Web Property Select (portal-scoped), prefix_tag, and errors, firing scalar srql.update", async () => {
    const root = createMountRoot()
    const {host, api, srqlUpdates} = createHostApi()

    const mounted = await mountWebRum(root, host, api)
    activeMounts.push({mounted, root})
    await flushUi()

    const selectTrigger = Array.from(root.querySelectorAll("button")).find((btn) =>
      btn.textContent?.includes("All Web Properties"),
    )
    expect(selectTrigger).toBeDefined()
    selectTrigger.click()
    await flushUi()

    const portalRoot = root.querySelector(".sr-dashboard-blueprint [data-sr-blueprint-portals='true']")
    expect(portalRoot).not.toBeNull()
    const leaked = Array.from(document.body.children).filter((el) => el !== root)
    expect(leaked).toHaveLength(0)

    const checkoutOption = Array.from(portalRoot.querySelectorAll(".bp6-menu-item")).find((el) =>
      el.textContent?.includes("Example Checkout App"),
    )
    expect(checkoutOption).toBeDefined()
    checkoutOption.click()
    await flushUi()

    expect(srqlUpdates).toHaveLength(1)
    expect(srqlUpdates[0].q).toContain('web_property_id:"01J00000000000000000000002"')
    expect(srqlUpdates[0].frameQueries.rum_recent_beacons).toContain(
      'web_property_id:"01J00000000000000000000002"',
    )

    // Toggle Errors Only
    const errorsOnlyBtn = Array.from(root.querySelectorAll("button")).find(
      (btn) => btn.textContent === "Errors Only",
    )
    expect(errorsOnlyBtn).toBeDefined()
    errorsOnlyBtn.click()
    await flushUi()

    const text = root.textContent || ""
    expect(text).toContain("/cart/:id")
    expect(text).not.toContain("https://portal.example.com/overview")
  })

  test("opens portal-scoped Drawer on beacon click and links trace_id and web_property_id", async () => {
    const root = createMountRoot()
    const {host, api, navigations} = createHostApi()

    const mounted = await mountWebRum(root, host, api)
    activeMounts.push({mounted, root})
    await flushUi()

    const errorBeaconRow = Array.from(root.querySelectorAll("tbody tr")).find((tr) =>
      tr.textContent?.includes("HTTP 502"),
    )
    expect(errorBeaconRow).toBeDefined()
    errorBeaconRow.click()
    await flushUi()

    const portalRoot = root.querySelector(".sr-dashboard-blueprint [data-sr-blueprint-portals='true']")
    const drawer = portalRoot?.querySelector(".bp6-drawer")
    expect(drawer).not.toBeNull()
    expect(document.body.querySelectorAll(":scope > .bp6-portal")).toHaveLength(0)

    expect(drawer?.textContent).toContain("Beacon Recorded User Friction or Errors")
    expect(drawer?.textContent).toContain("HTTP Status: 502")
    expect(drawer?.textContent).toContain("Timing Waterfall")
    expect(drawer?.textContent).toContain("198.51.100.0")

    const drawerTime = drawer?.querySelector("time[data-user-time-style='full']")
    expect(drawerTime?.textContent?.trim().length).toBeGreaterThan(0)

    const progressBar = drawer?.querySelector(".bp6-progress-bar")
    expect(progressBar).not.toBeNull()
    expect(progressBar?.classList.contains("bp6-intent-danger")).toBe(true)

    const traceBtn = Array.from(drawer.querySelectorAll("button")).find((btn) =>
      btn.textContent?.includes("Inspect Backend Trace"),
    )
    expect(traceBtn).toBeDefined()
    traceBtn.click()
    expect(navigations).toContain("/observability/traces/0000000000000000000000000000c3d4")

    const websiteBtn = Array.from(drawer.querySelectorAll("button")).find((btn) =>
      btn.textContent?.includes("Open Website"),
    )
    expect(websiteBtn).toBeDefined()
    websiteBtn.click()
    expect(navigations).toContain("/websites/01J00000000000000000000002")
  })

  test("degrades gracefully without srql.execute and guards rejections", async () => {
    const root = createMountRoot()
    const {host, api, srqlUpdates} = createHostApi({
      capabilities: ["navigation.open"],
      srqlUpdateImpl: () => Promise.reject(new Error("denied")),
      refreshFramesImpl: () => Promise.reject(new Error("offline")),
    })

    const mounted = await mountWebRum(root, host, api)
    activeMounts.push({mounted, root})
    await flushUi()

    const windowBtn = Array.from(root.querySelectorAll("button")).find((btn) => btn.textContent === "6h")
    expect(windowBtn).toBeDefined()
    windowBtn.click()
    await flushUi()
    expect(srqlUpdates).toHaveLength(0)

    const refreshBtn = Array.from(root.querySelectorAll("button")).find((btn) => btn.textContent === "Refresh")
    refreshBtn.click()
    await flushUi()
    expect(root.querySelector(".sr-dashboard-blueprint")).not.toBeNull()
  })

  test("clears cached recent beacons when a completed query returns zero rows", async () => {
    const root = createMountRoot()
    const {host, api, pushFrames} = createHostApi()

    const mounted = await mountWebRum(root, host, api)
    activeMounts.push({mounted, root})
    await flushUi()

    expect(root.textContent).toContain("/cart/:id")

    // During loading, previous rows remain visible
    const loadingFrames = structuredClone(sampleFrames).map((frame) =>
      frame.id === "rum_recent_beacons" ? {...frame, status: "loading", results: []} : frame,
    )
    pushFrames(loadingFrames)
    await flushUi()
    expect(root.textContent).toContain("/cart/:id")

    // Once status is no longer loading (e.g. "ok" with 0 rows), stale cache is cleared
    const emptyOkFrames = structuredClone(sampleFrames).map((frame) =>
      frame.id === "rum_recent_beacons" ? {...frame, status: "ok", results: []} : frame,
    )
    pushFrames(emptyOkFrames)
    await flushUi()
    expect(root.textContent).toContain("No matching RUM beacons")
  })

  test("clears cached CWV summary when a completed query returns zero rows", async () => {
    const root = createMountRoot()
    const {host, api, pushFrames} = createHostApi()

    const mounted = await mountWebRum(root, host, api)
    activeMounts.push({mounted, root})
    await flushUi()

    expect(root.textContent).toContain("2.18 s")

    // During loading, previous CWV summary remains visible
    const loadingFrames = structuredClone(sampleFrames).map((frame) =>
      frame.id === "rum_cwv_summary" ? {...frame, status: "loading", results: []} : frame,
    )
    pushFrames(loadingFrames)
    await flushUi()
    expect(root.textContent).toContain("2.18 s")

    // Once status is no longer loading (e.g. "ok" with 0 rows), stale CWV cache is cleared
    const emptyOkFrames = structuredClone(sampleFrames).map((frame) =>
      frame.id === "rum_cwv_summary" ? {...frame, status: "ok", results: []} : frame,
    )
    pushFrames(emptyOkFrames)
    await flushUi()
    expect(root.textContent).not.toContain("2.18 s")
    expect(root.textContent).toContain("No Data")
  })
})

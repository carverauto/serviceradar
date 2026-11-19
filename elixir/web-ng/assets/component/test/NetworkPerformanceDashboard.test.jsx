// @vitest-environment happy-dom
import {afterEach, describe, expect, test, vi} from "vitest"
import {mountNetworkPerformance} from "../../js/dashboards/network_performance"
import {parseTags} from "../src/NetworkPerformanceDashboard.jsx"
import sampleFrames from "../../../priv/dashboard-packages/network-performance/sample-frames.json"
import sampleSettings from "../../../priv/dashboard-packages/network-performance/sample-settings.json"

async function flushUi(ticks = 6) {
  for (let i = 0; i < ticks; i += 1) {
    await new Promise((resolve) => setTimeout(resolve, 15))
  }
}

function createHostApi({
  frames = structuredClone(sampleFrames),
  settings = structuredClone(sampleSettings),
  capabilities = ["srql.execute", "dashboard.preferences.read", "dashboard.preferences.write", "navigation.open"],
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
      route_slug: "network-performance",
      settings,
    },
    package: {
      dashboard_id: "cloud.serviceradar.network-performance",
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

describe("cloud.serviceradar.network-performance Blueprint dashboard", () => {
  test("parses both object and stringified JSON tags defensively", () => {
    expect(parseTags({responder_agent_id: "hub-1"})).toEqual({responder_agent_id: "hub-1"})
    expect(parseTags('{"responder_agent_id":"hub-2","protocol":"udp"}')).toEqual({
      responder_agent_id: "hub-2",
      protocol: "udp",
    })
    expect(parseTags("not-json")).toEqual({})
    expect(parseTags(null)).toEqual({})
    expect(parseTags(["not-an-object"])).toEqual({})
  })

  test("renders KPI strip, Hub Responder cards, callouts, and spoke links from synthetic fixtures", async () => {
    const root = createMountRoot("America/Chicago")
    const {host, api} = createHostApi()

    const mounted = await mountNetworkPerformance(root, host, api)
    activeMounts.push({mounted, root})
    await flushUi()

    expect(root.querySelector(".sr-dashboard-blueprint")).not.toBeNull()
    expect(root.querySelector("style[data-sr-blueprint-sdk='true']")).not.toBeNull()
    expect(document.head.querySelector("style[data-sr-blueprint-sdk='true']")).toBeNull()

    const text = root.textContent || ""
    expect(text).toContain("Network Performance (Hub & Spoke)")
    expect(text).toContain("Active Hub Responders")
    expect(text).toContain("Branch 01 Spoke")
    expect(text).toContain("Branch 02 Spoke")
    expect(text).toContain("Legacy 01 Spoke")
    expect(text).toContain("(legacy target)")
    expect(text).toContain("Degraded Spoke Links & Hub Responder Saturation")
    expect(text).toContain("Packet Loss or UDP Jitter Threshold Exceeded")

    // Timestamps formatted via user_time.js in America/Chicago
    const timeEls = root.querySelectorAll("time[data-user-time-zone='America/Chicago']")
    expect(timeEls.length).toBeGreaterThan(0)
  })

  test("syncs .bp6-dark with host theme and cleans up scoped nodes on destroy()", async () => {
    const root = createMountRoot()
    const {host, api, setTheme} = createHostApi({initialTheme: "dark"})

    const mounted = await mountNetworkPerformance(root, host, api)
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

  test("filters by direction, protocol, Hub Responder Select (portal-scoped), and search", async () => {
    const root = createMountRoot()
    const {host, api} = createHostApi()

    const mounted = await mountNetworkPerformance(root, host, api)
    activeMounts.push({mounted, root})
    await flushUi()

    // Filter by UDP protocol
    const udpBtn = Array.from(root.querySelectorAll("button")).find((btn) => btn.textContent === "UDP")
    expect(udpBtn).toBeDefined()
    udpBtn.click()
    await flushUi()

    let bodyText = root.querySelector("tbody")?.textContent || ""
    expect(bodyText).toContain("Branch 02 Spoke")
    expect(bodyText).not.toContain("Legacy 01 Spoke")

    // Reset protocol to All Proto
    const allProtoBtn = Array.from(root.querySelectorAll("button")).find((btn) => btn.textContent === "All Proto")
    allProtoBtn.click()
    await flushUi()

    // Open Hub Responder Select and verify portal containment inside .sr-dashboard-blueprint
    const selectTrigger = Array.from(root.querySelectorAll("button")).find((btn) =>
      btn.textContent?.includes("All Hub Responders"),
    )
    expect(selectTrigger).toBeDefined()
    selectTrigger.click()
    await flushUi()

    const portalRoot = root.querySelector(".sr-dashboard-blueprint [data-sr-blueprint-portals='true']")
    expect(portalRoot).not.toBeNull()
    expect(portalRoot?.textContent).toContain("Hub East 01")
    // Ensure popover did not leak directly to document.body outside mount root
    const leakedPopovers = Array.from(document.body.children).filter((el) => el !== root)
    expect(leakedPopovers).toHaveLength(0)

    const hubEastItem = Array.from(portalRoot.querySelectorAll(".bp6-menu-item")).find(
      (el) => el.textContent?.trim() === "Hub East 01",
    )
    expect(hubEastItem).toBeDefined()
    hubEastItem.click()
    await flushUi()

    bodyText = root.querySelector("tbody")?.textContent || ""
    expect(bodyText).toContain("Branch 01 Spoke")
    expect(bodyText).not.toContain("Branch 02 Spoke")

    // Filter by search yielding empty state
    const searchInput = root.querySelector("input[placeholder*='Search spoke']")
    expect(searchInput).not.toBeNull()
    const nativeSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value").set
    nativeSetter.call(searchInput, "nonexistent-spoke-999")
    searchInput.dispatchEvent(new Event("input", {bubbles: true}))
    searchInput.dispatchEvent(new Event("change", {bubbles: true}))
    await new Promise((resolve) => setTimeout(resolve, 220))
    await flushUi()

    expect(root.textContent).toContain("No matching spoke-to-hub links")
  })

  test("opens portal-scoped Drawer on row click, fires srql.update, renders sparklines, and navigates", async () => {
    const root = createMountRoot()
    const {host, api, srqlUpdates, navigations} = createHostApi()

    const mounted = await mountNetworkPerformance(root, host, api)
    activeMounts.push({mounted, root})
    await flushUi()

    const branch01Row = Array.from(root.querySelectorAll("tbody tr")).find((tr) =>
      tr.textContent?.includes("Branch 01 Spoke"),
    )
    expect(branch01Row).toBeDefined()
    branch01Row.click()
    await flushUi()

    expect(srqlUpdates).toHaveLength(1)
    expect(srqlUpdates[0].frameQueries.spoke_history).toContain("agent_id:agent-spoke-branch-01")

    const portalRoot = root.querySelector(".sr-dashboard-blueprint [data-sr-blueprint-portals='true']")
    const drawer = portalRoot?.querySelector(".bp6-drawer")
    expect(drawer).not.toBeNull()
    expect(document.body.querySelectorAll(":scope > .bp6-portal")).toHaveLength(0)

    expect(drawer?.textContent).toContain("Throughput (bps)")
    expect(drawer?.textContent).toContain("Packet Loss (%)")
    expect(drawer?.textContent).toContain("UDP Jitter (ms)")
    expect(drawer?.querySelectorAll("svg polyline").length).toBeGreaterThanOrEqual(1)

    const settingsBtn = Array.from(drawer.querySelectorAll("button")).find((btn) =>
      btn.textContent?.includes("Open Netperf Settings"),
    )
    expect(settingsBtn).toBeDefined()
    settingsBtn.click()
    expect(navigations).toContain("/settings/networks/netperf")

    const deviceBtn = Array.from(drawer.querySelectorAll("button")).find((btn) =>
      btn.textContent?.includes("Inspect Spoke Device"),
    )
    expect(deviceBtn).toBeDefined()
    deviceBtn.click()
    expect(navigations).toContainEqual({type: "device", uid: "sr:device-spoke-01"})
  })

  test("degrades gracefully for read-only viewers without srql.execute and reacts to live frame updates", async () => {
    const root = createMountRoot()
    const {host, api, srqlUpdates, pushFrames} = createHostApi({
      capabilities: ["navigation.open"],
    })

    const mounted = await mountNetworkPerformance(root, host, api)
    activeMounts.push({mounted, root})
    await flushUi()

    // Click Branch 02 row -> opens Drawer without calling srql.update
    const branch02Row = Array.from(root.querySelectorAll("tbody tr")).find((tr) =>
      tr.textContent?.includes("Branch 02 Spoke"),
    )
    branch02Row.click()
    await flushUi()

    expect(srqlUpdates).toHaveLength(0)
    const portalRoot = root.querySelector(".sr-dashboard-blueprint [data-sr-blueprint-portals='true']")
    const drawer = portalRoot?.querySelector(".bp6-drawer")
    expect(drawer).not.toBeNull()
    expect(drawer?.querySelectorAll("svg polyline").length).toBeGreaterThanOrEqual(1)

    // Live frame update adds a new spoke (server bumps refreshed_at / row_count)
    const updatedFrames = structuredClone(sampleFrames)
    updatedFrames[0].results.unshift({
      timestamp: "2026-11-18T04:05:00Z",
      agent_id: "agent-spoke-branch-03",
      uid: "sr:device-spoke-03",
      metric_name: "rperf.bits_per_second",
      value: 880000000,
      target_device_ip: "192.0.2.99",
      tags: {
        responder_agent_id: "agent-hub-east-01",
        direction: "upload",
        protocol: "tcp",
      },
    })
    updatedFrames[0].refreshed_at = "2026-11-18T04:05:00Z"
    updatedFrames[0].row_count = updatedFrames[0].results.length
    pushFrames(updatedFrames)
    await flushUi()

    expect(root.querySelector("tbody")?.textContent).toContain("agent-spoke-branch-03")
  })

  test("sorts spoke-to-hub rows by Packet Loss and Throughput headers", async () => {
    const root = createMountRoot()
    const {host, api} = createHostApi()

    const mounted = await mountNetworkPerformance(root, host, api)
    activeMounts.push({mounted, root})
    await flushUi()

    // Default sort is throughputBps desc -> Branch 01 Spoke (942 Mbps) is first
    let firstRowText = root.querySelector("tbody tr")?.textContent || ""
    expect(firstRowText).toContain("Branch 01 Spoke")

    // Click Packet Loss header -> sorts lossPct desc -> Branch 02 Spoke (2.4%) is first
    const lossSortBtn = Array.from(root.querySelectorAll("thead button")).find((btn) =>
      btn.textContent?.includes("Packet Loss"),
    )
    expect(lossSortBtn).toBeDefined()
    lossSortBtn.click()
    await flushUi()

    firstRowText = root.querySelector("tbody tr")?.textContent || ""
    expect(firstRowText).toContain("Branch 02 Spoke")
  })

  test("propagates root.dataset.timezone without host.instance.timezone and defaults to Etc/UTC when unset", async () => {
    const rootWithTz = createMountRoot("America/Chicago")
    const {host: host1, api: api1} = createHostApi()
    expect(host1.instance.timezone).toBeUndefined()

    const mounted1 = await mountNetworkPerformance(rootWithTz, host1, api1)
    activeMounts.push({mounted: mounted1, root: rootWithTz})
    await flushUi()

    expect(rootWithTz.querySelectorAll("time[data-user-time-zone='America/Chicago']").length).toBeGreaterThan(0)
    expect(rootWithTz.querySelectorAll("time[data-user-time-zone='Etc/UTC']").length).toBe(0)

    const rootNoTz = document.createElement("div")
    document.body.appendChild(rootNoTz)
    const {host: host2, api: api2} = createHostApi()
    const mounted2 = await mountNetworkPerformance(rootNoTz, host2, api2)
    activeMounts.push({mounted: mounted2, root: rootNoTz})
    await flushUi()

    expect(rootNoTz.querySelectorAll("time[data-user-time-zone='Etc/UTC']").length).toBeGreaterThan(0)
  })

  test("applies direction and protocol filters before collapsing multi-policy links", async () => {
    const root = createMountRoot()
    const {host, api} = createHostApi()

    const mounted = await mountNetworkPerformance(root, host, api)
    activeMounts.push({mounted, root})
    await flushUi()

    // Initially All Dir / All Proto -> Branch 01 Spoke shows newest TCP upload (942 Mbps / 1.4 ms)
    const branch01All = Array.from(root.querySelectorAll("tbody tr")).find((tr) =>
      tr.textContent?.includes("Branch 01 Spoke"),
    )
    expect(branch01All?.textContent).toContain("942 Mbps")
    expect(branch01All?.textContent).toContain("1.4 ms")

    // Select UDP -> Branch 01 Spoke must show UDP sample (415 Mbps / 3.2 ms), NOT 942 Mbps / 1.4 ms
    const udpBtn = Array.from(root.querySelectorAll("button")).find((btn) => btn.textContent === "UDP")
    udpBtn.click()
    await flushUi()

    const branch01Udp = Array.from(root.querySelectorAll("tbody tr")).find((tr) =>
      tr.textContent?.includes("Branch 01 Spoke"),
    )
    expect(branch01Udp).toBeDefined()
    expect(branch01Udp?.textContent).toContain("415 Mbps")
    expect(branch01Udp?.textContent).toContain("3.2 ms")
    expect(branch01Udp?.textContent).not.toContain("942 Mbps")
    expect(branch01Udp?.textContent).not.toContain("1.4 ms")

    // Reset to All Proto and select Download -> Branch 01 Spoke must also show 415 Mbps / 3.2 ms
    const allProtoBtn = Array.from(root.querySelectorAll("button")).find((btn) => btn.textContent === "All Proto")
    allProtoBtn.click()
    const downloadBtn = Array.from(root.querySelectorAll("button")).find((btn) => btn.textContent === "Download")
    downloadBtn.click()
    await flushUi()

    const branch01Down = Array.from(root.querySelectorAll("tbody tr")).find((tr) =>
      tr.textContent?.includes("Branch 01 Spoke"),
    )
    expect(branch01Down).toBeDefined()
    expect(branch01Down?.textContent).toContain("415 Mbps")
    expect(branch01Down?.textContent).toContain("3.2 ms")
    expect(branch01Down?.textContent).not.toContain("942 Mbps")
  })

  test("keeps Drawer open and table populated when frames transition to pending loading state", async () => {
    const root = createMountRoot()
    const {host, api, pushFrames} = createHostApi()

    const mounted = await mountNetworkPerformance(root, host, api)
    activeMounts.push({mounted, root})
    await flushUi()

    const branch01Row = Array.from(root.querySelectorAll("tbody tr")).find((tr) =>
      tr.textContent?.includes("Branch 01 Spoke"),
    )
    branch01Row.click()
    await flushUi()

    const portalRoot = root.querySelector(".sr-dashboard-blueprint [data-sr-blueprint-portals='true']")
    expect(portalRoot?.querySelector(".bp6-drawer")).not.toBeNull()

    // Simulate pending_frames with empty results & status: "loading"
    pushFrames([
      {id: "netperf_recent_samples", status: "loading", results: []},
      {id: "netperf_metric_trends", status: "loading", results: []},
      {id: "netperf_spoke_summary", status: "loading", results: []},
      {id: "spoke_history", status: "loading", results: []},
    ])
    await flushUi()

    expect(portalRoot?.querySelector(".bp6-drawer")).not.toBeNull()
    expect(root.querySelector("tbody")?.textContent).toContain("Branch 01 Spoke")
  })

  test("guards srql.update rejections/sync throws and api.refreshFrames() rejections cleanly", async () => {
    const unhandled = []
    const onUnhandled = (reason) => unhandled.push(reason)
    process.on("unhandledRejection", onUnhandled)

    try {
      const rootAsync = createMountRoot()
      const asyncSetup = createHostApi({
        srqlUpdateImpl: () => Promise.reject(new Error("SRQL forbidden")),
        refreshFramesImpl: () => Promise.reject(new Error("channel not_connected")),
      })

      const mountedAsync = await mountNetworkPerformance(rootAsync, asyncSetup.host, asyncSetup.api)
      activeMounts.push({mounted: mountedAsync, root: rootAsync})
      await flushUi()

      const refreshBtn = Array.from(rootAsync.querySelectorAll("button")).find(
        (btn) => btn.textContent === "Refresh",
      )
      expect(refreshBtn).toBeDefined()
      refreshBtn.click()

      const rowAsync = rootAsync.querySelector("tbody tr")
      rowAsync.click()
      await flushUi()

      expect(rootAsync.querySelector(".bp6-drawer")).not.toBeNull()
      expect(unhandled).toHaveLength(0)

      // Synchronous throw from srql.update must not crash click handler
      const rootSync = createMountRoot()
      const syncSetup = createHostApi({
        srqlUpdateImpl: () => {
          throw new Error("SRQL sync explosion")
        },
      })
      const mountedSync = await mountNetworkPerformance(rootSync, syncSetup.host, syncSetup.api)
      activeMounts.push({mounted: mountedSync, root: rootSync})
      await flushUi()

      const rowSync = rootSync.querySelector("tbody tr")
      expect(() => rowSync.click()).not.toThrow()
      await flushUi()
      expect(rootSync.querySelector(".bp6-drawer")).not.toBeNull()
      expect(unhandled).toHaveLength(0)
    } finally {
      process.off("unhandledRejection", onUnhandled)
    }
  })

  test("treats whitespace, booleans, and arrays in numericValue as missing ('—') and avoids misleading Uplink label", async () => {
    const root = createMountRoot()
    const frames = [
      {
        id: "netperf_recent_samples",
        status: "ok",
        results: [
          {
            timestamp: "2026-11-18T03:55:00Z",
            agent_id: "agent-spoke-blank",
            metric_name: "rperf.bits_per_second",
            value: "   ",
            target_device_ip: "192.0.2.77",
            tags: {responder_agent_id: "agent-hub-east-01", direction: "download", protocol: "tcp"},
          },
          {
            timestamp: "2026-11-18T03:55:00Z",
            agent_id: "agent-spoke-blank",
            metric_name: "rperf.loss_percent",
            value: false,
            target_device_ip: "192.0.2.77",
            tags: {responder_agent_id: "agent-hub-east-01", direction: "download", protocol: "tcp"},
          },
          {
            timestamp: "2026-11-18T03:55:00Z",
            agent_id: "agent-spoke-blank",
            metric_name: "rperf.jitter_ms",
            value: [],
            target_device_ip: "192.0.2.77",
            tags: {responder_agent_id: "agent-hub-east-01", direction: "download", protocol: "tcp"},
          },
          {
            timestamp: "2026-11-18T03:55:00Z",
            agent_id: "agent-spoke-down-only",
            metric_name: "rperf.bits_per_second",
            value: 320000000,
            target_device_ip: "192.0.2.78",
            tags: {responder_agent_id: "agent-hub-east-01", direction: "download", protocol: "tcp"},
          },
        ],
      },
      {id: "netperf_metric_trends", status: "ok", results: []},
      {id: "netperf_spoke_summary", status: "ok", results: []},
      {id: "netperf_responder_capacity", status: "ok", results: []},
      {id: "netperf_agents", status: "ok", results: []},
      {id: "spoke_history", status: "ok", results: []},
    ]
    const {host, api} = createHostApi({frames})

    const mounted = await mountNetworkPerformance(root, host, api)
    activeMounts.push({mounted, root})
    await flushUi()

    const blankRow = Array.from(root.querySelectorAll("tbody tr")).find((tr) =>
      tr.textContent?.includes("agent-spoke-blank"),
    )
    expect(blankRow).toBeDefined()
    expect(blankRow?.textContent).not.toContain("0 bps")
    expect(blankRow?.textContent).not.toContain("0%")
    expect(blankRow?.textContent).not.toContain("0 ms")

    // When there are zero upload samples, KPI must not label the median as "Uplink median"
    expect(root.textContent).not.toContain("Uplink median")
    expect(root.textContent).toContain("Median throughput")
  })

  test("computes Fleet Median Throughput from each link's latest upload and download rate", async () => {
    const root = createMountRoot()
    const sample = (agentId, ts, direction, value) => ({
      timestamp: ts,
      agent_id: agentId,
      metric_name: "rperf.bits_per_second",
      value,
      target_device_ip: "192.0.2.10",
      tags: {responder_agent_id: "agent-hub-east-01", direction, protocol: "tcp"},
    })
    const frames = [
      {
        id: "netperf_recent_samples",
        status: "ok",
        results: [
          sample("agent-spoke-chatty", "2026-11-18T03:00:00Z", "upload", 1_000_000),
          sample("agent-spoke-chatty", "2026-11-18T03:10:00Z", "upload", 1_000_000),
          sample("agent-spoke-chatty", "2026-11-18T03:20:00Z", "upload", 100_000_000),
          sample("agent-spoke-chatty", "2026-11-18T03:00:00Z", "download", 5_000_000),
          sample("agent-spoke-chatty", "2026-11-18T03:10:00Z", "download", 5_000_000),
          sample("agent-spoke-chatty", "2026-11-18T03:20:00Z", "download", 200_000_000),
          sample("agent-spoke-quiet", "2026-11-18T03:20:00Z", "upload", 100_000_000),
          sample("agent-spoke-quiet", "2026-11-18T03:20:00Z", "download", 200_000_000),
        ],
      },
      {id: "netperf_metric_trends", status: "ok", results: []},
      {id: "netperf_spoke_summary", status: "ok", results: []},
      {id: "netperf_responder_capacity", status: "ok", results: []},
      {id: "netperf_agents", status: "ok", results: []},
      {id: "spoke_history", status: "ok", results: []},
    ]
    const {host, api} = createHostApi({frames})

    const mounted = await mountNetworkPerformance(root, host, api)
    activeMounts.push({mounted, root})
    await flushUi()

    const card = Array.from(root.querySelectorAll(".sr-netperf-kpi-card")).find((el) =>
      el.textContent?.includes("Fleet Median Throughput"),
    )
    expect(card).toBeDefined()
    expect(card.querySelector(".sr-netperf-kpi-value")?.textContent).toMatch(/^100(\.0+)? Mbps$/)
    expect(card.textContent).toContain("Uplink median")
    expect(card.querySelector(".sr-netperf-kpi-meta")?.textContent).toMatch(/Downlink 200(\.0+)? Mbps/)
  })

  test("uses recentSamples for Legacy 01 Spoke drawerHistory before fleet-wide metricTrends fallback", async () => {
    const root = createMountRoot()
    const {host, api} = createHostApi()

    const mounted = await mountNetworkPerformance(root, host, api)
    activeMounts.push({mounted, root})
    await flushUi()

    const legacyRow = Array.from(root.querySelectorAll("tbody tr")).find((tr) =>
      tr.textContent?.includes("Legacy 01 Spoke"),
    )
    expect(legacyRow).toBeDefined()
    legacyRow.click()
    await flushUi()

    const portalRoot = root.querySelector(".sr-dashboard-blueprint [data-sr-blueprint-portals='true']")
    const drawerText = portalRoot?.querySelector(".bp6-drawer")?.textContent || ""
    expect(drawerText).toContain("284,000,000")
    expect(drawerText).not.toContain("510,000,000")
    expect(drawerText).not.toContain("530,000,000")
    expect(drawerText).not.toContain("Fleet-wide fallback")
  })

  test("uses the grouped samples for drawer history when a row has no agent id", async () => {
    const root = createMountRoot()
    const frames = structuredClone(sampleFrames)
    frames[0].results = [
      {
        timestamp: "2026-11-18T03:50:00Z",
        metric_name: "rperf.bits_per_second",
        value: 123000000,
        target_device_ip: "192.0.2.90",
        tags: {responder_agent_id: "agent-hub-east-01", direction: "download", protocol: "tcp"},
      },
      {
        timestamp: "2026-11-18T03:55:00Z",
        metric_name: "rperf.bits_per_second",
        value: 124000000,
        target_device_ip: "192.0.2.90",
        tags: {responder_agent_id: "agent-hub-east-01", direction: "download", protocol: "tcp"},
      },
    ]
    frames[5].results = []
    const {host, api} = createHostApi({frames})

    const mounted = await mountNetworkPerformance(root, host, api)
    activeMounts.push({mounted, root})
    await flushUi()

    const unknownRow = Array.from(root.querySelectorAll("tbody tr")).find((tr) =>
      tr.textContent?.includes("unknown-spoke"),
    )
    expect(unknownRow).toBeDefined()
    unknownRow.click()
    await flushUi()

    const portalRoot = root.querySelector(".sr-dashboard-blueprint [data-sr-blueprint-portals='true']")
    const drawerText = portalRoot?.querySelector(".bp6-drawer")?.textContent || ""
    expect(drawerText).toContain("124,000,000")
    expect(drawerText).not.toContain("Fleet-wide fallback")
  })

  test("labels fleet-wide metricTrends fallback clearly when spoke has no per-spoke history", async () => {
    const root = createMountRoot()
    const frames = structuredClone(sampleFrames)
    // Empty recentSamples + spoke_history so summary-only link falls back to metricTrends
    frames[0].results = []
    frames[5].results = []
    const {host, api} = createHostApi({frames})

    const mounted = await mountNetworkPerformance(root, host, api)
    activeMounts.push({mounted, root})
    await flushUi()

    const firstRow = root.querySelector("tbody tr")
    expect(firstRow).not.toBeNull()
    firstRow.click()
    await flushUi()

    const portalRoot = root.querySelector(".sr-dashboard-blueprint [data-sr-blueprint-portals='true']")
    const drawerText = portalRoot?.querySelector(".bp6-drawer")?.textContent || ""
    expect(drawerText).toContain("Fleet-wide fallback")
    expect(drawerText).toContain("Fleet-Wide Throughput Baseline")
  })

  test("isolates legacy link drawerHistory from named Hub Responder and sibling legacy target rows on the same spoke", async () => {
    const root = createMountRoot()
    const frames = [
      {
        id: "netperf_recent_samples",
        status: "ok",
        results: [
          {
            timestamp: "2026-11-18T03:55:00Z",
            agent_id: "agent-spoke-mix",
            metric_name: "rperf.bits_per_second",
            value: 11_000_000,
            target_device_ip: "198.51.100.99",
            tags: {metric_family: "rperf", target: "198.51.100.99"},
          },
          {
            timestamp: "2026-11-18T03:56:00Z",
            agent_id: "agent-spoke-mix",
            metric_name: "rperf.bits_per_second",
            value: 222_000_000,
            target_device_ip: "198.51.100.100",
            tags: {metric_family: "rperf", target: "198.51.100.100"},
          },
          {
            timestamp: "2026-11-18T03:57:00Z",
            agent_id: "agent-spoke-mix",
            metric_name: "rperf.bits_per_second",
            value: 999_000_000,
            target_device_ip: "198.51.100.10",
            tags: {metric_family: "rperf", responder_agent_id: "agent-hub-real", direction: "upload", protocol: "tcp"},
          },
        ],
      },
      {id: "netperf_metric_trends", status: "ok", results: []},
      {id: "netperf_spoke_summary", status: "ok", results: []},
      {id: "netperf_responder_capacity", status: "ok", results: []},
      {id: "netperf_agents", status: "ok", results: []},
      {
        id: "spoke_history",
        status: "ok",
        results: [
          {
            timestamp: "2026-11-18T03:50:00Z",
            agent_id: "agent-spoke-mix",
            metric_name: "rperf.bits_per_second",
            value: 12_000_000,
            target_device_ip: "198.51.100.99",
            tags: {metric_family: "rperf", target: "198.51.100.99"},
          },
          {
            timestamp: "2026-11-18T03:55:00Z",
            agent_id: "agent-spoke-mix",
            metric_name: "rperf.bits_per_second",
            value: 11_000_000,
            target_device_ip: "198.51.100.99",
            tags: {metric_family: "rperf", target: "198.51.100.99"},
          },
          {
            timestamp: "2026-11-18T03:51:00Z",
            agent_id: "agent-spoke-mix",
            metric_name: "rperf.bits_per_second",
            value: 888_000_000,
            target_device_ip: "198.51.100.10",
            tags: {metric_family: "rperf", responder_agent_id: "agent-hub-real"},
          },
        ],
      },
    ]

    const {host, api} = createHostApi({frames})
    const mounted = await mountNetworkPerformance(root, host, api)
    activeMounts.push({mounted, root})
    await flushUi()

    const legacyRow = Array.from(root.querySelectorAll("tbody tr")).find((tr) =>
      tr.textContent?.includes("198.51.100.99 (legacy target)"),
    )
    expect(legacyRow).toBeDefined()
    legacyRow.click()
    await flushUi()

    const portalRoot = root.querySelector(".sr-dashboard-blueprint [data-sr-blueprint-portals='true']")
    const drawerText = portalRoot?.querySelector(".bp6-drawer")?.textContent || ""
    expect(drawerText).toContain("11,000,000")
    expect(drawerText).toContain("12,000,000")
    expect(drawerText).not.toContain("999,000,000")
    expect(drawerText).not.toContain("888,000,000")
    expect(drawerText).not.toContain("222,000,000")
  })

  test("renders neutral missing KPI state for empty and TCP-only telemetry while preserving threshold tags when samples exist", async () => {
    // 1. Empty frames
    const emptyRoot = createMountRoot()
    const emptySetup = createHostApi({frames: []})
    const emptyMount = await mountNetworkPerformance(emptyRoot, emptySetup.host, emptySetup.api)
    activeMounts.push({mounted: emptyMount, root: emptyRoot})
    await flushUi()

    const emptyCard = Array.from(emptyRoot.querySelectorAll(".sr-netperf-kpi-card")).find((card) =>
      card.textContent?.includes("Worst Spoke Loss & Jitter"),
    )
    expect(emptyCard).toBeDefined()
    expect(emptyCard.querySelector(".sr-netperf-kpi-value")?.textContent).toBe("—")
    expect(emptyCard.textContent).toContain("No UDP jitter")
    expect(emptyCard.textContent).toContain("no samples")
    expect(emptyCard.textContent).not.toContain("within SLA")
    expect(emptyCard.textContent).not.toContain("0%")
    expect(emptyCard.querySelector(".bp6-tag.bp6-intent-success")).toBeNull()
    expect(emptyCard.querySelector(".bp6-tag.bp6-intent-warning")).toBeNull()

    // 2. TCP-only frames (throughput + availability only, no loss or jitter)
    const tcpRoot = createMountRoot()
    const tcpSetup = createHostApi({
      frames: [
        {
          id: "netperf_recent_samples",
          status: "ok",
          results: [
            {
              timestamp: "2026-11-18T03:58:00Z",
              agent_id: "agent-spoke-tcp-01",
              metric_name: "rperf.bits_per_second",
              value: 750_000_000,
              target_device_ip: "192.0.2.10",
              tags: {responder_agent_id: "agent-hub-east-01", direction: "upload", protocol: "tcp"},
            },
            {
              timestamp: "2026-11-18T03:58:00Z",
              agent_id: "agent-spoke-tcp-01",
              metric_name: "rperf.available",
              value: 1,
              target_device_ip: "192.0.2.10",
              tags: {responder_agent_id: "agent-hub-east-01", direction: "upload", protocol: "tcp"},
            },
          ],
        },
      ],
    })
    const tcpMount = await mountNetworkPerformance(tcpRoot, tcpSetup.host, tcpSetup.api)
    activeMounts.push({mounted: tcpMount, root: tcpRoot})
    await flushUi()

    const tcpCard = Array.from(tcpRoot.querySelectorAll(".sr-netperf-kpi-card")).find((card) =>
      card.textContent?.includes("Worst Spoke Loss & Jitter"),
    )
    expect(tcpCard).toBeDefined()
    expect(tcpCard.querySelector(".sr-netperf-kpi-value")?.textContent).toBe("—")
    expect(tcpCard.textContent).toContain("No UDP jitter")
    expect(tcpCard.textContent).toContain("no samples")
    expect(tcpCard.textContent).not.toContain("within SLA")

    // 3. Explicit 0% loss sample without UDP jitter preserves "within SLA" tag and "No UDP jitter"
    const zeroLossRoot = createMountRoot()
    const zeroLossSetup = createHostApi({
      frames: [
        {
          id: "netperf_recent_samples",
          status: "ok",
          results: [
            {
              timestamp: "2026-11-18T03:58:00Z",
              agent_id: "agent-spoke-tcp-02",
              metric_name: "rperf.loss_percent",
              value: 0,
              target_device_ip: "192.0.2.10",
              tags: {responder_agent_id: "agent-hub-east-01", direction: "upload", protocol: "tcp"},
            },
          ],
        },
      ],
    })
    const zeroLossMount = await mountNetworkPerformance(zeroLossRoot, zeroLossSetup.host, zeroLossSetup.api)
    activeMounts.push({mounted: zeroLossMount, root: zeroLossRoot})
    await flushUi()

    const zeroLossCard = Array.from(zeroLossRoot.querySelectorAll(".sr-netperf-kpi-card")).find((card) =>
      card.textContent?.includes("Worst Spoke Loss & Jitter"),
    )
    expect(zeroLossCard.querySelector(".sr-netperf-kpi-value")?.textContent).toBe("0%")
    expect(zeroLossCard.textContent).toContain("No UDP jitter")
    expect(zeroLossCard.textContent).toContain("within SLA")
    expect(zeroLossCard.querySelector(".bp6-tag.bp6-intent-success")).not.toBeNull()
  })

  test("isolates untagged spoke_history rows and literal 'legacy-target' rows from 198.51.100.99 and named Hub Responders", async () => {
    const root = createMountRoot()
    const frames = [
      {
        id: "netperf_recent_samples",
        status: "ok",
        results: [
          {
            timestamp: "2026-11-18T03:55:00Z",
            agent_id: "agent-spoke-mix",
            metric_name: "rperf.bits_per_second",
            value: 11_000_000,
            target_device_ip: "198.51.100.99",
            tags: {metric_family: "rperf", target: "198.51.100.99"},
          },
          {
            timestamp: "2026-11-18T03:56:00Z",
            agent_id: "agent-spoke-mix",
            metric_name: "rperf.bits_per_second",
            value: 15_000_000,
            tags: {metric_family: "rperf", target: "legacy-target"},
          },
          {
            timestamp: "2026-11-18T03:57:00Z",
            agent_id: "agent-spoke-mix",
            metric_name: "rperf.bits_per_second",
            value: 999_000_000,
            tags: {metric_family: "rperf", responder_agent_id: "agent-hub-real", direction: "upload", protocol: "tcp"},
          },
          {
            timestamp: "2026-11-18T03:58:00Z",
            agent_id: "agent-spoke-mix",
            metric_name: "rperf.bits_per_second",
            value: 777_000_000,
            tags: {metric_family: "rperf"},
          },
        ],
      },
      {id: "netperf_metric_trends", status: "ok", results: []},
      {id: "netperf_spoke_summary", status: "ok", results: []},
      {id: "netperf_responder_capacity", status: "ok", results: []},
      {id: "netperf_agents", status: "ok", results: []},
      {
        id: "spoke_history",
        status: "ok",
        results: [
          {
            timestamp: "2026-11-18T03:50:00Z",
            agent_id: "agent-spoke-mix",
            metric_name: "rperf.bits_per_second",
            value: 12_000_000,
            target_device_ip: "198.51.100.99",
            tags: {metric_family: "rperf", target: "198.51.100.99"},
          },
          {
            timestamp: "2026-11-18T03:51:00Z",
            agent_id: "agent-spoke-mix",
            metric_name: "rperf.bits_per_second",
            value: 777_000_000,
            tags: {metric_family: "rperf"},
          },
          {
            timestamp: "2026-11-18T03:52:00Z",
            agent_id: "agent-spoke-mix",
            metric_name: "rperf.bits_per_second",
            value: 333_000_000,
            tags: {metric_family: "rperf", target: "legacy-target"},
          },
          {
            timestamp: "2026-11-18T03:53:00Z",
            agent_id: "agent-spoke-mix",
            metric_name: "rperf.bits_per_second",
            value: 888_000_000,
            tags: {metric_family: "rperf", responder_agent_id: "agent-hub-real"},
          },
        ],
      },
    ]

    const {host, api} = createHostApi({frames})
    const mounted = await mountNetworkPerformance(root, host, api)
    activeMounts.push({mounted, root})
    await flushUi()

    const portalRoot = root.querySelector(".sr-dashboard-blueprint [data-sr-blueprint-portals='true']")

    // 1. 198.51.100.99 (legacy target) excludes untagged (777M), literal 'legacy-target' (333M/15M), and named hub (888M/999M)
    const ipRow = Array.from(root.querySelectorAll("tbody tr")).find((tr) =>
      tr.textContent?.includes("198.51.100.99 (legacy target)"),
    )
    expect(ipRow).toBeDefined()
    ipRow.click()
    await flushUi()

    let drawerText = portalRoot?.querySelector(".bp6-drawer")?.textContent || ""
    expect(drawerText).toContain("12,000,000")
    expect(drawerText).not.toContain("777,000,000")
    expect(drawerText).not.toContain("333,000,000")
    expect(drawerText).not.toContain("888,000,000")
    expect(drawerText).not.toContain("999,000,000")

    // 2. Named Hub Responder agent-hub-real excludes untagged (777M), 'legacy-target' (333M), and 198.51.100.99 (12M)
    const hubRow = Array.from(root.querySelectorAll("tbody tr")).find((tr) =>
      tr.textContent?.includes("agent-hub-real"),
    )
    expect(hubRow).toBeDefined()
    hubRow.click()
    await flushUi()

    drawerText = portalRoot?.querySelector(".bp6-drawer")?.textContent || ""
    expect(drawerText).toContain("888,000,000")
    expect(drawerText).not.toContain("777,000,000")
    expect(drawerText).not.toContain("333,000,000")
    expect(drawerText).not.toContain("12,000,000")

    // 3. Literal 'legacy-target' excludes 198.51.100.99 (12M), untagged (777M), and agent-hub-real (888M)
    const literalLegacyRow = Array.from(root.querySelectorAll("tbody tr")).find((tr) =>
      tr.textContent?.includes("legacy-target (legacy target)"),
    )
    expect(literalLegacyRow).toBeDefined()
    literalLegacyRow.click()
    await flushUi()

    drawerText = portalRoot?.querySelector(".bp6-drawer")?.textContent || ""
    expect(drawerText).toContain("333,000,000")
    expect(drawerText).not.toContain("12,000,000")
    expect(drawerText).not.toContain("777,000,000")
    expect(drawerText).not.toContain("888,000,000")

    // 4. Untagged ('unassigned-target') shows only untagged 777M
    const unassignedRow = Array.from(root.querySelectorAll("tbody tr")).find((tr) =>
      tr.textContent?.includes("unassigned-target (legacy target)"),
    )
    expect(unassignedRow).toBeDefined()
    unassignedRow.click()
    await flushUi()

    drawerText = portalRoot?.querySelector(".bp6-drawer")?.textContent || ""
    expect(drawerText).toContain("777,000,000")
    expect(drawerText).not.toContain("12,000,000")
    expect(drawerText).not.toContain("333,000,000")
    expect(drawerText).not.toContain("888,000,000")
  })
})

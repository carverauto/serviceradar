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
  timezone = "America/Chicago",
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
      },
    },
    navigate: (target) => {
      navigations.push(target)
    },
    refreshFrames: () => {
      refreshes.push(true)
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
      timezone,
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
})

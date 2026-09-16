import {afterEach, describe, expect, it, vi} from "vitest"
import DashboardWindowSelect, {dashboardWindowPreferences} from "./DashboardWindowSelect"

const originalDocument = globalThis.document
afterEach(() => { globalThis.document = originalDocument })

describe("dashboard window cookies", () => {
  it("restores independent validated defaults before connected mount", () => {
    expect(dashboardWindowPreferences("")).toEqual({netflow: "last_15m", events: "last_24h"})
    expect(dashboardWindowPreferences("dashboard_netflow_window=last_90d; dashboard_events_window=last_7d"))
      .toEqual({netflow: "last_90d", events: "last_7d"})
    expect(dashboardWindowPreferences("dashboard_netflow_window=%E0%A4%A; dashboard_events_window=all_time"))
      .toEqual({netflow: "last_15m", events: "last_24h"})
  })

  it("persists only the changed selector and sends the validated request", () => {
    globalThis.document = {cookie: ""}
    const listeners = new Map()
    const el = {
      dataset: {windowKind: "events", window: "last_24h"}, value: "last_30d",
      addEventListener: (name, callback) => listeners.set(name, callback),
      removeEventListener: (name, callback) => { if (listeners.get(name) === callback) listeners.delete(name) },
    }
    const context = {el, pushEvent: vi.fn()}
    DashboardWindowSelect.mounted.call(context)
    expect(context.pushEvent).not.toHaveBeenCalled()
    listeners.get("change")()
    expect(document.cookie).toBe("dashboard_events_window=last_30d; Max-Age=31536000; Path=/; SameSite=Lax")
    expect(context.pushEvent).toHaveBeenCalledWith("select_dashboard_window", {kind: "events", window: "last_30d"})
    el.value = "arbitrary"
    listeners.get("change")()
    expect(context.pushEvent).toHaveBeenCalledTimes(1)
    DashboardWindowSelect.updated.call(context)
    expect(el.value).toBe("last_24h")
    DashboardWindowSelect.destroyed.call(context)
    expect(listeners.size).toBe(0)
  })
})

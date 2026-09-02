import {describe, expect, it} from "vitest"

import {mountEndpointInventory} from "./endpoint_inventory"
import {mountSecurityFindings} from "./security_findings"
import {mountServiceAvailabilityNoc} from "./service_availability_noc"
import {dashboardUserTimeHtml} from "../utils/dashboard_user_time"

const canonical = "2026-08-30T18:00:00Z"

function dashboardElement(timezone = "America/Chicago") {
  return {
    dataset: {timezone},
    innerHTML: "",
    querySelectorAll() {
      return []
    },
  }
}

function dashboardApi() {
  return {
    onFrameUpdate() {
      return () => {}
    },
    onThemeChange() {
      return () => {}
    },
  }
}

function hostWithFrame(id, results) {
  return {package: {frames: [{id, results}]}}
}

describe("built-in dashboard user-time rendering", () => {
  it("normalizes valid offset instants to canonical UTC metadata", () => {
    const html = dashboardUserTimeHtml("2026-08-30T13:00:00.123456-05:00", {
      timeZone: "America/Chicago",
    })

    expect(html).toContain('datetime="2026-08-30T18:00:00.123456Z"')
    expect(html).toContain("canonical UTC 2026-08-30T18:00:00.123456Z")
    expect(html).not.toContain('datetime="2026-08-30T13:00:00.123456-05:00"')
  })

  it.each(["2026-08-30T18:00:00", '<img src=x onerror="boom">']) (
    "renders invalid or offsetless dashboard values only as an escaped fallback: %s",
    (value) => {
      const html = dashboardUserTimeHtml(value, {timeZone: "America/Chicago"})

      expect(html).not.toContain("<time")
      expect(html).not.toContain("canonical UTC")
      expect(html).not.toContain("<img")
      expect(html).toContain(value.startsWith("<") ? "&lt;img" : value)
    },
  )

  it("keeps a numeric offset accessible when a compact label omits it", () => {
    const html = dashboardUserTimeHtml(canonical, {
      timeZone: "America/Chicago",
      style: "compact",
    })

    expect(html).toContain('data-user-time-style="compact"')
    expect(html).toContain("GMT-5; display zone America/Chicago")
  })

  it("uses the endpoint dashboard root timezone for scan timestamps", () => {
    const element = dashboardElement()
    const host = hostWithFrame("scan_status", [
      {device_uid: "device-1", last_scan_at: canonical, package_count: 1},
    ])

    mountEndpointInventory(element, host, dashboardApi())

    expect(element.innerHTML).toContain(`<time datetime="${canonical}"`)
    expect(element.innerHTML).toContain(`data-user-time-zone="America/Chicago"`)
    expect(element.innerHTML).toContain(`${canonical} (UTC); display zone America/Chicago`)
    expect(element.innerHTML).toContain("01:00:00 PM")
    expect(element.innerHTML).toContain("GMT-5")
  })

  it("uses the security dashboard root timezone for event timestamps", () => {
    const element = dashboardElement()
    const host = hostWithFrame("scan_activity_recent", [
      {id: "event-1", activity_name: "Scan", time: canonical},
    ])

    mountSecurityFindings(element, host, dashboardApi())

    expect(element.innerHTML).toContain(`<time datetime="${canonical}"`)
    expect(element.innerHTML).toContain(`data-user-time-zone="America/Chicago"`)
    expect(element.innerHTML).toContain(`${canonical} (UTC); display zone America/Chicago`)
    expect(element.innerHTML).toContain("01:00:00 PM")
    expect(element.innerHTML).toContain("GMT-5")
  })

  it("uses the service dashboard root timezone for observed timestamps", () => {
    const element = dashboardElement()
    const host = {
      package: {
        frames: [
          {
            id: "attention_services",
            results: [{service_name: "DNS", timestamp: canonical, status: "critical"}],
          },
          {
            id: "slo_evaluations",
            results: [{slo_name: "DNS availability", projected_exhaustion_at: canonical}],
          },
        ],
      },
    }

    mountServiceAvailabilityNoc(element, host, dashboardApi())

    expect(element.innerHTML).toContain(`<time datetime="${canonical}"`)
    expect(element.innerHTML).toContain(`data-user-time-zone="America/Chicago"`)
    expect(element.innerHTML).toContain(`${canonical} (UTC); display zone America/Chicago`)
    expect(element.innerHTML).toContain(`Exhausts <time datetime="${canonical}"`)
    expect(element.innerHTML).toContain("01:00:00 PM")
    expect(element.innerHTML).toContain("GMT-5")
  })
})

import React from "react"
import {renderToStaticMarkup} from "react-dom/server"
import {afterEach, describe, expect, it, vi} from "vitest"

import * as DashboardPanelChart from "../src/DashboardPanelChart.jsx"
import {
  Component,
  capacityForecastRows,
  dashboardPanelCategoryLabel,
  isCapacityForecastPanel,
} from "../src/DashboardPanelChart.jsx"

const fields = [
  {name: "forecasted_at", type: "datetime"},
  {name: "horizon_ends_at", type: "datetime"},
  {name: "resource_label", type: "string"},
  {name: "current_value", type: "number"},
  {name: "projected_value", type: "number"},
  {name: "lower_bound", type: "number"},
  {name: "upper_bound", type: "number"},
  {name: "exhaustion_threshold", type: "number"},
  {name: "projected_exhaustion_at", type: "datetime"},
]

describe("DashboardPanelChart capacity forecast helpers", () => {
  afterEach(() => {
    vi.unstubAllGlobals()
  })

  it("detects capacity forecast panels from display config or canonical fields", () => {
    expect(isCapacityForecastPanel({display_config: {capacity_forecast: true}}, [])).toBe(true)
    expect(isCapacityForecastPanel({display_config: {}}, fields)).toBe(true)
    expect(isCapacityForecastPanel({display_config: {}}, [{name: "timestamp", type: "datetime"}])).toBe(false)
  })

  it("normalizes and sorts capacity forecast rows", () => {
    const rows = capacityForecastRows(
      [
        {
          forecasted_at: "2026-06-12T12:00:00Z",
          horizon_ends_at: "2026-09-10T12:00:00Z",
          resource_label: "uplink-a",
          current_value: "63.5",
          projected_value: 91.2,
          lower_bound: 84,
          upper_bound: 99,
          exhaustion_threshold: 80,
          projected_exhaustion_at: "2026-08-01T12:00:00Z",
        },
        {
          forecasted_at: "2026-06-11T12:00:00Z",
          horizon_ends_at: "2026-09-09T12:00:00Z",
          resource_label: "uplink-a",
          current_value: 61,
          projected_value: 87,
          exhaustion_threshold: 80,
        },
      ],
      fields,
    )

    expect(rows).toHaveLength(2)
    expect(rows[0].forecastedAt).toBe("2026-06-11T12:00:00Z")
    expect(rows[0].name).toBe("2026-06-11T12:00:00Z")
    expect(rows[1]).toMatchObject({
      label: "uplink-a",
      current: 63.5,
      projected: 91.2,
      lower: 84,
      upper: 99,
      threshold: 80,
      exhaustionAt: "2026-08-01T12:00:00Z",
    })
  })

  it("formats axis labels in the saved zone and tooltip labels with a numeric offset", () => {
    expect(DashboardPanelChart.dashboardPanelTimeLabel).toBeTypeOf("function")

    const canonical = "2026-08-30T18:00:00Z"
    const axis = DashboardPanelChart.dashboardPanelTimeLabel(canonical, {
      timeZone: "America/Chicago",
      style: "axis",
      locale: "en-US",
    })
    const tooltip = DashboardPanelChart.dashboardPanelTimeLabel(canonical, {
      timeZone: "America/Chicago",
      style: "tooltip",
      locale: "en-US",
    })

    expect(axis).toContain("01:00 PM")
    expect(axis).not.toMatch(/GMT|UTC/u)
    expect(tooltip).toContain("01:00:00 PM")
    expect(tooltip).toMatch(/GMT-0?5(?::00)?/u)
  })

  it("preserves numeric categories while localizing datetime categories", () => {
    expect(
      dashboardPanelCategoryLabel(42, "port", {
        fieldType: "number",
        timeZone: "America/Chicago",
        style: "axis",
      }),
    ).toBe("42")

    expect(
      dashboardPanelCategoryLabel("2026-08-30T18:00:00Z", "observed_at", {
        fieldType: "datetime",
        timeZone: "America/Chicago",
        style: "axis",
      }),
    ).toContain("01:00 PM")
  })

  it("renders forecast ETA using the saved zone with numeric-offset context", () => {
    const html = renderToStaticMarkup(
      <Component
        panel={{visual_type: "line", display_config: {capacity_forecast: true}}}
        rows={[
          {
            forecasted_at: "2026-06-12T12:00:00Z",
            horizon_ends_at: "2026-09-10T12:00:00Z",
            current_value: 63.5,
            projected_value: 91.2,
            projected_exhaustion_at: "2026-08-01T12:00:00Z",
          },
        ]}
        fields={fields}
        timezone="America/Chicago"
      />,
    )

    expect(html).toContain("07:00:00 AM")
    expect(html).toMatch(/GMT-0?5(?::00)?/u)
    expect(html).toContain('dateTime="2026-08-01T12:00:00Z"')
    expect(html).toContain('data-user-time-zone="America/Chicago"')
    expect(html).toContain('data-user-time-style="tooltip"')
    expect(html).toMatch(
      /aria-label="Aug 01, 2026, 07:00:00 AM GMT-0?5(?::00)?; display zone America\/Chicago; canonical UTC 2026-08-01T12:00:00Z"/u,
    )
    expect(html).toContain('data-time-axis-start="2026-06-12T12:00:00Z"')
    expect(html).toContain('data-time-axis-end="2026-06-12T12:00:00Z"')
    expect(html).toContain('data-time-axis-zone="America/Chicago"')
    expect(html).toMatch(
      /aria-label="Time axis from Jun 12, 2026, 07:00:00 AM GMT-0?5(?::00)? to Jun 12, 2026, 07:00:00 AM GMT-0?5(?::00)?; display zone America\/Chicago; canonical UTC range 2026-06-12T12:00:00Z to 2026-06-12T12:00:00Z"/u,
    )
  })

  it("falls back to the canonical UTC instant when Intl is unavailable or unusable", () => {
    const canonical = "2026-08-30T18:00:00Z"

    expect(
      DashboardPanelChart.dashboardPanelTimeLabel(canonical, {
        timeZone: "America/Chicago",
        style: "tooltip",
        intl: {},
      }),
    ).toBe(canonical)

    vi.stubGlobal("Intl", undefined)

    expect(
      DashboardPanelChart.dashboardPanelTimeLabel(canonical, {
        timeZone: "America/Chicago",
        style: "tooltip",
      }),
    ).toBe(canonical)
  })
})

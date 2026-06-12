import {describe, expect, it} from "vitest"

import {
  capacityForecastRows,
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
})

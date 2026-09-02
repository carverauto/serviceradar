import React from "react"
import {renderToStaticMarkup} from "react-dom/server"
import {describe, expect, it} from "vitest"

import {Component} from "../src/DashboardBuilderCanvas.jsx"

const canonical = "2026-08-30T18:00:00Z"
const timezone = "America/Chicago"

describe("DashboardBuilderCanvas datetime previews", () => {
  it("renders datetime-typed table cells as semantic localized instants", () => {
    const html = renderToStaticMarkup(
      <Component
        panels={[{
          id: "table-preview",
          title: "Table preview",
          visual_type: "table",
          data_binding: {},
          preview: {
            fields: [
              {name: "observed_at", type: "datetime"},
              {name: "note", type: "string"},
            ],
            rows: [{observed_at: canonical, note: canonical}],
          },
        }]}
        timezone={timezone}
      />,
    )

    expect(html.match(/<time\b/gu)).toHaveLength(1)
    expect(html).toContain(`dateTime="${canonical}"`)
    expect(html).toContain(`data-user-time-zone="${timezone}"`)
    expect(html).toContain("01:00:00 PM")
    expect(html).toContain(`<td class="max-w-44 truncate" title="${canonical}">${canonical}</td>`)
  })

  it("renders datetime row and column bindings in pivot previews", () => {
    const html = renderToStaticMarkup(
      <Component
        panels={[{
          id: "pivot-preview",
          title: "Pivot preview",
          visual_type: "pivot",
          data_binding: {row_field: "started_at", column_field: "ended_at"},
          preview: {
            fields: [
              {name: "started_at", type: "datetime"},
              {name: "ended_at", type: "datetime"},
            ],
            rows: [
              {
                started_at: canonical,
                ended_at: "2026-08-30T19:00:00Z",
              },
            ],
          },
        }]}
        timezone={timezone}
      />,
    )

    expect(html.match(/<time\b/gu)).toHaveLength(2)
    expect(html).toContain(`dateTime="${canonical}"`)
    expect(html).toContain('dateTime="2026-08-30T19:00:00Z"')
    expect(html.match(new RegExp(`data-user-time-zone="${timezone}"`, "gu"))).toHaveLength(2)
    expect(html).toContain("01:00:00 PM")
    expect(html).toContain("02:00:00 PM")
  })
})

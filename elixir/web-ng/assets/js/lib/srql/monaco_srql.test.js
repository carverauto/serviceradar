import {describe, expect, test} from "vitest"

import {srqlCompletionItems} from "./monaco_srql.js"

const catalog = {
  control_tokens: ["limit:", "sort:", "time:", "where"],
  operators: [":", "!=", ">", "<"],
  entities: {
    devices: {
      label: "Devices",
      default_sort: {field: "last_seen", direction: "desc"},
      fields: {
        array: ["discovery_sources", "tags"],
        boolean: ["is_active"],
        filter: ["hostname", "ip", "discovery_sources", "tags", "is_active", "vendor_name"],
        numeric: [],
        series: [],
        stats: [],
        value: [],
      },
      enums: {discovery_sources: ["agent", "awx", "armis"]},
    },
    logs: {
      label: "Logs",
      default_sort: {field: "timestamp", direction: "desc"},
      fields: {
        array: [],
        boolean: [],
        filter: ["message", "severity_text"],
        numeric: [],
        series: [],
        stats: [],
        value: [],
      },
      enums: {severity_text: ["FATAL", "ERROR", "WARN", "INFO", "DEBUG"]},
    },
  },
}

const labels = items => items.map(item => item.label)
const byLabel = (items, label) => items.find(item => item.label === label)

describe("srqlCompletionItems", () => {
  test("suggests bare entity ids right after in:", () => {
    const items = srqlCompletionItems({catalog, linePrefix: "in:"})
    expect(labels(items)).toEqual(expect.arrayContaining(["devices", "logs"]))
    expect(byLabel(items, "devices").insert).toBe("devices ")
    expect(byLabel(items, "devices").kind).toBe("entity")
  })

  test("leads with in:<entity> and control tokens at the start", () => {
    const items = srqlCompletionItems({catalog, linePrefix: ""})
    expect(labels(items)).toEqual(expect.arrayContaining(["in:devices", "sort:", "where"]))
  })

  test("offers the entity fields for a bare filter after in:devices", () => {
    const items = srqlCompletionItems({catalog, linePrefix: "in:devices "})
    expect(labels(items)).toEqual(expect.arrayContaining(["hostname", "discovery_sources", "sort:"]))

    // Plain field inserts `field:`; array field inserts a parenthesized snippet.
    expect(byLabel(items, "hostname").insert).toBe("hostname:")
    const discovery = byLabel(items, "discovery_sources")
    expect(discovery.insert).toBe("discovery_sources:($0)")
    expect(discovery.snippet).toBe(true)
    expect(discovery.detail).toBe("array")
  })

  test("suggests known enum values inside a discovery_sources set", () => {
    const items = srqlCompletionItems({catalog, linePrefix: "in:devices discovery_sources:("})
    expect(labels(items)).toEqual(["agent", "awx", "armis"])
    expect(byLabel(items, "awx").kind).toBe("enum")
  })

  test("leads with severity_text enum values right after the colon (op slot)", () => {
    const items = srqlCompletionItems({catalog, linePrefix: "in:logs severity_text:"})
    // Enum values come first, then the comparison operators are still available.
    expect(labels(items).slice(0, 5)).toEqual(["FATAL", "ERROR", "WARN", "INFO", "DEBUG"])
    expect(labels(items)).toEqual(expect.arrayContaining([":", "!="]))
    expect(byLabel(items, "ERROR").kind).toBe("enum")
  })

  test("offers only the current entity's fields (context-aware)", () => {
    const items = srqlCompletionItems({catalog, linePrefix: "in:logs "})
    const fieldLabels = items.filter(item => item.kind === "field").map(item => item.label)
    expect(fieldLabels).toEqual(expect.arrayContaining(["message", "severity_text"]))
    expect(fieldLabels).not.toContain("hostname")
  })

  test("suggests operators after a plain field's colon (no known values)", () => {
    const items = srqlCompletionItems({catalog, linePrefix: "in:devices hostname:"})
    expect(labels(items)).toEqual(expect.arrayContaining([":", "!="]))
    // hostname has no enum/boolean values, so nothing but operators is offered.
    expect(items.every(item => item.kind === "operator")).toBe(true)
  })

  test("falls back to the flat completion list before the catalog loads", () => {
    const items = srqlCompletionItems({
      catalog: null,
      completions: ["in:devices", "sort:", "hostname"],
      linePrefix: "in:",
    })
    // After `in:` the flat entity token is inserted without its prefix.
    expect(byLabel(items, "devices").insert).toBe("devices")
  })
})

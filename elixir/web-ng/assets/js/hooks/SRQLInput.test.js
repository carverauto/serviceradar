import {describe, expect, test} from "vitest"

import SRQLInput from "./SRQLInput.js"
import {tokenize} from "../lib/srql/tokenizer.js"

const catalog = {
  control_tokens: ["limit:", "sort:", "time:", "where"],
  entities: {
    attributed_flows: {
      default_sort: {field: "time", direction: "desc"},
      fields: {
        boolean: [],
        filter: [
          "attribution_status",
          "process",
          "src_endpoint_ip",
          "dst_endpoint_ip",
          "src_endpoint_port",
          "dst_endpoint_port",
          "protocol_num",
        ],
        numeric: ["src_endpoint_port", "dst_endpoint_port", "protocol_num"],
        series: [],
        stats: [],
        value: [],
      },
      label: "Attributed Flows",
    },
    events: {
      default_sort: {field: "timestamp", direction: "desc"},
      fields: {
        boolean: [],
        filter: ["log_name", "message", "severity"],
        numeric: [],
        series: [],
        stats: [],
        value: [],
      },
      label: "Events",
    },
    devices: {
      default_sort: {field: "last_seen", direction: "desc"},
      fields: {
        array: ["discovery_sources", "tags"],
        boolean: ["is_active"],
        filter: ["hostname", "ip", "discovery_sources", "tags", "is_active"],
        numeric: [],
        series: [],
        stats: [],
        value: [],
      },
      enums: {discovery_sources: ["agent", "awx", "armis"]},
      label: "Devices",
    },
  },
  operators: [":"],
}

function hookFor(state) {
  const hook = Object.create(SRQLInput)
  hook.catalog = catalog
  hook.forceAllCandidates = false
  hook.state = state

  return hook
}

describe("SRQLInput hook", () => {
  test("accepts default sort fields that are not filter fields", () => {
    const query =
      "in:attributed_flows time:last_24h attribution_status:attributed sort:time:desc limit:50"
    const state = tokenize(query, query.indexOf("time:desc") + "time".length)
    const hook = hookFor(state)
    const sortField = state.tokens.find(
      token => token.kind === "field" && token.text === "time" && query.slice(token.start - 5, token.start) === "sort:"
    )

    expect(sortField).toBeTruthy()
    expect(hook.isUnknown(sortField)).toBe(false)
  })

  test("does not use stale time control context for normal field values", () => {
    const query = "in:attributed_flows time:last_24h attribution_status:attributed"
    const state = tokenize(query, query.length)
    const hook = hookFor(state)

    expect(state.activeToken).toMatchObject({kind: "value", text: "attributed"})
    expect(hook.valueCandidates(state)).toEqual([])
  })

  test("suggests the default sort field in sort field context", () => {
    const query = "in:attributed_flows time:last_24h sort:ti"
    const state = tokenize(query, query.length)
    const hook = hookFor(state)

    expect(hook.buildCandidates(state)).toContainEqual({
      value: "time",
      label: "time",
      detail: "Sort field",
      slot: "field",
    })
  })

  test("accepts event time aliases in sort field context", () => {
    const query = 'in:events log_name:"pdns.ocsf" sort:time:desc limit:50'
    const state = tokenize(query, query.indexOf("time:desc") + "time".length)
    const hook = hookFor(state)
    const sortField = state.tokens.find(
      token => token.kind === "field" && token.text === "time" && query.slice(token.start - 5, token.start) === "sort:"
    )

    expect(sortField).toBeTruthy()
    expect(hook.isUnknown(sortField)).toBe(false)
    expect(hook.sortableFieldsForEntity("events")).toEqual(
      expect.arrayContaining(["event_timestamp", "time", "timestamp"])
    )
  })

  test("accepts generated attributed flow detail filters", () => {
    const query =
      "in:attributed_flows time:last_24h sort:time:desc src_endpoint_ip:10.0.2.10 dst_endpoint_ip:192.168.10.31 src_endpoint_port:179 dst_endpoint_port:38401 protocol_num:6"
    const state = tokenize(query, query.length)
    const hook = hookFor(state)

    expect(state.tokens.map(token => [token.kind, token.text])).toContainEqual([
      "field",
      "src_endpoint_ip",
    ])

    for (const token of state.tokens) {
      expect(hook.isUnknown(token), `${token.kind}:${token.text}`).toBe(false)
    }
  })

  test("surfaces entity fields for a bare filter after in:devices", () => {
    const query = "in:devices dis"
    const state = tokenize(query, query.length)
    const hook = hookFor(state)

    expect(hook.buildCandidates(state)).toContainEqual({
      value: "discovery_sources",
      label: "discovery_sources",
      detail: "Field",
      slot: "field",
      array: true,
    })
  })

  test("marks array fields so the accept scaffolds parenthesized set syntax", () => {
    const query = "in:devices "
    const state = tokenize(query, query.length)
    const hook = hookFor(state)
    const candidate = hook.fieldSlotCandidates(state).find(item => item.value === "discovery_sources")

    expect(candidate).toMatchObject({value: "discovery_sources", array: true})
    // Plain fields stay unscaffolded.
    expect(hook.fieldSlotCandidates(state).find(item => item.value === "hostname").array).toBeUndefined()
  })

  test("suggests known discovery_sources values", () => {
    const query = "in:devices discovery_sources:awx"
    const state = tokenize(query, query.length)
    const hook = hookFor(state)

    expect(hook.valueCandidates(state)).toContainEqual({
      value: "awx",
      label: "awx",
      detail: "Value",
      slot: "value",
    })
  })

  test("matches enum values inside a parenthesized set, ignoring the paren", () => {
    const query = "in:devices discovery_sources:(aw"
    const state = tokenize(query, query.length)
    const hook = hookFor(state)

    const values = hook.buildCandidates(state).map(candidate => candidate.value)
    expect(values).toContain("awx")
  })
})

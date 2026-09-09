import {describe, expect, test} from "vitest"

import SRQLInput from "./SRQLInput.js"
import {HISTORY_STORAGE_KEY, pushHistory} from "../lib/srql/queryHistory.js"
import {tokenize} from "../lib/srql/tokenizer.js"

function memoryStorage() {
  const map = new Map()
  return {
    getItem: key => (map.has(key) ? map.get(key) : null),
    setItem: (key, value) => {
      map.set(key, String(value))
    },
    removeItem: key => {
      map.delete(key)
    },
  }
}

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

function hookFor(state, {value = "", storage = memoryStorage()} = {}) {
  const hook = Object.create(SRQLInput)
  hook.catalog = catalog
  hook.forceAllCandidates = false
  hook.state = state
  hook.historyStorage = storage
  hook.input = {value}
  hook.candidates = []
  hook.highlighted = 0
  hook.dropdownOpen = false

  return hook
}

describe("SRQLInput hook", () => {
  test("accepts default sort fields that are not filter fields", () => {
    const query =
      "in:attributed_flows time:last_24h attribution_status:attributed sort:time:desc limit:50"
    const state = tokenize(query, query.indexOf("time:desc") + "time".length)
    const hook = hookFor(state, {value: query})
    const sortField = state.tokens.find(
      token => token.kind === "field" && token.text === "time" && query.slice(token.start - 5, token.start) === "sort:"
    )

    expect(sortField).toBeTruthy()
    expect(hook.isUnknown(sortField)).toBe(false)
  })

  test("does not use stale time control context for normal field values", () => {
    const query = "in:attributed_flows time:last_24h attribution_status:attributed"
    const state = tokenize(query, query.length)
    const hook = hookFor(state, {value: query})

    expect(state.activeToken).toMatchObject({kind: "value", text: "attributed"})
    expect(hook.valueCandidates(state)).toEqual([])
  })

  test("suggests the default sort field in sort field context", () => {
    const query = "in:attributed_flows time:last_24h sort:ti"
    const state = tokenize(query, query.length)
    const hook = hookFor(state, {value: query})

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
    const hook = hookFor(state, {value: query})
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
    const hook = hookFor(state, {value: query})

    expect(state.tokens.map(token => [token.kind, token.text])).toContainEqual([
      "field",
      "src_endpoint_ip",
    ])

    for (const token of state.tokens) {
      expect(hook.isUnknown(token), `${token.kind}:${token.text}`).toBe(false)
    }
  })

  test("does not flag metadata.<key> dynamic filters as unknown", () => {
    const query = 'in:devices metadata.gateway_id:"gateway-platform"'
    const state = tokenize(query, query.length)
    const hook = hookFor(state, {value: query})
    const metadataField = state.tokens.find(token => token.kind === "field" && token.text === "metadata.gateway_id")

    expect(metadataField).toBeTruthy()
    expect(hook.isUnknown(metadataField)).toBe(false)
  })

  test("does not flag tags.<key> dynamic filters as unknown", () => {
    const query = "in:devices tags.owner:platform"
    const state = tokenize(query, query.length)
    const hook = hookFor(state, {value: query})
    const tagsField = state.tokens.find(token => token.kind === "field" && token.text === "tags.owner")

    expect(tagsField).toBeTruthy()
    expect(hook.isUnknown(tagsField)).toBe(false)
  })

  test("still flags malformed metadata keys and genuinely unknown fields", () => {
    const query = "in:devices metadata.bad!:x totally_bogus:y"
    const state = tokenize(query, query.length)
    const hook = hookFor(state, {value: query})
    const malformedMetadata = state.tokens.find(token => token.kind === "field" && token.text === "metadata.bad!")
    const bogusField = state.tokens.find(token => token.kind === "field" && token.text === "totally_bogus")

    expect(malformedMetadata).toBeTruthy()
    expect(hook.isUnknown(malformedMetadata)).toBe(true)
    expect(bogusField).toBeTruthy()
    expect(hook.isUnknown(bogusField)).toBe(true)
  })

  test("surfaces entity fields for a bare filter after in:devices", () => {
    const query = "in:devices dis"
    const state = tokenize(query, query.length)
    const hook = hookFor(state, {value: query})

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
    const hook = hookFor(state, {value: query})
    const candidate = hook.fieldSlotCandidates(state).find(item => item.value === "discovery_sources")

    expect(candidate).toMatchObject({value: "discovery_sources", array: true})
    // Plain fields stay unscaffolded.
    expect(hook.fieldSlotCandidates(state).find(item => item.value === "hostname").array).toBeUndefined()
  })

  test("suggests known discovery_sources values", () => {
    const query = "in:devices discovery_sources:awx"
    const state = tokenize(query, query.length)
    const hook = hookFor(state, {value: query})

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
    const hook = hookFor(state, {value: query})

    const values = hook.buildCandidates(state).map(candidate => candidate.value)
    expect(values).toContain("awx")
  })

  test("does not flag a negated array field as unknown", () => {
    const query = "in:devices !discovery_sources:(armis)"
    const state = tokenize(query, query.length)
    const hook = hookFor(state, {value: query})

    for (const token of state.tokens) {
      expect(hook.isUnknown(token), `${token.kind}:${token.text}`).toBe(false)
    }
  })

  test("suggests known values for a negated array field", () => {
    const query = "in:devices !discovery_sources:(aw"
    const state = tokenize(query, query.length)
    const hook = hookFor(state, {value: query})

    const values = hook.buildCandidates(state).map(candidate => candidate.value)
    expect(values).toContain("awx")
  })

  test("still flags a negated unknown field", () => {
    const query = "in:devices !bogus:(x)"
    const state = tokenize(query, query.length)
    const hook = hookFor(state, {value: query})
    const field = state.tokens.find(token => token.kind === "field")

    expect(field?.text).toBe("!bogus")
    expect(hook.isUnknown(field)).toBe(true)
  })

  test("shows recent history when the bar is empty", () => {
    const storage = memoryStorage()
    pushHistory("in:devices hostname:edge", storage)
    pushHistory("in:events time:last_1h", storage)

    const state = tokenize("", 0)
    const hook = hookFor(state, {value: "", storage})

    expect(hook.buildCandidates(state)).toEqual([
      {
        value: "in:events time:last_1h",
        label: "in:events time:last_1h",
        detail: "Recent",
        slot: "history",
      },
      {
        value: "in:devices hostname:edge",
        label: "in:devices hostname:edge",
        detail: "Recent",
        slot: "history",
      },
    ])
  })

  test("prepends matching history while retyping before a known entity is chosen", () => {
    const storage = memoryStorage()
    pushHistory("in:devices hostname:edge", storage)
    pushHistory("in:events time:last_1h", storage)

    // Partial entity token is not a known catalog entity, so history may merge.
    const query = "in:dev"
    const state = tokenize(query, query.length)
    const hook = hookFor(state, {value: query, storage})
    const candidates = hook.buildCandidates(state)

    expect(candidates[0]).toMatchObject({
      value: "in:devices hostname:edge",
      slot: "history",
      detail: "Recent",
    })
    expect(candidates.some(candidate => candidate.slot === "control" || candidate.slot === "entity")).toBe(
      true
    )
  })

  test("does not interleave history once a known entity is active", () => {
    const storage = memoryStorage()
    pushHistory("in:devices include_inactive:true time:last_24h hostname:edge", storage)
    pushHistory("in:devices include_inactive:true time:last_24h", storage)

    // Same shape as the live Devices bar: entity chosen, field/value completions.
    const query = "in:devices include_inactive:true time:last_24h"
    const state = tokenize(query, query.length)
    const hook = hookFor(state, {value: query, storage})
    const candidates = hook.buildCandidates(state)

    expect(candidates.every(candidate => candidate.slot !== "history")).toBe(true)
  })

  test("does not list the current bar text as a history row while retyping", () => {
    const storage = memoryStorage()
    pushHistory("in:devices hostname:edge", storage)
    pushHistory("in:dev", storage)

    const query = "in:dev"
    const state = tokenize(query, query.length)
    const hook = hookFor(state, {value: query, storage})
    const candidates = hook.buildCandidates(state)

    expect(candidates.map(candidate => candidate.value)).not.toContain("in:dev")
    expect(candidates[0]).toMatchObject({
      value: "in:devices hostname:edge",
      slot: "history",
    })
  })

  test("accepting a history row replaces the whole query", () => {
    const storage = memoryStorage()
    const events = []
    const input = {
      value: "in",
      setSelectionRange(start, end) {
        this.selectionStart = start
        this.selectionEnd = end
      },
      dispatchEvent(event) {
        events.push(event.type)
      },
    }
    const hook = Object.create(SRQLInput)
    hook.input = input
    hook.historyStorage = storage
    hook.close = () => {
      hook.closed = true
    }

    hook.accept({
      value: "in:devices hostname:edge",
      label: "in:devices hostname:edge",
      detail: "Recent",
      slot: "history",
    })

    expect(input.value).toBe("in:devices hostname:edge")
    expect(input.selectionStart).toBe(input.value.length)
    expect(events).toEqual(["input", "change"])
    expect(hook.closed).toBe(true)
  })

  test("recordHistory persists executed queries", () => {
    const storage = memoryStorage()
    const hook = hookFor(tokenize("", 0), {storage})

    hook.recordHistory("  in:devices  ")
    hook.recordHistory("")
    expect(JSON.parse(storage.getItem(HISTORY_STORAGE_KEY))).toEqual(["in:devices"])
  })
})

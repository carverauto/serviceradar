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
        filter: ["attribution_status", "process"],
        numeric: [],
        series: [],
        stats: [],
        value: [],
      },
      label: "Attributed Flows",
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
})

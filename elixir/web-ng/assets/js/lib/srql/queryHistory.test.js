import {describe, expect, test, beforeEach} from "vitest"

import {
  HISTORY_LIMIT,
  HISTORY_STORAGE_KEY,
  filterHistory,
  pushHistory,
  readHistory,
} from "./queryHistory.js"

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

describe("queryHistory", () => {
  /** @type {ReturnType<typeof memoryStorage>} */
  let storage

  beforeEach(() => {
    storage = memoryStorage()
  })

  test("starts empty", () => {
    expect(readHistory(storage)).toEqual([])
  })

  test("pushes most-recent first and skips blanks", () => {
    pushHistory("  in:devices  ", storage)
    pushHistory("", storage)
    pushHistory("   ", storage)
    pushHistory("in:events", storage)

    expect(readHistory(storage)).toEqual(["in:events", "in:devices"])
  })

  test("moves exact duplicates to the front", () => {
    pushHistory("in:devices", storage)
    pushHistory("in:events", storage)
    pushHistory("in:devices", storage)

    expect(readHistory(storage)).toEqual(["in:devices", "in:events"])
  })

  test(`caps history at ${HISTORY_LIMIT}`, () => {
    for (let index = 0; index < HISTORY_LIMIT + 5; index += 1) {
      pushHistory(`in:devices limit:${index}`, storage)
    }

    const history = readHistory(storage)
    expect(history).toHaveLength(HISTORY_LIMIT)
    expect(history[0]).toBe(`in:devices limit:${HISTORY_LIMIT + 4}`)
    expect(history.at(-1)).toBe(`in:devices limit:5`)
  })

  test("filterHistory matches substrings case-insensitively", () => {
    pushHistory("in:devices hostname:edge", storage)
    pushHistory("in:events log_name:pdns", storage)
    pushHistory("in:attributed_flows time:last_24h", storage)

    expect(filterHistory("DEVICE", storage)).toEqual(["in:devices hostname:edge"])
    expect(filterHistory("time:", storage)).toEqual(["in:attributed_flows time:last_24h"])
    expect(filterHistory("", storage)).toHaveLength(3)
  })

  test("tolerates corrupt storage payloads", () => {
    storage.setItem(HISTORY_STORAGE_KEY, "{not-json")
    expect(readHistory(storage)).toEqual([])

    storage.setItem(HISTORY_STORAGE_KEY, JSON.stringify({oops: true}))
    expect(readHistory(storage)).toEqual([])

    storage.setItem(HISTORY_STORAGE_KEY, JSON.stringify([1, "in:devices", null, "  "]))
    expect(readHistory(storage)).toEqual(["in:devices"])
  })
})
